import CoreAudio
import Foundation

public struct AirtapError: Error, CustomStringConvertible {
    public let description: String
    static func status(_ status: OSStatus, _ what: String) -> AirtapError {
        AirtapError(description: "\(what) failed (OSStatus \(status))")
    }
}

public struct OutputDevice: Identifiable, Hashable {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
}

public struct AudioApp: Identifiable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    public let isPlaying: Bool
}

private let system = AudioObjectID(kAudioObjectSystemObject)

private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

private func hasOutput(_ device: AudioObjectID) -> Bool {
    var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
}

public func outputDevices() -> [OutputDevice] {
    objectIDs(system, kAudioHardwarePropertyDevices).filter(hasOutput).map {
        OutputDevice(id: $0, name: string($0, kAudioObjectPropertyName), uid: string($0, kAudioDevicePropertyDeviceUID))
    }
}

private func isRunningOutput(_ process: AudioObjectID) -> Bool {
    var addr = address(kAudioProcessPropertyIsRunningOutput)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr && running != 0
}

public func audioApps() -> [AudioApp] {
    var playing: [String: Bool] = [:]
    for process in objectIDs(system, kAudioHardwarePropertyProcessObjectList) {
        let bundleID = string(process, kAudioProcessPropertyBundleID)
        if !bundleID.isEmpty { playing[bundleID] = (playing[bundleID] ?? false) || isRunningOutput(process) }
    }
    return playing.keys.sorted().map { AudioApp(bundleID: $0, isPlaying: playing[$0] ?? false) }
}

public func defaultOutput() throws -> OutputDevice {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try Router.check(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id), "read default output device")
    guard let device = outputDevices().first(where: { $0.id == id }) else { throw AirtapError(description: "default output device not found") }
    return device
}

/// Taps the audio of every process whose bundle id contains `bundleID`, muting it locally, and hands it to `sink`
/// on the audio thread. The tap is rebuilt when the app's audio processes or the default output device change,
/// because both are baked into it: the process list is what gets captured and the output device is its clock.
public final class Router {
    /// Called when a rebuild changed the sample rate of the audio handed to `sink`.
    public var onFormatChange: ((AudioStreamBasicDescription) -> Void)?
    public var format: AudioStreamBasicDescription {
        formatLock.lock()
        defer { formatLock.unlock() }
        return currentFormat
    }

    private static let maxRebuildRetries = 5
    private let formatLock = NSLock()
    private var currentFormat = AudioStreamBasicDescription()
    private var rebuildRetries = 0
    private let bundleID: String
    private let sink: (UnsafePointer<AudioBufferList>) -> Void
    private let queue = DispatchQueue(label: "airtap.router")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var tappedProcesses: Set<AudioObjectID> = []
    private var clockUID = ""
    private var listeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    public init(bundleID: String, sink: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        self.bundleID = bundleID
        self.sink = sink
        try queue.sync { try build(processes: matchingProcesses(), clock: defaultOutput()) }
        observe(kAudioHardwarePropertyProcessObjectList)
        observe(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // No `queue.sync` here: the last reference can go away on `queue` itself, at the end of a listener callback,
    // and syncing onto the queue we are already on would deadlock. Nothing else can touch the tap by now.
    deinit {
        removeListeners()
        teardown()
    }

    public func stop() {
        removeListeners()
        queue.sync { teardown() }
    }

    private func removeListeners() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener.block)
        }
        listeners = []
    }

    private func observe(_ selector: AudioObjectPropertySelector) {
        var address = address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        AudioObjectAddPropertyListenerBlock(system, &address, queue, block)
        listeners.append((address, block))
    }

    private func matchingProcesses() -> [AudioObjectID] {
        let processes = objectIDs(system, kAudioHardwarePropertyProcessObjectList)
        let bundleIDs = processes.map { string($0, kAudioProcessPropertyBundleID) }
        return BundleMatch.indices(of: bundleIDs, matching: bundleID).map { processes[$0] }
    }

    /// Runs on `queue` whenever the system's process list or default output device changes.
    private func refresh() {
        let processes = matchingProcesses()
        let clock = try? defaultOutput()
        let isWaiting = tappedProcesses.isEmpty
        if isWaiting, processes.isEmpty { return }
        guard isWaiting || Set(processes) != tappedProcesses || clock?.uid != clockUID else { return }
        let previousRate = format.mSampleRate
        teardown()
        guard !processes.isEmpty else {
            Log.info("capture", "'\(bundleID)' has no audio process right now; waiting for it to return")
            return
        }
        do {
            guard let clock else { throw AirtapError(description: "no default output device") }
            try build(processes: processes, clock: clock)
            rebuildRetries = 0
            Log.info("capture", "tap rebuilt: \(processes.count) process(es), clock '\(clock.name)', \(Int(format.mSampleRate)) Hz")
            if format.mSampleRate != previousRate { onFormatChange?(format) }
        } catch {
            teardown()
            retryRebuild(after: error)
        }
    }

    /// A rebuild can fail because the new device is not ready at the instant the change is announced, and no further
    /// change event would follow to trigger another attempt.
    private func retryRebuild(after error: Error) {
        guard rebuildRetries < Self.maxRebuildRetries else {
            Log.info("capture", "could not rebuild the tap, giving up until the next change: \(error)")
            return
        }
        rebuildRetries += 1
        let delay = Double(rebuildRetries)
        Log.info("capture", "could not rebuild the tap (\(error)); retry \(rebuildRetries)/\(Self.maxRebuildRetries) in \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    private func build(processes: [AudioObjectID], clock: OutputDevice) throws {
        guard !processes.isEmpty else { throw AirtapError(description: "no audio process matches '\(bundleID)' (is it playing?)") }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        try Self.check(AudioHardwareCreateProcessTap(tapDescription, &tap), "create process tap (audio capture permission?)")
        var formatAddress = address(kAudioTapPropertyFormat)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var tapFormat = AudioStreamBasicDescription()
        try Self.check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &tapFormat), "read tap format")
        formatLock.lock()
        currentFormat = tapFormat
        formatLock.unlock()

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "airtap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clock.uid]],
            kAudioAggregateDeviceTapListKey: [tapEntry],
        ]
        do {
            try Self.check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "create aggregate device")
            let sink = sink
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
                sink(input)
                for buffer in UnsafeMutableAudioBufferListPointer(output) where buffer.mData != nil {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
            }, "create IO proc")
            try Self.check(AudioDeviceStart(aggregate, ioProc), "start device")
        } catch {
            teardown()
            throw error
        }
        tappedProcesses = Set(processes)
        clockUID = clock.uid
    }

    private func teardown() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
        tappedProcesses = []
        clockUID = ""
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AirtapError.status(status, what) }
    }
}

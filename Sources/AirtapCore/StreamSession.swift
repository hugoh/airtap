import AppKit
import CoreAudio
import Foundation

private final class TapFeed: @unchecked Sendable {
    var feed: PCMFeed?
    var peak: Float = 0
}

/// Its mutable state is only touched by `start` and `stop`, which callers must not run concurrently.
extension StreamSession: @unchecked Sendable {}

/// Captures one app's audio and keeps it streaming to a named AirPlay speaker, reconnecting when the session dies.
public final class StreamSession {
    public typealias State = ReconnectingStream.State

    public var onState: ((State) -> Void)? {
        didSet { stream?.onState = onState }
    }

    /// Called once a second while streaming with how the stream is doing, and with nil while there is no connection.
    public var onHealth: ((StreamHealth?) -> Void)?

    private let app: String
    private let speakerName: String
    private let volume: Double
    private let tap = TapFeed()
    private var router: Router?
    private var stream: ReconnectingStream?
    private var meter: DispatchSourceTimer?
    private var powerObserver: PowerObserver?

    public init(app: String, speaker: String, volume: Double = 30) {
        self.app = app
        speakerName = speaker
        self.volume = volume
    }

    public func start() throws {
        let tap = tap
        let router = try Router(bundleID: app) { input in
            guard let feed = tap.feed else { return }
            Self.push(input, into: feed, tap: tap)
        }
        router.onFormatChange = { format in
            Log.info("capture", "tap sample rate is now \(Int(format.mSampleRate)) Hz")
            tap.feed?.reconfigure(inputRate: format.mSampleRate)
        }
        let format = router.format
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2 else {
            router.stop()
            throw AirPlayError(description: "unsupported tap format: \(format)")
        }
        let feed = PCMFeed(inputRate: format.mSampleRate)
        tap.feed = feed
        self.router = router
        Log.info("capture", "tapping '\(app)' at \(Int(format.mSampleRate)) Hz")

        let stream = ReconnectingStream(source: feed, volume: volume) { [speakerName] isCancelled in
            try Self.resolve(speakerName, isCancelled: isCancelled)
        }
        stream.onState = onState
        self.stream = stream
        powerObserver = PowerObserver(
            onSleep: { Log.info("power", "system will sleep") },
            onWake: { [weak stream] in
                Log.info("power", "system woke; reconnecting")
                stream?.restart(reason: "system woke from sleep")
            }
        )
        startMeter(stream: stream, feed: feed, sampleRate: Int(format.mSampleRate), router: router)
        stream.start()
    }

    public func stop() {
        stream?.stop()
        meter?.cancel()
        powerObserver = nil
        router?.stop()
        router = nil
        stream = nil
        Log.info("session", "stopped")
    }

    private static func resolve(_ name: String, isCancelled: () -> Bool) throws -> Speaker {
        if let direct = Speaker(address: name) { return direct }
        let result = SpeakerDiscovery.discoverDetailed(timeout: 10, matching: name, isCancelled: isCancelled)
        if let speaker = Speaker.bestMatch(for: name, in: result.speakers) {
            let candidates = result.speakers.filter { $0.name.localizedCaseInsensitiveContains(name) }
            if candidates.count > 1 { Log.info("session", "'\(name)' matches \(candidates.map(\.name)); using '\(speaker.name)'") }
            return speaker
        }
        if let offline = result.unreachable.first(where: { $0.localizedCaseInsensitiveContains(name) }) {
            throw AirPlayError(description: "'\(offline)' is announced on the network but not answering (powered off or asleep?)")
        }
        throw AirPlayError(description: "no AirPlay speaker named '\(name)' found (saw: \(result.speakers.map(\.name)))")
    }

    // MARK: Diagnostics

    private func startMeter(stream: ReconnectingStream, feed: PCMFeed, sampleRate: Int, router: Router) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "airtap.health"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        let tap = tap
        var reporter = HealthReporter(speakerName: speakerName)
        var mute = MutePolicy()
        timer.setEventHandler { [weak self, weak router] in
            let level = tap.peak
            tap.peak = 0
            Log.debug("capture") { String(format: "input level %.3f", level) }
            let connection = stream.connection
            if let muted = mute.evaluate(streaming: connection.connectedSince != nil, now: Clock.now()) { router?.setMuted(muted) }
            let health = reporter.report(connection: connection, feed: feed.stats, inputLevel: level, sampleRate: sampleRate, now: Clock.now())
            if let health, reporter.ticks % 5 == 0 { Log.debug("health") { health.summary } }
            self?.onHealth?(health)
        }
        timer.resume()
        meter = timer
    }

    private static func push(_ input: UnsafePointer<AudioBufferList>, into feed: PCMFeed, tap: TapFeed) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if buffers.count == 1, let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let frames = Int(buffers[0].mDataByteSize) / (2 * MemoryLayout<Float>.size)
            for index in 0..<frames * 2 { tap.peak = max(tap.peak, abs(samples[index])) }
            feed.push(samples, frames: frames)
        } else if buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            for frame in 0..<frames { tap.peak = max(tap.peak, abs(left[frame]), abs(right[frame])) }
            feed.push(left: left, right: right, frames: frames)
        }
    }
}

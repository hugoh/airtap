import Foundation

/// One AirPlay 2 session with transient pairing, streaming raw PCM over encrypted RTP.
/// Port of what pyatv does for RAOP receivers that support AirPlay 2.
///
/// `connect` and `startStreaming` are called in order from one thread; `stop` may be called from any thread at any
/// time, including while `connect` is still blocked on the network.
public final class AirPlaySender {
    private static let sampleRate = UInt64(AirPlayRequests.sampleRate)
    private static let framesPerPacket = AirPlayRequests.framesPerPacket
    private static let latency: UInt64 = 22050 + 44100
    private static let backlogSize = 1000
    private static let feedbackTimeout: TimeInterval = 3
    private static let teardownTimeout: TimeInterval = 2
    /// Two seconds of packets the kernel refused in a row is no longer a hiccup.
    private static let maxConsecutiveDrops = 250
    private let host: String
    private let port: UInt16
    private let volumePercent: Double

    private let stateLock = NSLock()
    private var rtsp: RTSPSession?
    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?
    private var audioSocket: UDPSocket?
    private var eventConnection: TCPConnection?
    private var cipher: AudioPacketCipher?
    private var remoteControlPort: UInt16 = 0
    private var stopped = false
    private var running = false
    private var timingActive = false
    private var failure: ((Error) -> Void)?
    private var startTimestamp: UInt64 = 0
    private var headTimestamp: UInt64 = 0
    private var sequence: UInt16 = 0
    private var backlog: [UInt16: Data] = [:]
    private var stats = StreamStats()
    private var source: PCMSource?

    public init(host: String, port: UInt16, volumePercent: Double = 30) {
        self.host = host
        self.port = port
        self.volumePercent = volumePercent
    }

    deinit { stop() }

    private func spawn(_ name: String, priority: QualityOfService, _ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = "airtap.\(name)"
        thread.qualityOfService = priority
        thread.start()
    }

    /// Stores a freshly opened resource, unless `stop` already ran: then nothing would ever close it, so close it here.
    private func keep<Resource>(_ resource: Resource, in slot: ReferenceWritableKeyPath<AirPlaySender, Resource?>, close: (Resource) -> Void) throws -> Resource {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else {
            close(resource)
            throw AirPlayError(description: "session was stopped while connecting")
        }
        self[keyPath: slot] = resource
        return resource
    }

    // MARK: Session setup

    /// Pairs, sets up the session and opens the audio channel. Blocks for a few seconds.
    public func connect() throws {
        Log.info("session", "connecting to \(host):\(port)")
        let rtsp = try keep(RTSPSession(link: AirPlayLink(connection: try TCPConnection(host: host, port: port))), in: \.rtsp) { $0.link.close() }
        let link = rtsp.link
        Log.debug("session") { "tcp connected, local address \(link.localAddress), session id \(rtsp.sessionID)" }
        let encryptionKeys = try AirPlayPairing.transient(over: link)
        link.enableEncryption(outKey: encryptionKeys.write, inKey: encryptionKeys.read)
        Log.debug("session") { "paired (transient), control channel encrypted" }

        _ = try rtsp.exchange("GET", uri: "/info", allowError: true)

        let control = try keep(UDPSocket(), in: \.controlSocket) { $0.close() }
        let timing = try keep(UDPSocket(), in: \.timingSocket) { $0.close() }
        // The speaker asks for timing while it processes the stream SETUP and will not reply until it gets an answer.
        stateLock.lock()
        timingActive = true
        stateLock.unlock()
        spawn("timing", priority: .userInteractive) { [self] in timingLoop(timing) }

        let sessionResponse = try rtsp.exchange("SETUP", body: AirPlayRequests.session(timingPort: timing.port))
        let sessionInfo = try RTSPSession.plist(sessionResponse.body)
        Log.debug("session") { "SETUP response: \(sessionInfo.keys.sorted())" }
        guard let eventPort = (sessionInfo["eventPort"] as? NSNumber)?.uint16Value else {
            throw AirPlayError(description: "speaker did not return an event port")
        }
        try openEventChannel(port: eventPort, shared: link.sharedSecret)

        let streamKey = hkdfExpand(salt: "Events-Salt", info: "Events-Write-Encryption-Key", secret: link.sharedSecret)
        let stream = AirPlayRequests.stream(controlPort: control.port, key: streamKey, connectionID: rtsp.sessionID)
        let streamResponse = try rtsp.exchange("SETUP", body: ["streams": [stream]])
        guard let granted = (try RTSPSession.plist(streamResponse.body)["streams"] as? [[String: Any]])?.first,
              let remoteControl = (granted["controlPort"] as? NSNumber)?.uint16Value,
              let dataPort = (granted["dataPort"] as? NSNumber)?.uint16Value
        else { throw AirPlayError(description: "speaker did not return stream ports") }

        Log.debug("session") { "stream ports: data=\(dataPort) control=\(remoteControl); local control=\(control.port) timing=\(timing.port)" }
        let audio = try keep(UDPSocket(), in: \.audioSocket) { $0.close() }
        try audio.connect(host: host, port: dataPort)
        stateLock.lock()
        remoteControlPort = remoteControl
        cipher = AudioPacketCipher(key: streamKey)
        stateLock.unlock()
        Log.info("session", "connected to \(host):\(port)")
    }

    private func openEventChannel(port: UInt16, shared: Data) throws {
        var opened: TCPConnection?
        var lastError: Error?
        for _ in 0..<5 where opened == nil {
            do {
                opened = try keep(TCPConnection(host: host, port: port), in: \.eventConnection) { $0.close() }
                Log.debug("events") { "connected to event port \(port)" }
            } catch let error as AirPlayError {
                throw error
            } catch {
                lastError = error
                Log.debug("events") { "event port \(port) not ready (\(error)), retrying" }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard let connection = opened else { throw lastError ?? AirPlayError(description: "event channel unavailable") }
        let session = HAPSession(
            outKey: hkdfExpand(salt: "Events-Salt", info: "Events-Read-Encryption-Key", secret: shared),
            inKey: hkdfExpand(salt: "Events-Salt", info: "Events-Write-Encryption-Key", secret: shared)
        )
        // Events are ignored, but unread data would eventually stall the speaker's side of the channel.
        spawn("events", priority: .utility) { [weak self, connection] in
            while true {
                do {
                    let chunk = try connection.receive(timeout: 1)
                    Log.debug("events") { "received \(chunk.count) bytes" }
                    _ = try? session.decrypt(chunk)
                } catch let error as NetworkError where error.description.hasPrefix("timed out") {
                    continue
                } catch {
                    guard let self, self.isRunning else {
                        Log.debug("events") { "event channel closed with the session" }
                        return
                    }
                    Log.info("events", "event channel closed: \(error)")
                    self.fail(AirPlayError(description: "event channel closed (\(error))"), from: "events")
                    return
                }
            }
        }
    }

    // MARK: Streaming

    /// Starts playback and returns immediately. `onFailure` fires once if the session dies.
    public func startStreaming(source: PCMSource, onFailure: @escaping (Error) -> Void) throws {
        stateLock.lock()
        guard !stopped, let audio = audioSocket, let control = controlSocket, let cipher, let rtsp else {
            stateLock.unlock()
            throw AirPlayError(description: "connect() first")
        }
        self.source = source
        stats = StreamStats()
        startTimestamp = NTP.toTimestamp(NTP.now(), rate: Self.sampleRate)
        headTimestamp = startTimestamp
        sequence = UInt16.random(in: 0...UInt16.max)
        backlog = [:]
        running = true
        failure = onFailure
        let initialSequence = sequence
        let controlPort = remoteControlPort
        stateLock.unlock()

        let controlAddress = try UDPSocket.address(host: host, port: controlPort)
        spawn("control", priority: .userInitiated) { [self] in controlLoop(control, destination: controlAddress) }

        try rtsp.exchange("RECORD")
        try rtsp.exchange("FLUSH", headers: [
            ("Range", "npt=0-"), ("Session", "0"), ("RTP-Info", "seq=\(initialSequence);rtptime=\(Self.latency)"),
        ])
        try rtsp.exchange("SET_PARAMETER", contentType: "text/parameters", text: "volume: \(Self.decibels(percent: volumePercent))")

        spawn("feedback", priority: .utility) { [self] in feedbackLoop(rtsp) }
        // Pacing audio is the one job here that must not wait behind other work.
        spawn("audio", priority: .userInteractive) { [self] in audioLoop(audio: audio, cipher: cipher, source: source, ssrc: rtsp.sessionID) }
        Log.info("stream", "streaming started (volume \(Int(volumePercent))%)")
    }

    static func decibels(percent: Double) -> Double { percent <= 0 ? -144 : -30 + percent * 0.3 }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func audioLoop(audio: UDPSocket, cipher: AudioPacketCipher, source: PCMSource, ssrc: UInt32) {
        var pacer = PacketPacer(start: Clock.now(), interval: Double(Self.framesPerPacket) / Double(Self.sampleRate))
        var consecutiveDrops = 0
        while isRunning {
            let lateMilliseconds: Double
            switch pacer.step(now: Clock.now()) {
            case .wait(let seconds):
                Thread.sleep(forTimeInterval: seconds)
                continue
            case .stalled(let seconds):
                return fail(AirPlayError(description: "streaming stalled for \(Int(seconds)) s (system sleep?)"), from: "audio")
            case .send(let late):
                lateMilliseconds = late
            }

            stateLock.lock()
            let seqno = sequence
            let timestamp = UInt32(truncatingIfNeeded: headTimestamp - startTimestamp + Self.latency)
            stateLock.unlock()
            let packet: Data
            var dropped = false
            do {
                packet = try cipher.packet(first: pacer.index == 0, seqno: seqno, timestamp: timestamp, ssrc: ssrc, audio: source.readPacket(frames: Self.framesPerPacket))
                do {
                    try audio.send(packet)
                    consecutiveDrops = 0
                } catch let error as NetworkError where error.isTransient && consecutiveDrops < Self.maxConsecutiveDrops {
                    // Keep the timeline moving; the speaker asks for the packet again if it matters.
                    consecutiveDrops += 1
                    dropped = true
                }
            } catch {
                return fail(error, from: "audio")
            }
            stateLock.lock()
            backlog[seqno] = packet
            backlog[seqno &- UInt16(Self.backlogSize)] = nil
            sequence = seqno &+ 1
            headTimestamp += UInt64(Self.framesPerPacket)
            stats.packetsSent += 1
            if dropped { stats.packetsDropped += 1 }
            stats.maxLateMilliseconds = max(stats.maxLateMilliseconds, lateMilliseconds)
            stateLock.unlock()
            pacer.advance()
        }
    }

    private func controlLoop(_ control: UDPSocket, destination: sockaddr_in) {
        var destination = destination
        var nextSync = ProcessInfo.processInfo.systemUptime
        var first = true
        while isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextSync {
                stateLock.lock()
                let ntp = NTP.fromTimestamp(headTimestamp, rate: Self.sampleRate)
                let rtpTime = UInt32(truncatingIfNeeded: headTimestamp - startTimestamp + Self.latency)
                stateLock.unlock()
                let parts = NTP.parts(ntp)
                let packet = RTP.sync(first: first, nowWithoutLatency: rtpTime &- UInt32(Self.latency), ntpSeconds: parts.seconds, ntpFraction: parts.fraction, now: rtpTime)
                do {
                    try control.send(packet, to: &destination)
                } catch let error as NetworkError where error.isTransient {
                    Log.debug("control") { "sync packet not sent: \(error)" }
                } catch {
                    return fail(error, from: "control")
                }
                logStats(rtpTime: rtpTime)
                first = false
                nextSync = now + 1
            }
            if let (data, from) = control.receive(timeout: max(0.01, nextSync - ProcessInfo.processInfo.systemUptime)) {
                resend(request: data, to: from, over: control)
            }
        }
    }

    private func logStats(rtpTime: UInt32) {
        stateLock.lock()
        let snapshot = stats
        let feed = source?.debugSummary ?? ""
        stats.maxLateMilliseconds = 0
        stateLock.unlock()
        Log.debug("stats") { "\(snapshot.summary(rtpTime: rtpTime)) \(feed)" }
    }

    private func resend(request: Data, to address: sockaddr_in, over control: UDPSocket) {
        guard request.count >= 8, request[request.startIndex + 1] & 0x7F == 0x55 else { return }
        let base = request.startIndex
        let lost = UInt16(request[base + 4]) << 8 | UInt16(request[base + 5])
        let count = UInt16(request[base + 6]) << 8 | UInt16(request[base + 7])
        var destination = address
        stateLock.lock()
        stats.retransmitRequests += 1
        stateLock.unlock()
        Log.debug("control") { "retransmit request: seq \(lost) x\(count)" }
        for offset in 0..<count {
            stateLock.lock()
            let packet = backlog[lost &+ offset]
            stateLock.unlock()
            guard let packet else {
                Log.debug("control") { "seq \(lost &+ offset) no longer in backlog" }
                continue
            }
            try? control.send(Data([0x80, 0xD6]) + packet[2..<4] + packet, to: &destination)
            stateLock.lock()
            stats.retransmitPacketsServed += 1
            stateLock.unlock()
        }
    }

    private var isTimingActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return timingActive
    }

    private func timingLoop(_ timing: UDPSocket) {
        while isTimingActive {
            guard let (data, from) = timing.receive(timeout: 0.25) else { continue }
            stateLock.lock()
            stats.timingRequests += 1
            stateLock.unlock()
            let parts = NTP.parts(NTP.now())
            var destination = from
            if let response = try? RTP.timingResponse(to: data, receivedSeconds: parts.seconds, receivedFraction: parts.fraction) {
                try? timing.send(response, to: &destination)
            }
        }
    }

    /// Keeps the session alive. Any reply, whatever its status, shows the speaker is there: some receivers do not
    /// implement `/feedback` and answer with an error. Only a dead or silent connection ends the session.
    private func feedbackLoop(_ rtsp: RTSPSession) {
        var failures = 0
        var reportedStatus = false
        while isRunning {
            Thread.sleep(forTimeInterval: 2)
            guard isRunning else { return }
            do {
                let response = try rtsp.exchange("POST", uri: "/feedback", allowError: true, timeout: Self.feedbackTimeout)
                if !(200..<300).contains(response.code), !reportedStatus {
                    reportedStatus = true
                    Log.debug("feedback") { "speaker answers keep-alives with status \(response.code); treating any answer as alive" }
                }
                failures = 0
                stateLock.lock()
                stats.feedbackSucceeded += 1
                stateLock.unlock()
            } catch {
                failures += 1
                stateLock.lock()
                stats.feedbackFailed += 1
                stateLock.unlock()
                guard isRunning else { return }
                Log.info("feedback", "keep-alive failed (\(failures)/3): \(error)")
                let isTimeout = (error as? NetworkError)?.description.hasPrefix("timed out") ?? false
                if !isTimeout || failures >= 3 { return fail(AirPlayError(description: "speaker stopped responding (\(error))"), from: "feedback") }
            }
        }
    }

    private func fail(_ error: Error, from origin: String) {
        stateLock.lock()
        let callback = running ? failure : nil
        running = false
        stateLock.unlock()
        if callback != nil { Log.info("stream", "failed in \(origin) loop: \(error)") }
        callback?(error)
    }

    /// Safe to call more than once and from any thread. Closing the sockets also unblocks a `connect` in progress.
    public func stop() {
        stateLock.lock()
        let wasRunning = running
        let session = rtsp
        let sockets = [controlSocket, timingSocket, audioSocket]
        let events = eventConnection
        running = false
        timingActive = false
        stopped = true
        rtsp = nil
        controlSocket = nil
        timingSocket = nil
        audioSocket = nil
        eventConnection = nil
        stateLock.unlock()

        Log.debug("session") { "stopping (was streaming: \(wasRunning))" }
        if wasRunning {
            // The speaker is often already gone when we stop, so do not let a polite goodbye delay the reconnect.
            do { try session?.exchange("TEARDOWN", headers: [("Session", "0")], timeout: Self.teardownTimeout) } catch { Log.debug("session") { "TEARDOWN failed: \(error)" } }
        }
        sockets.forEach { $0?.close() }
        events?.close()
        session?.link.close()
    }
}

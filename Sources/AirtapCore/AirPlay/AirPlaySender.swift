import Foundation

private struct StreamStats {
    var packetsSent = 0
    var maxLateMilliseconds = 0.0
    var retransmitRequests = 0
    var retransmitPacketsServed = 0
    var timingRequests = 0
    var feedbackSucceeded = 0
    var feedbackFailed = 0
}

/// One AirPlay 2 session with transient pairing, streaming raw PCM over encrypted RTP.
/// Port of what pyatv does for RAOP receivers that support AirPlay 2.
public final class AirPlaySender {
    private static let sampleRate: UInt64 = 44100
    private static let framesPerPacket = 352
    private static let latency: UInt64 = 22050 + 44100
    private static let backlogSize = 1000
    private static let feedbackTimeout: TimeInterval = 3
    private static let teardownTimeout: TimeInterval = 2
    private let host: String
    private let port: UInt16
    private let volumePercent: Double

    private var rtsp: RTSPSession?
    private var controlSocket: UDPSocket?
    private var timingSocket: UDPSocket?
    private var audioSocket: UDPSocket?
    private var eventConnection: TCPConnection?
    private var cipher: AudioPacketCipher?

    private let stateLock = NSLock()
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

    // MARK: Session setup

    /// Pairs, sets up the session and opens the audio channel. Blocks for a few seconds.
    public func connect() throws {
        Log.info("session", "connecting to \(host):\(port)")
        let link = AirPlayLink(connection: try TCPConnection(host: host, port: port))
        let rtsp = RTSPSession(link: link)
        self.rtsp = rtsp
        Log.debug("session") { "tcp connected, local address \(link.localAddress), session id \(rtsp.sessionID)" }
        let encryptionKeys = try AirPlayPairing.transient(over: link)
        link.enableEncryption(outKey: encryptionKeys.write, inKey: encryptionKeys.read)
        Log.debug("session") { "paired (transient), control channel encrypted" }

        _ = try rtsp.exchange("GET", uri: "/info", allowError: true)

        let control = try UDPSocket()
        let timing = try UDPSocket()
        controlSocket = control
        timingSocket = timing
        // The speaker asks for timing while it processes the stream SETUP and will not reply until it gets an answer.
        stateLock.lock()
        timingActive = true
        stateLock.unlock()
        Thread.detachNewThread { [self] in timingLoop() }

        let sessionResponse = try rtsp.exchange("SETUP", body: [
            "deviceID": "AA:BB:CC:DD:EE:FF",
            "sessionUUID": UUID().uuidString,
            "timingPort": Int(timing.port),
            "timingProtocol": "NTP",
            "isMultiSelectAirPlay": true,
            "groupContainsGroupLeader": false,
            "macAddress": "AA:BB:CC:DD:EE:FF",
            "model": "iPhone14,3",
            "name": "airtap",
            "osBuildVersion": "20F66",
            "osName": "iPhone OS",
            "osVersion": "16.5",
            "senderSupportsRelay": false,
            "sourceVersion": "690.7.1",
            "statsCollectionEnabled": false,
        ])
        let sessionInfo = try RTSPSession.plist(sessionResponse.body)
        Log.debug("session") { "SETUP response: \(sessionInfo.keys.sorted())" }
        guard let eventPort = (sessionInfo["eventPort"] as? NSNumber)?.uint16Value else {
            throw AirPlayError(description: "speaker did not return an event port")
        }
        try openEventChannel(port: eventPort, shared: link.sharedSecret)

        let streamKey = hkdfExpand(salt: "Events-Salt", info: "Events-Write-Encryption-Key", secret: link.sharedSecret)
        let stream: [String: Any] = [
            "audioFormat": 0x800,
            "audioMode": "default",
            "controlPort": Int(control.port),
            "ct": 1,
            "isMedia": true,
            "latencyMax": 88200,
            "latencyMin": 11025,
            "shk": streamKey,
            "spf": Self.framesPerPacket,
            "sr": Int(Self.sampleRate),
            "type": 0x60,
            "supportsDynamicStreamID": false,
            "streamConnectionID": Int(rtsp.sessionID),
        ]
        let streamResponse = try rtsp.exchange("SETUP", body: ["streams": [stream]])
        guard let granted = (try RTSPSession.plist(streamResponse.body)["streams"] as? [[String: Any]])?.first,
              let remoteControl = (granted["controlPort"] as? NSNumber)?.uint16Value,
              let dataPort = (granted["dataPort"] as? NSNumber)?.uint16Value
        else { throw AirPlayError(description: "speaker did not return stream ports") }

        remoteControlPort = remoteControl
        Log.debug("session") { "stream ports: data=\(dataPort) control=\(remoteControl); local control=\(control.port) timing=\(timing.port)" }
        let audio = try UDPSocket()
        try audio.connect(host: host, port: dataPort)
        audioSocket = audio
        cipher = AudioPacketCipher(key: streamKey)
        Log.info("session", "connected to \(host):\(port)")
    }

    private var remoteControlPort: UInt16 = 0

    private func openEventChannel(port: UInt16, shared: Data) throws {
        var lastError: Error?
        for _ in 0..<5 {
            do {
                eventConnection = try TCPConnection(host: host, port: port)
                Log.debug("events") { "connected to event port \(port)" }
                break
            } catch {
                lastError = error
                Log.debug("events") { "event port \(port) not ready (\(error)), retrying" }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard let connection = eventConnection else { throw lastError ?? AirPlayError(description: "event channel unavailable") }
        let session = HAPSession(
            outKey: hkdfExpand(salt: "Events-Salt", info: "Events-Read-Encryption-Key", secret: shared),
            inKey: hkdfExpand(salt: "Events-Salt", info: "Events-Write-Encryption-Key", secret: shared)
        )
        // Events are ignored, but unread data would eventually stall the speaker's side of the channel.
        Thread.detachNewThread { [weak self, weak connection] in
            while let connection {
                do {
                    let chunk = try connection.receive(timeout: 1)
                    Log.debug("events") { "received \(chunk.count) bytes" }
                    _ = try? session.decrypt(chunk)
                } catch let error as NetworkError where error.description.hasPrefix("timed out") {
                    continue
                } catch {
                    Log.info("events", "event channel closed: \(error)")
                    self?.fail(AirPlayError(description: "event channel closed (\(error))"), from: "events")
                    return
                }
            }
        }
    }

    // MARK: Streaming

    /// Starts playback and returns immediately. `onFailure` fires once if the session dies.
    public func startStreaming(source: PCMSource, onFailure: @escaping (Error) -> Void) throws {
        guard let audio = audioSocket, let cipher, let rtsp else { throw AirPlayError(description: "connect() first") }

        stateLock.lock()
        self.source = source
        stats = StreamStats()
        startTimestamp = NTP.toTimestamp(NTP.now(), rate: Self.sampleRate)
        headTimestamp = startTimestamp
        sequence = UInt16.random(in: 0...UInt16.max)
        backlog = [:]
        running = true
        failure = onFailure
        let initialSequence = sequence
        stateLock.unlock()

        Thread.detachNewThread { [self] in controlLoop() }

        try rtsp.exchange("RECORD")
        try rtsp.exchange("FLUSH", headers: [
            ("Range", "npt=0-"), ("Session", "0"), ("RTP-Info", "seq=\(initialSequence);rtptime=\(Self.latency)"),
        ])
        try rtsp.exchange("SET_PARAMETER", contentType: "text/parameters", text: "volume: \(Self.decibels(percent: volumePercent))")

        Thread.detachNewThread { [self] in feedbackLoop(rtsp) }
        Thread.detachNewThread { [self] in audioLoop(audio: audio, cipher: cipher, source: source, ssrc: rtsp.sessionID) }
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
            do {
                let packet = try cipher.packet(first: pacer.index == 0, seqno: seqno, timestamp: timestamp, ssrc: ssrc, audio: source.readPacket(frames: Self.framesPerPacket))
                try audio.send(packet)
                stateLock.lock()
                backlog[seqno] = packet
                backlog[seqno &- UInt16(Self.backlogSize)] = nil
                sequence = seqno &+ 1
                headTimestamp += UInt64(Self.framesPerPacket)
                stats.packetsSent += 1
                stats.maxLateMilliseconds = max(stats.maxLateMilliseconds, lateMilliseconds)
                stateLock.unlock()
            } catch {
                return fail(error, from: "audio")
            }
            pacer.advance()
        }
    }

    private func controlLoop() {
        guard let control = controlSocket else { return }
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
                do { try control.send(packet, to: host, port: remoteControlPort) } catch { return fail(error, from: "control") }
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
        Log.debug("stats") {
            "sent=\(snapshot.packetsSent) maxLate=\(Int(snapshot.maxLateMilliseconds))ms rtp=\(rtpTime) "
                + "retransmit=\(snapshot.retransmitRequests)req/\(snapshot.retransmitPacketsServed)pkts timing=\(snapshot.timingRequests) "
                + "feedback=\(snapshot.feedbackSucceeded)ok/\(snapshot.feedbackFailed)fail \(feed)"
        }
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

    private func timingLoop() {
        guard let timing = timingSocket else { return }
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

    private func feedbackLoop(_ rtsp: RTSPSession) {
        var failures = 0
        while isRunning {
            Thread.sleep(forTimeInterval: 2)
            guard isRunning else { return }
            do {
                try rtsp.exchange("POST", uri: "/feedback", timeout: Self.feedbackTimeout)
                failures = 0
                stateLock.lock()
                stats.feedbackSucceeded += 1
                stateLock.unlock()
            } catch {
                failures += 1
                stateLock.lock()
                stats.feedbackFailed += 1
                stateLock.unlock()
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

    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        timingActive = false
        stateLock.unlock()
        Log.debug("session") { "stopping (was streaming: \(wasRunning))" }
        if wasRunning {
            // The speaker is often already gone when we stop, so do not let a polite goodbye delay the reconnect.
            do { try rtsp?.exchange("TEARDOWN", headers: [("Session", "0")], timeout: Self.teardownTimeout) } catch { Log.debug("session") { "TEARDOWN failed: \(error)" } }
        }
        controlSocket?.close()
        timingSocket?.close()
        audioSocket?.close()
        eventConnection?.close()
        rtsp?.link.close()
        controlSocket = nil
        timingSocket = nil
        audioSocket = nil
        eventConnection = nil
        rtsp = nil
    }
}

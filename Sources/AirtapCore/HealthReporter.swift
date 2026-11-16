import Foundation

/// Turns what the sender, feed and tap report each second into a `StreamHealth`, remembering the last minute of it.
struct HealthReporter {
    private static let silenceSeconds = 10
    private static let silentLevel: Float = 0.0005

    let speakerName: String
    private(set) var ticks = 0
    private var window = HealthWindow()
    private var previousPackets = 0
    private var silentFor = 0

    init(speakerName: String) { self.speakerName = speakerName }

    mutating func report(connection: ReconnectingStream.Connection, feed: FeedStats, inputLevel: Float, sampleRate: Int, now: TimeInterval) -> StreamHealth? {
        ticks += 1
        silentFor = inputLevel < Self.silentLevel ? silentFor + 1 : 0
        guard let sender = connection.sender, let since = connection.connectedSince, let speaker = connection.speaker else {
            previousPackets = 0
            return nil
        }
        window.record(
            HealthSample(
                gaps: feed.underruns, dropped: sender.packetsDropped, resends: sender.retransmitRequests,
                keepAliveFailures: sender.feedbackFailed, latenessMilliseconds: Int(sender.maxLateMilliseconds)
            ),
            at: now
        )
        // The sender's counters start again from zero with every new session.
        let packetsPerSecond = sender.packetsSent >= previousPackets ? sender.packetsSent - previousPackets : sender.packetsSent
        previousPackets = sender.packetsSent
        return StreamHealth(
            speaker: speaker.name, address: "\(speaker.host):\(speaker.port)", assessment: window.assess(),
            pairingMilliseconds: sender.pairingMilliseconds, setupMilliseconds: sender.setupMilliseconds,
            uptimeSeconds: Int(Date().timeIntervalSince(since)), reconnects: connection.reconnects,
            lastReconnectReason: connection.lastReconnectReason, keepAliveMilliseconds: sender.keepAliveMilliseconds,
            packetsPerSecond: packetsPerSecond, resendsLastMinute: window.increase(\.resends),
            worstLatenessMilliseconds: Int(sender.maxLateMilliseconds), bufferMilliseconds: feed.bufferedMilliseconds,
            targetBufferMilliseconds: feed.targetMilliseconds, gapsLastMinute: window.increase(\.gaps),
            droppedLastMinute: window.increase(\.dropped), driftCorrections: feed.driftCorrections,
            inputLevel: inputLevel, isSilent: silentFor >= Self.silenceSeconds, tapSampleRate: sampleRate
        )
    }
}

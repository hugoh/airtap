import Foundation

/// Cumulative counters and the worst lateness of the last second, read once a second while streaming.
public struct HealthSample: Equatable {
    public var gaps: Int
    public var dropped: Int
    public var resends: Int
    public var keepAliveFailures: Int
    public var latenessMilliseconds: Int

    public init(gaps: Int, dropped: Int, resends: Int, keepAliveFailures: Int, latenessMilliseconds: Int) {
        self.gaps = gaps
        self.dropped = dropped
        self.resends = resends
        self.keepAliveFailures = keepAliveFailures
        self.latenessMilliseconds = latenessMilliseconds
    }
}

public struct HealthAssessment: Equatable {
    public enum Level: Equatable { case good, degraded }

    public var level: Level
    /// Most important first.
    public var problems: [String]

    public init(level: Level, problems: [String]) {
        self.level = level
        self.problems = problems
    }
}

/// Decides whether a stream is stable by looking at what happened in the last minute, so a single hiccup does not
/// flag a stream forever and a stream that keeps hiccuping does not look fine between them.
public struct HealthWindow {
    private static let span: TimeInterval = 60
    private static let latenessSpan: TimeInterval = 10
    private static let lateThresholdMilliseconds = 100
    private static let resendThreshold = 5

    private var samples: [(time: TimeInterval, sample: HealthSample)] = []

    public init() {}

    public mutating func record(_ sample: HealthSample, at time: TimeInterval) {
        samples.append((time, sample))
        samples.removeAll { time - $0.time > Self.span }
    }

    public func assess() -> HealthAssessment {
        guard let now = samples.last?.time else { return HealthAssessment(level: .good, problems: []) }
        var problems: [String] = []

        let gaps = increase(\.gaps)
        if gaps > 0 { problems.append("\(gaps) audio \(gaps == 1 ? "gap" : "gaps") in the last minute") }
        let dropped = increase(\.dropped)
        if dropped > 0 { problems.append("\(dropped) \(dropped == 1 ? "packet" : "packets") dropped before sending") }
        let late = samples.filter { now - $0.time <= Self.latenessSpan }.map(\.sample.latenessMilliseconds).max() ?? 0
        if late >= Self.lateThresholdMilliseconds { problems.append("Mac was slow sending audio (up to \(late) ms late)") }
        let failures = increase(\.keepAliveFailures)
        if failures > 0 { problems.append("speaker was slow to answer \(failures) \(failures == 1 ? "keep-alive" : "keep-alives")") }
        let resends = increase(\.resends)
        if resends >= Self.resendThreshold { problems.append("\(resends) packets lost on the network and resent") }

        return HealthAssessment(level: problems.isEmpty ? .good : .degraded, problems: problems)
    }

    /// Growth of a cumulative counter across the window. A counter that goes down belongs to a new session and
    /// started again from zero, so its new value is all growth.
    public func increase(_ counter: KeyPath<HealthSample, Int>) -> Int {
        zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            let before = pair.0.sample[keyPath: counter]
            let after = pair.1.sample[keyPath: counter]
            return total + (after >= before ? after - before : after)
        }
    }
}

/// Everything the menu shows about a running stream, as plain values, with the wording kept out of the UI.
public struct StreamHealth: Equatable {
    public struct Row: Equatable {
        public let label: String
        public let value: String
    }

    public struct Section: Equatable {
        public let title: String
        public let rows: [Row]
    }

    /// The protocol asks the speaker to buffer 1.5 s; its own rendering adds a little on top.
    private static let protocolDelaySeconds = 1.5
    private static let renderDelaySeconds = 0.07

    public var speaker: String
    public var address: String
    public var assessment: HealthAssessment
    public var pairingMilliseconds: Int
    public var setupMilliseconds: Int
    public var uptimeSeconds: Int
    public var reconnects: Int
    public var lastReconnectReason: String?
    public var keepAliveMilliseconds: Int?
    public var packetsPerSecond: Int
    public var resendsLastMinute: Int
    public var worstLatenessMilliseconds: Int
    public var bufferMilliseconds: Int
    public var targetBufferMilliseconds: Int
    public var gapsLastMinute: Int
    public var droppedLastMinute: Int
    public var driftCorrections: Int
    public var inputLevel: Float
    public var isSilent: Bool
    public var tapSampleRate: Int

    public init(
        speaker: String, address: String, assessment: HealthAssessment, pairingMilliseconds: Int, setupMilliseconds: Int,
        uptimeSeconds: Int, reconnects: Int, lastReconnectReason: String?, keepAliveMilliseconds: Int?, packetsPerSecond: Int,
        resendsLastMinute: Int, worstLatenessMilliseconds: Int, bufferMilliseconds: Int, targetBufferMilliseconds: Int,
        gapsLastMinute: Int, droppedLastMinute: Int, driftCorrections: Int, inputLevel: Float, isSilent: Bool, tapSampleRate: Int
    ) {
        self.speaker = speaker
        self.address = address
        self.assessment = assessment
        self.pairingMilliseconds = pairingMilliseconds
        self.setupMilliseconds = setupMilliseconds
        self.uptimeSeconds = uptimeSeconds
        self.reconnects = reconnects
        self.lastReconnectReason = lastReconnectReason
        self.keepAliveMilliseconds = keepAliveMilliseconds
        self.packetsPerSecond = packetsPerSecond
        self.resendsLastMinute = resendsLastMinute
        self.worstLatenessMilliseconds = worstLatenessMilliseconds
        self.bufferMilliseconds = bufferMilliseconds
        self.targetBufferMilliseconds = targetBufferMilliseconds
        self.gapsLastMinute = gapsLastMinute
        self.droppedLastMinute = droppedLastMinute
        self.driftCorrections = driftCorrections
        self.inputLevel = inputLevel
        self.isSilent = isSilent
        self.tapSampleRate = tapSampleRate
    }

    /// An estimate: the buffered audio plus what the speaker adds, not a measurement.
    public var delaySeconds: Double { Self.protocolDelaySeconds + Double(bufferMilliseconds) / 1000 + Self.renderDelaySeconds }

    public var summary: String {
        if assessment.level == .degraded { return "Unstable: " + assessment.problems.prefix(2).joined(separator: " · ") }
        let delay = "Streaming to \(speaker) · "
        return delay + (isSilent ? "the app is silent" : String(format: "delay ≈ %.1f s", delaySeconds))
    }

    public var sections: [Section] {
        [
            Section(title: "Connection", rows: [
                Row(label: "Speaker", value: "\(speaker) (\(address))"),
                Row(label: "Handshake", value: "pairing \(pairingMilliseconds) ms · setup \(setupMilliseconds) ms"),
                Row(label: "Connected for", value: Self.duration(seconds: uptimeSeconds)),
                Row(label: "Reconnects", value: reconnects == 0 ? "none" : "\(reconnects)" + (lastReconnectReason.map { " (last: \($0))" } ?? "")),
            ]),
            Section(title: "Stream", rows: [
                Row(label: "Keep-alive", value: keepAliveMilliseconds.map { "\($0) ms" } ?? "not yet measured"),
                Row(label: "Packets", value: "\(packetsPerSecond) per second"),
                Row(label: "Resends (1 min)", value: "\(resendsLastMinute)"),
                Row(label: "Slowest send", value: "\(worstLatenessMilliseconds) ms late"),
            ]),
            Section(title: "Audio", rows: [
                Row(label: "Buffer", value: "\(bufferMilliseconds) ms of \(targetBufferMilliseconds) ms"),
                Row(label: "Gaps (1 min)", value: "\(gapsLastMinute)"),
                Row(label: "Dropped (1 min)", value: "\(droppedLastMinute)"),
                Row(label: "Clock drift fixes", value: "\(driftCorrections)"),
                Row(label: "Input level", value: String(format: "%.2f · %d kHz", inputLevel, tapSampleRate / 1000)),
            ]),
        ]
    }

    public static func duration(seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) s"
        case ..<3600: "\(seconds / 60) min \(seconds % 60) s"
        default: "\(seconds / 3600) h \(seconds % 3600 / 60) min"
        }
    }
}

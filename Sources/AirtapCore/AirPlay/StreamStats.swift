import Foundation

/// Counters for one streaming session, logged once a second and shown in the menu.
public struct SenderStats: Equatable {
    public var packetsSent = 0
    public var packetsDropped = 0
    /// Worst lateness, in milliseconds, of any packet in the last second.
    public var maxLateMilliseconds = 0.0
    public var retransmitRequests = 0
    public var retransmitPacketsServed = 0
    public var timingRequests = 0
    public var feedbackSucceeded = 0
    public var feedbackFailed = 0
    /// Round trip of the latest keep-alive, once there has been one.
    public var keepAliveMilliseconds: Int?
    public var pairingMilliseconds = 0
    public var setupMilliseconds = 0

    public init() {}

    func summary(rtpTime: UInt32) -> String {
        "sent=\(packetsSent) dropped=\(packetsDropped) maxLate=\(Int(maxLateMilliseconds))ms rtp=\(rtpTime) "
            + "retransmit=\(retransmitRequests)req/\(retransmitPacketsServed)pkts timing=\(timingRequests) "
            + "feedback=\(feedbackSucceeded)ok/\(feedbackFailed)fail"
    }
}

/// The sender's counters, updated from its several threads.
final class StatsStore {
    private let lock = NSLock()
    private var current = SenderStats()
    private var latest = SenderStats()
    private var handshake = (pairing: 0, setup: 0)

    func update(_ change: (inout SenderStats) -> Void) {
        lock.lock()
        change(&current)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        current = SenderStats()
        latest = SenderStats()
        lock.unlock()
    }

    func recordHandshake(pairing: TimeInterval? = nil, setup: TimeInterval? = nil) {
        lock.lock()
        if let pairing { handshake.pairing = Int(pairing * 1000) }
        if let setup { handshake.setup = Int(setup * 1000) }
        lock.unlock()
    }

    /// Called once a second: publishes the counters and starts measuring the next second's worst lateness afresh.
    func takeSnapshot() -> SenderStats {
        lock.lock()
        defer { lock.unlock() }
        latest = current
        current.maxLateMilliseconds = 0
        return latest
    }

    var diagnostics: SenderStats {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = latest
        snapshot.pairingMilliseconds = handshake.pairing
        snapshot.setupMilliseconds = handshake.setup
        return snapshot
    }
}

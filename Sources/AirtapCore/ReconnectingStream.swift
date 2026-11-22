import Foundation

/// What the supervisor needs from a streaming session; `AirPlaySender` in production, a fake in tests.
/// `stop` must be safe to call from another thread while `connect` is still blocked.
protocol StreamingSession: AnyObject {
    func connect() throws
    func startStreaming(source: PCMSource, onFailure: @escaping (Error) -> Void) throws
    func stop()
    func setVolume(percent: Double)
    var senderStats: SenderStats? { get }
}

extension StreamingSession {
    var senderStats: SenderStats? { nil }
}

extension AirPlaySender: StreamingSession {
    var senderStats: SenderStats? { diagnostics }
}

/// Keeps one PCM source streaming to one speaker, reconnecting with backoff whenever the session fails.
public final class ReconnectingStream {
    public enum State: Equatable {
        case connecting
        case streaming(String)
        case reconnecting(String)
    }

    /// Where the stream stands, for display.
    public struct Connection: Equatable {
        public var speaker: Speaker?
        public var connectedSince: Date?
        public var reconnects = 0
        public var lastReconnectReason: String?
        public var sender: SenderStats?
    }

    /// Finds the speaker. It may take seconds, so it is handed a check for "stop was requested, give up".
    public typealias Resolve = (_ isCancelled: () -> Bool) throws -> Speaker

    private let source: PCMSource
    private let retryDelay: TimeInterval
    private let resolve: Resolve
    private let makeSession: (Speaker, Double) -> StreamingSession
    private var volume: Double

    private let condition = NSCondition()
    private var stopped = false
    private var finished = false
    private var restartReason: String?
    private var current: StreamingSession?
    private var stateHandler: ((State) -> Void)?
    private var speaker: Speaker?
    private var connectedSince: Date?
    private var reconnects = 0
    private var lastReconnectReason: String?

    public var connection: Connection {
        locked {
            Connection(
                speaker: speaker, connectedSince: connectedSince, reconnects: reconnects,
                lastReconnectReason: lastReconnectReason, sender: connectedSince == nil ? nil : current?.senderStats
            )
        }
    }

    public var onState: ((State) -> Void)? {
        get { locked { stateHandler } }
        set { locked { stateHandler = newValue } }
    }

    public convenience init(source: PCMSource, volume: Double, resolve: @escaping Resolve) {
        self.init(source: source, volume: volume, retryDelay: 1, resolve: resolve) {
            AirPlaySender(host: $0.host, port: $0.port, volumePercent: $1)
        }
    }

    init(source: PCMSource, volume: Double, retryDelay: TimeInterval, resolve: @escaping Resolve, makeSession: @escaping (Speaker, Double) -> StreamingSession) {
        self.source = source
        self.volume = volume
        self.retryDelay = retryDelay
        self.resolve = resolve
        self.makeSession = makeSession
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    public func start() {
        Thread.detachNewThread { [self] in supervise() }
    }

    /// Returns once the supervisor has let go of the speaker. A connect in progress is interrupted rather than awaited.
    public func stop() {
        condition.lock()
        stopped = true
        let session = current
        condition.broadcast()
        condition.unlock()

        session?.stop()

        condition.lock()
        let deadline = Date().addingTimeInterval(8)
        while !finished, condition.wait(until: deadline) {}
        condition.unlock()
    }

    /// Applies to the stream now and to every session that replaces it.
    public func setVolume(_ percent: Double) {
        let session = locked { () -> StreamingSession? in
            volume = percent
            return connectedSince == nil ? nil : current
        }
        session?.setVolume(percent: percent)
    }

    /// Drops the current session and connects again, e.g. after the Mac wakes from sleep.
    /// Requests that arrive before the reconnect happens are satisfied by that one reconnect.
    public func restart(reason: String) {
        condition.lock()
        if restartReason == nil { restartReason = reason }
        condition.broadcast()
        condition.unlock()
    }

    /// Doubles up to sixty times the base delay, so a speaker left off overnight is not searched for all night.
    static func nextBackoff(after current: TimeInterval, base: TimeInterval) -> TimeInterval {
        min(current * 2, base * 60)
    }

    private func supervise() {
        var backoff = retryDelay
        while !isStopped {
            publish(.connecting)
            locked { restartReason = nil }
            var session: StreamingSession?
            do {
                let speaker = try resolve { [self] in isStopped }
                let candidate = makeSession(speaker, locked { volume })
                session = candidate
                guard adopt(candidate) else { break }
                try candidate.connect()
                try candidate.startStreaming(source: source) { [self] error in restart(reason: "stream failed: \(error)") }
                locked {
                    self.speaker = speaker
                    connectedSince = Date()
                }
                publish(.streaming(speaker.name))
                backoff = retryDelay
                let reason = waitForRestartRequest()
                locked { connectedSince = nil }
                release(candidate)
                guard let reason else { break }
                noteReconnect(reason)
                Log.info("session", "restarting: \(reason)")
                publish(.reconnecting(reason))
                pause(retryDelay)
            } catch {
                if let session { release(session) }
                if isStopped { break }
                noteReconnect("\(error)")
                Log.info("session", "could not stream: \(error)")
                publish(.reconnecting("\(error)"))
                pause(backoff)
                backoff = Self.nextBackoff(after: backoff, base: retryDelay)
            }
        }
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    private var isStopped: Bool { locked { stopped } }

    private func noteReconnect(_ reason: String) {
        locked {
            reconnects += 1
            lastReconnectReason = reason.replacingOccurrences(of: "stream failed: ", with: "")
        }
    }

    /// Makes the session reachable by `stop`. Returns false if stop already happened, so it must not connect at all.
    private func adopt(_ session: StreamingSession) -> Bool {
        locked {
            guard !stopped else { return false }
            current = session
            return true
        }
    }

    private func release(_ session: StreamingSession) {
        locked { current = nil }
        session.stop()
    }

    /// Returns the reason to restart, or nil when the stream was stopped.
    private func waitForRestartRequest() -> String? {
        condition.lock()
        defer { condition.unlock() }
        while restartReason == nil, !stopped { condition.wait() }
        return stopped ? nil : restartReason
    }

    private func pause(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        while !stopped, condition.wait(until: deadline) {}
        condition.unlock()
    }

    private func publish(_ state: State) {
        Log.debug("state") { "\(state)" }
        onState?(state)
    }
}

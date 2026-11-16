import Foundation

/// What the supervisor needs from a streaming session; `AirPlaySender` in production, a fake in tests.
/// `stop` must be safe to call from another thread while `connect` is still blocked.
protocol StreamingSession: AnyObject {
    func connect() throws
    func startStreaming(source: PCMSource, onFailure: @escaping (Error) -> Void) throws
    func stop()
}

extension AirPlaySender: StreamingSession {}

/// Keeps one PCM source streaming to one speaker, reconnecting with backoff whenever the session fails.
public final class ReconnectingStream {
    public enum State: Equatable {
        case connecting
        case streaming(String)
        case reconnecting(String)
    }

    /// Finds the speaker. It may take seconds, so it is handed a check for "stop was requested, give up".
    public typealias Resolve = (_ isCancelled: () -> Bool) throws -> Speaker

    private let source: PCMSource
    private let retryDelay: TimeInterval
    private let resolve: Resolve
    private let makeSession: (Speaker) -> StreamingSession

    private let condition = NSCondition()
    private var stopped = false
    private var finished = false
    private var restartReason: String?
    private var current: StreamingSession?
    private var stateHandler: ((State) -> Void)?

    public var onState: ((State) -> Void)? {
        get { locked { stateHandler } }
        set { locked { stateHandler = newValue } }
    }

    public convenience init(source: PCMSource, volume: Double, resolve: @escaping Resolve) {
        self.init(source: source, volume: volume, retryDelay: 1, resolve: resolve) {
            AirPlaySender(host: $0.host, port: $0.port, volumePercent: volume)
        }
    }

    init(source: PCMSource, volume: Double, retryDelay: TimeInterval, resolve: @escaping Resolve, makeSession: @escaping (Speaker) -> StreamingSession) {
        self.source = source
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

    /// Drops the current session and connects again, e.g. after the Mac wakes from sleep.
    /// Requests that arrive before the reconnect happens are satisfied by that one reconnect.
    public func restart(reason: String) {
        condition.lock()
        if restartReason == nil { restartReason = reason }
        condition.broadcast()
        condition.unlock()
    }

    private func supervise() {
        var backoff = retryDelay
        while !isStopped {
            publish(.connecting)
            locked { restartReason = nil }
            var session: StreamingSession?
            do {
                let speaker = try resolve { [self] in isStopped }
                let candidate = makeSession(speaker)
                session = candidate
                guard adopt(candidate) else { break }
                try candidate.connect()
                try candidate.startStreaming(source: source) { [self] error in restart(reason: "stream failed: \(error)") }
                publish(.streaming(speaker.name))
                backoff = retryDelay
                let reason = waitForRestartRequest()
                release(candidate)
                guard let reason else { break }
                Log.info("session", "restarting: \(reason)")
                publish(.reconnecting(reason))
                pause(retryDelay)
            } catch {
                if let session { release(session) }
                if isStopped { break }
                Log.info("session", "could not stream: \(error)")
                publish(.reconnecting("\(error)"))
                pause(backoff)
                backoff = min(backoff * 2, max(retryDelay, 10))
            }
        }
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    private var isStopped: Bool { locked { stopped } }

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

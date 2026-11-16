import Foundation

/// What the supervisor needs from a streaming session; `AirPlaySender` in production, a fake in tests.
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

    public var onState: ((State) -> Void)?

    private let source: PCMSource
    private let retryDelay: TimeInterval
    private let resolve: () throws -> Speaker
    private let makeSession: (Speaker) -> StreamingSession

    private let condition = NSCondition()
    private var stopped = false
    private var finished = false
    private var restartReason: String?

    public convenience init(source: PCMSource, volume: Double, resolve: @escaping () throws -> Speaker) {
        self.init(source: source, volume: volume, retryDelay: 1, resolve: resolve) {
            AirPlaySender(host: $0.host, port: $0.port, volumePercent: volume)
        }
    }

    init(source: PCMSource, volume: Double, retryDelay: TimeInterval, resolve: @escaping () throws -> Speaker, makeSession: @escaping (Speaker) -> StreamingSession) {
        self.source = source
        self.retryDelay = retryDelay
        self.resolve = resolve
        self.makeSession = makeSession
    }

    public func start() {
        Thread.detachNewThread { [self] in supervise() }
    }

    public func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(5)
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
            clearRestartRequest()
            var session: StreamingSession?
            do {
                let speaker = try resolve()
                let candidate = makeSession(speaker)
                session = candidate
                try candidate.connect()
                try candidate.startStreaming(source: source) { [self] error in restart(reason: "stream failed: \(error)") }
                publish(.streaming(speaker.name))
                backoff = retryDelay
                let reason = waitForRestartRequest()
                candidate.stop()
                guard let reason else { break }
                Log.info("session", "restarting: \(reason)")
                publish(.reconnecting(reason))
                pause(retryDelay)
            } catch {
                session?.stop()
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

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private func clearRestartRequest() {
        condition.lock()
        restartReason = nil
        condition.unlock()
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

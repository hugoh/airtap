import XCTest
@testable import AirtapCore

private final class FakeSession: StreamingSession {
    var connectError: Error?
    private(set) var isStreaming = false
    private(set) var stopCount = 0
    private var onFailure: ((Error) -> Void)?
    private let lock = NSLock()

    func connect() throws {
        if let connectError { throw connectError }
    }

    func startStreaming(source: PCMSource, onFailure: @escaping (Error) -> Void) throws {
        lock.lock()
        self.onFailure = onFailure
        isStreaming = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopCount += 1
        isStreaming = false
        lock.unlock()
    }

    func failStream() {
        lock.lock()
        let callback = onFailure
        lock.unlock()
        callback?(AirPlayError(description: "boom"))
    }
}

private final class Silence: PCMSource {
    func readPacket(frames: Int) -> Data { Data(repeating: 0, count: frames * 4) }
}

final class ReconnectingStreamTests: XCTestCase {
    private var sessions: [FakeSession] = []
    private let lock = NSLock()
    private var nextConnectErrors: [Error?] = []

    private func makeStream() -> ReconnectingStream {
        ReconnectingStream(
            source: Silence(), volume: 30, retryDelay: 0.02,
            resolve: { Speaker(name: "Test", host: "127.0.0.1", port: 1) },
            makeSession: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                let session = FakeSession()
                if !nextConnectErrors.isEmpty { session.connectError = nextConnectErrors.removeFirst() }
                sessions.append(session)
                return session
            }
        )
    }

    private var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    private func session(_ index: Int) -> FakeSession {
        lock.lock()
        defer { lock.unlock() }
        return sessions[index]
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(condition(), what)
    }

    func testStreamFailureStartsANewSession() {
        let stream = makeStream()
        stream.start()
        waitUntil("first session streams") { sessionCount == 1 && session(0).isStreaming }

        session(0).failStream()

        waitUntil("second session streams") { sessionCount == 2 && session(1).isStreaming }
        XCTAssertEqual(session(0).stopCount, 1)
        stream.stop()
    }

    func testSimultaneousRestartRequestsCauseOneReconnect() {
        let stream = makeStream()
        stream.start()
        waitUntil("first session streams") { sessionCount == 1 && session(0).isStreaming }

        stream.restart(reason: "system woke")
        session(0).failStream()
        stream.restart(reason: "again")

        waitUntil("second session streams") { sessionCount == 2 && session(1).isStreaming }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sessionCount, 2, "leftover requests must not trigger another reconnect")
        XCTAssertTrue(session(1).isStreaming)
        stream.stop()
    }

    func testConnectFailureIsRetriedAndTheFailedSessionIsStopped() {
        nextConnectErrors = [AirPlayError(description: "refused"), AirPlayError(description: "refused"), nil]
        let stream = makeStream()
        var states: [ReconnectingStream.State] = []
        let stateLock = NSLock()
        stream.onState = { state in
            stateLock.lock()
            states.append(state)
            stateLock.unlock()
        }
        stream.start()

        waitUntil("third attempt streams") { sessionCount == 3 && session(2).isStreaming }
        XCTAssertEqual(session(0).stopCount, 1)
        XCTAssertEqual(session(1).stopCount, 1)
        stateLock.lock()
        XCTAssertTrue(states.contains(.reconnecting("refused")))
        XCTAssertEqual(states.last, .streaming("Test"))
        stateLock.unlock()
        stream.stop()
    }

    func testStopEndsTheSessionAndTheSupervisor() {
        let stream = makeStream()
        stream.start()
        waitUntil("first session streams") { sessionCount == 1 && session(0).isStreaming }

        stream.stop()

        XCTAssertFalse(session(0).isStreaming)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sessionCount, 1, "nothing reconnects after stop")
    }
}

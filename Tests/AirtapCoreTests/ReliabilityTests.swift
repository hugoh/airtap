import AppKit
import XCTest
@testable import AirtapCore

final class MutePolicyTests: XCTestCase {
    func testTheAppPlaysLocallyUntilTheStreamIsUp() {
        var policy = MutePolicy(graceSeconds: 5)
        XCTAssertFalse(policy.isMuted)
        XCTAssertNil(policy.evaluate(streaming: false, now: 0))
        XCTAssertNil(policy.evaluate(streaming: false, now: 30), "never connected: leave the app alone")
        XCTAssertEqual(policy.evaluate(streaming: true, now: 31), true)
        XCTAssertTrue(policy.isMuted)
    }

    func testABriefReconnectKeepsTheAppMuted() {
        var policy = MutePolicy(graceSeconds: 5)
        _ = policy.evaluate(streaming: true, now: 0)
        XCTAssertNil(policy.evaluate(streaming: false, now: 1))
        XCTAssertNil(policy.evaluate(streaming: false, now: 4.9))
        XCTAssertEqual(policy.evaluate(streaming: true, now: 5), nil, "back in time: nothing to change")
        XCTAssertTrue(policy.isMuted)
    }

    func testALongOutageGivesTheSoundBackToTheMac() {
        var policy = MutePolicy(graceSeconds: 5)
        _ = policy.evaluate(streaming: true, now: 0)
        XCTAssertNil(policy.evaluate(streaming: false, now: 2))
        XCTAssertEqual(policy.evaluate(streaming: false, now: 7.1), false)
        XCTAssertFalse(policy.isMuted)
        XCTAssertNil(policy.evaluate(streaming: false, now: 60), "already unmuted")
        XCTAssertEqual(policy.evaluate(streaming: true, now: 61), true, "muted again as soon as the speaker is back")
    }

    func testTheGraceRestartsWithEachOutage() {
        var policy = MutePolicy(graceSeconds: 5)
        _ = policy.evaluate(streaming: true, now: 0)
        _ = policy.evaluate(streaming: false, now: 3)
        _ = policy.evaluate(streaming: true, now: 4)
        XCTAssertNil(policy.evaluate(streaming: false, now: 6), "a new outage starts counting from its own first second")
        XCTAssertNil(policy.evaluate(streaming: false, now: 9.5), "3.5 s into it, not 6.5 s since the first outage")
        XCTAssertEqual(policy.evaluate(streaming: false, now: 11.5), false)
    }
}

final class BackoffTests: XCTestCase {
    func testDoublesFromTheBaseUpToSixtyTimesIt() {
        var delay = 1.0
        var seen: [Double] = []
        for _ in 0..<9 {
            seen.append(delay)
            delay = ReconnectingStream.nextBackoff(after: delay, base: 1)
        }
        XCTAssertEqual(seen, [1, 2, 4, 8, 16, 32, 60, 60, 60])
    }

    func testScalesWithTheBase() {
        XCTAssertEqual(ReconnectingStream.nextBackoff(after: 0.03, base: 0.01), 0.06, accuracy: 1e-9)
        XCTAssertEqual(ReconnectingStream.nextBackoff(after: 0.5, base: 0.01), 0.6, accuracy: 1e-9)
    }
}

final class PowerObserverTests: XCTestCase {
    func testWakeAndSleepReachTheirHandlers() {
        let center = NotificationCenter()
        var events: [String] = []
        let observer = PowerObserver(center: center, onSleep: { events.append("sleep") }, onWake: { events.append("wake") })

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(events, ["sleep", "wake"])
        withExtendedLifetime(observer) {}
    }

    func testNothingFiresAfterTheObserverIsGone() {
        let center = NotificationCenter()
        var wakes = 0
        var observer: PowerObserver? = PowerObserver(center: center, onSleep: {}, onWake: { wakes += 1 })
        observer = nil
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(wakes, 0)
        XCTAssertNil(observer)
    }
}

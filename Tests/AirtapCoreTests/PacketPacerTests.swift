import XCTest
@testable import AirtapCore

final class PacketPacerTests: XCTestCase {
    private let interval = 352.0 / 44100

    func testWaitsUntilThePacketIsDue() {
        var pacer = PacketPacer(start: 100, interval: interval)
        XCTAssertEqual(pacer.step(now: 100), .send(lateMilliseconds: 0))
        pacer.advance()
        guard case .wait(let seconds) = pacer.step(now: 100.001) else { return XCTFail("expected a wait") }
        XCTAssertEqual(seconds, interval - 0.001, accuracy: 1e-9)
    }

    func testOversleepingIsReportedAsLateness() {
        var pacer = PacketPacer(start: 100, interval: interval)
        pacer.advance()
        guard case .send(let late) = pacer.step(now: 100 + interval + 0.040) else { return XCTFail("expected a send") }
        XCTAssertEqual(late, 40, accuracy: 0.001)
    }

    func testCatchesUpWithBackToBackPackets() {
        var pacer = PacketPacer(start: 100, interval: interval)
        let now = 100 + 3 * interval
        var sent = 0
        while case .send = pacer.step(now: now) {
            pacer.advance()
            sent += 1
        }
        XCTAssertEqual(sent, 4)
    }

    func testLongGapIsAStallNotACatchUp() {
        let pacer = PacketPacer(start: 100, interval: interval)
        guard case .stalled(let seconds) = pacer.step(now: 130) else { return XCTFail("expected a stall") }
        XCTAssertEqual(seconds, 30, accuracy: 0.001)
    }

    func testClockKeepsCountingAndNeverGoesBackwards() {
        let first = Clock.now()
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertGreaterThan(Clock.now() - first, 0.015)
    }
}

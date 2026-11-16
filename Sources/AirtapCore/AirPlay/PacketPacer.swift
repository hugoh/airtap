import Foundation

/// Seconds on a clock that keeps running while the Mac sleeps, so a suspended stream shows up as a stall.
enum Clock {
    static func now() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }
}

/// Decides when each fixed-size packet is due, relative to the stream start.
struct PacketPacer {
    enum Step: Equatable {
        case wait(TimeInterval)
        case send(lateMilliseconds: Double)
        case stalled(seconds: TimeInterval)
    }

    private let start: TimeInterval
    private let interval: TimeInterval
    private let stallThreshold: TimeInterval
    private(set) var index = 0

    init(start: TimeInterval, interval: TimeInterval, stallThreshold: TimeInterval = 1) {
        self.start = start
        self.interval = interval
        self.stallThreshold = stallThreshold
    }

    func step(now: TimeInterval) -> Step {
        let late = now - (start + Double(index) * interval)
        if late < 0 { return .wait(-late) }
        return late > stallThreshold ? .stalled(seconds: late) : .send(lateMilliseconds: late * 1000)
    }

    mutating func advance() { index += 1 }
}

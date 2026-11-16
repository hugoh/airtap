import AppKit
import Foundation

/// Decides when the app being streamed should be silent on this Mac: only while the speaker has it. If the stream is
/// down for longer than a brief reconnect, the sound comes back here rather than disappearing completely.
struct MutePolicy {
    let graceSeconds: TimeInterval
    private(set) var isMuted = false
    private var outageStart: TimeInterval?

    init(graceSeconds: TimeInterval = 5) { self.graceSeconds = graceSeconds }

    /// Returns the new mute state when it should change, nil when it should stay as it is.
    mutating func evaluate(streaming: Bool, now: TimeInterval) -> Bool? {
        if streaming {
            outageStart = nil
            guard !isMuted else { return nil }
            isMuted = true
            return true
        }
        guard isMuted else { return nil }
        let start = outageStart ?? now
        outageStart = start
        guard now - start > graceSeconds else { return nil }
        isMuted = false
        return false
    }
}

/// Tells the session when the Mac goes to sleep and when it wakes, which is when a stream most likely died.
final class PowerObserver {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter, onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.center = center
        tokens = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in onSleep() },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in onWake() },
        ]
    }

    deinit { tokens.forEach { center.removeObserver($0) } }
}

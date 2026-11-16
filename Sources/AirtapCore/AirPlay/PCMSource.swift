import Foundation

/// Everything that can go wrong between the tap and the speaker, described for a person. Socket failures keep
/// their error code in `NetworkError`, which is the only other error type.
public struct AirPlayError: Error, CustomStringConvertible {
    public let description: String

    static func status(_ status: OSStatus, _ what: String) -> AirPlayError {
        AirPlayError(description: "\(what) failed (OSStatus \(status))")
    }
}

/// Supplies stereo 16-bit big-endian PCM at 44.1 kHz, exactly `frames` frames per call (silence if starved).
public protocol PCMSource: AnyObject {
    func readPacket(frames: Int) -> Data
    var debugSummary: String { get }
}

public extension PCMSource {
    var debugSummary: String { "" }
}

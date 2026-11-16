import Foundation

public struct AirPlayError: Error, CustomStringConvertible {
    public let description: String
}

/// Supplies stereo 16-bit big-endian PCM at 44.1 kHz, exactly `frames` frames per call (silence if starved).
public protocol PCMSource: AnyObject {
    func readPacket(frames: Int) -> Data
    var debugSummary: String { get }
}

public extension PCMSource {
    var debugSummary: String { "" }
}

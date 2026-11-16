import CryptoKit
import Foundation

enum NTP {
    private static let unixToNtpSeconds: UInt64 = 0x83AA_7E80

    static func now() -> UInt64 {
        var spec = timespec()
        clock_gettime(CLOCK_REALTIME, &spec)
        let micros = UInt64(spec.tv_nsec) / 1000
        return (UInt64(spec.tv_sec) + unixToNtpSeconds) << 32 | (micros << 32) / 1_000_000
    }

    static func parts(_ ntp: UInt64) -> (seconds: UInt32, fraction: UInt32) {
        (UInt32(truncatingIfNeeded: ntp >> 32), UInt32(truncatingIfNeeded: ntp))
    }

    static func toTimestamp(_ ntp: UInt64, rate: UInt64) -> UInt64 { ((ntp >> 16) * rate) >> 16 }

    static func fromTimestamp(_ timestamp: UInt64, rate: UInt64) -> UInt64 { ((timestamp << 16) / rate) << 16 }
}

struct RTPError: Error, CustomStringConvertible {
    let description: String
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

enum RTP {
    static func sync(first: Bool, nowWithoutLatency: UInt32, ntpSeconds: UInt32, ntpFraction: UInt32, now: UInt32) -> Data {
        var packet = Data([first ? 0x90 : 0x80, 0xD4, 0x00, 0x07])
        packet.appendBigEndian(nowWithoutLatency)
        packet.appendBigEndian(ntpSeconds)
        packet.appendBigEndian(ntpFraction)
        packet.appendBigEndian(now)
        return packet
    }

    /// Answers a 32 byte timing request: echoes the sender's transmit time and stamps receive and send with now.
    static func timingResponse(to request: Data, receivedSeconds: UInt32, receivedFraction: UInt32) throws -> Data {
        guard request.count >= 32 else { throw RTPError(description: "timing request too short (\(request.count) bytes)") }
        let base = request.startIndex
        var packet = Data([request[base], 0xD3, 0x00, 0x07, 0, 0, 0, 0])
        packet += request[base + 24 ..< base + 32]
        for _ in 0..<2 {
            packet.appendBigEndian(receivedSeconds)
            packet.appendBigEndian(receivedFraction)
        }
        return packet
    }
}

/// Encrypts RTP audio packets: header, ChaCha20-Poly1305 payload (AAD is timestamp + ssrc), then the 8 byte nonce counter.
final class AudioPacketCipher {
    private let key: SymmetricKey
    private var nonce = CounterNonce()

    init(key: Data) { self.key = SymmetricKey(data: key) }

    func packet(first: Bool, seqno: UInt16, timestamp: UInt32, ssrc: UInt32, audio: Data) throws -> Data {
        var header = Data([0x80, first ? 0xE0 : 0x60])
        header.appendBigEndian(seqno)
        header.appendBigEndian(timestamp)
        header.appendBigEndian(ssrc)
        let counter = nonce.bytes.suffix(8)
        let box = try ChaChaPoly.seal(audio, using: key, nonce: nonce.next(), authenticating: header[4..<12])
        return header + box.ciphertext + box.tag + counter
    }
}

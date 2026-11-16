import CryptoKit
import Foundation

/// ChaCha20-Poly1305 with the 4 zero bytes + 8 byte little-endian counter nonce HAP uses.
struct CounterNonce {
    private(set) var counter: UInt64 = 0

    var bytes: Data { Data(repeating: 0, count: 4) + withUnsafeBytes(of: counter.littleEndian) { Data($0) } }

    mutating func next() throws -> ChaChaPoly.Nonce {
        defer { counter += 1 }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

/// HAP transport encryption: frames of up to 1024 bytes, each prefixed with its little-endian length (also the AAD).
final class HAPSession {
    private static let frameLength = 1024
    private static let tagLength = 16

    private let outKey: SymmetricKey
    private let inKey: SymmetricKey
    private var outNonce = CounterNonce()
    private var inNonce = CounterNonce()
    private var pending = Data()

    init(outKey: Data, inKey: Data) {
        self.outKey = SymmetricKey(data: outKey)
        self.inKey = SymmetricKey(data: inKey)
    }

    func encrypt(_ data: Data) throws -> Data {
        var output = Data()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + Self.frameLength, data.endIndex)
            let length = withUnsafeBytes(of: UInt16(end - offset).littleEndian) { Data($0) }
            let box = try ChaChaPoly.seal(data[offset..<end], using: outKey, nonce: outNonce.next(), authenticating: length)
            output += length + box.ciphertext + box.tag
            offset = end
        }
        return output
    }

    var bufferedByteCount: Int { pending.count }

    /// After a frame fails to authenticate the stream is out of step for good, so what is buffered can never be
    /// decoded; drop it instead of piling up everything that arrives afterwards.
    func decrypt(_ data: Data) throws -> Data {
        do {
            return try decode(data)
        } catch {
            pending = Data()
            throw error
        }
    }

    private func decode(_ data: Data) throws -> Data {
        pending += data
        var output = Data()
        while pending.count >= 2 {
            let base = pending.startIndex
            let length = Int(pending[base]) | Int(pending[base + 1]) << 8
            let frameEnd = base + 2 + length + Self.tagLength
            guard pending.endIndex >= frameEnd else { break }
            let aad = pending[base ..< base + 2]
            let box = try ChaChaPoly.SealedBox(
                nonce: inNonce.next(),
                ciphertext: pending[base + 2 ..< base + 2 + length],
                tag: pending[base + 2 + length ..< frameEnd]
            )
            do {
                output += try ChaChaPoly.open(box, using: inKey, authenticating: aad)
            } catch {
                throw AirPlayError(description: "frame failed authentication")
            }
            pending = Data(pending[frameEnd...])
        }
        return output
    }
}

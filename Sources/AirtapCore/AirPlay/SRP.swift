import BigInt
import CryptoKit
import Foundation

struct SRPResult {
    /// The client's proof, sent to the speaker.
    let proof: Data
    let sessionKey: Data
    /// What the speaker must send back to show it derived the same key.
    let serverProof: Data
}

/// SRP-6a client as used by HAP pairing, matching srptools byte for byte: hashed integers are
/// serialized without leading zeros except where the group padding is explicit.
struct SRPClient {
    private static let prime = BigUInt(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74" +
    "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" +
    "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" +
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" +
    "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb" +
    "9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" +
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718" +
    "3995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33" +
    "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" +
    "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864" +
    "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e2" +
    "08e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff"
        , radix: 16)!
    private static let generator = BigUInt(5)
    private static let width = 384

    private let privateValue: BigUInt
    private let user: String
    private let pin: String
    let publicKey: Data

    init(privateKey: Data, user: String, pin: String) {
        privateValue = BigUInt(privateKey)
        self.user = user
        self.pin = pin
        publicKey = Self.minimal(Self.generator.power(privateValue, modulus: Self.prime))
    }

    mutating func process(serverPublic: Data, salt: Data) throws -> SRPResult {
        let n = Self.prime
        let b = BigUInt(serverPublic)
        guard b % n != 0 else { throw AirPlayError(description: "invalid server public key") }
        let a = Self.generator.power(privateValue, modulus: n)

        let k = Self.hashInt(Self.minimal(n), Self.padded(Self.generator))
        let u = Self.hashInt(Self.padded(a), Self.padded(b))
        let credentialHash = Data(SHA512.hash(data: Data("\(user):\(pin)".utf8)))
        let x = Self.hashInt(Self.minimal(BigUInt(salt)), credentialHash)
        let v = Self.generator.power(x, modulus: n)

        let base = (b + n * k - (k * v) % n) % n
        let secret = base.power(privateValue + u * x, modulus: n)
        let sessionKey = Data(SHA512.hash(data: Self.minimal(secret)))

        let groupHash = Self.hashInt(Self.minimal(n)) ^ Self.hashInt(Self.minimal(Self.generator))
        var proofInput = Self.minimal(groupHash)
        proofInput += Self.digest(Data(user.utf8))
        proofInput += Self.minimal(BigUInt(salt))
        proofInput += Self.minimal(a)
        proofInput += Self.minimal(b)
        proofInput += sessionKey
        let proof = Self.digest(proofInput)
        return SRPResult(proof: proof, sessionKey: sessionKey, serverProof: Self.digest(Self.minimal(a) + proof + sessionKey))
    }

    private static func minimal(_ value: BigUInt) -> Data {
        let bytes = value.serialize()
        return bytes.isEmpty ? Data([0]) : bytes
    }

    private static func padded(_ value: BigUInt) -> Data {
        let bytes = value.serialize()
        return Data(repeating: 0, count: max(0, width - bytes.count)) + bytes
    }

    private static func digest(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }

    private static func hashInt(_ parts: Data...) -> BigUInt {
        BigUInt(digest(parts.reduce(Data(), +)))
    }
}

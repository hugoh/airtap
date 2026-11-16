import CryptoKit
import Foundation

/// HAP transient pairing: SRP with the fixed PIN every AirPlay 2 receiver accepts, without storing credentials.
enum AirPlayPairing {
    private static let headers: [(String, String)] = [
        ("User-Agent", "AirPlay/320.20"), ("Connection", "keep-alive"), ("X-Apple-HKP", "4"), ("Content-Type", "application/octet-stream"),
    ]

    /// Returns the keys for the encrypted control channel and stores the shared secret on the link.
    static func transient(over link: AirPlayLink) throws -> (write: Data, read: Data) {
        _ = try link.request(method: "POST", uri: "/pair-pin-start", headers: headers)
        let first = try link.request(
            method: "POST", uri: "/pair-setup", headers: headers,
            body: TLV8.encode([(TLV8.method, Data([0])), (TLV8.sequence, Data([1])), (TLV8.flags, Data([0x10]))])
        )
        let challenge = try Self.pairingResponse(first)
        guard let salt = challenge[TLV8.salt], let serverKey = challenge[TLV8.publicKey] else {
            throw AirPlayError(description: "pairing response missing salt or public key")
        }
        var srp = SRPClient(privateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }), user: "Pair-Setup", pin: "3939")
        let result = try srp.process(serverPublic: serverKey, salt: salt)
        let second = try link.request(
            method: "POST", uri: "/pair-setup", headers: headers,
            body: TLV8.encode([(TLV8.sequence, Data([3])), (TLV8.publicKey, srp.publicKey), (TLV8.proof, result.proof)])
        )
        guard let serverProof = try Self.pairingResponse(second)[TLV8.proof], SymmetricKey(data: serverProof) == SymmetricKey(data: result.serverProof) else {
            throw AirPlayError(description: "speaker did not prove it knows the pairing secret")
        }
        link.sharedSecret = result.sessionKey
        return (
            hkdfExpand(salt: "Control-Salt", info: "Control-Write-Encryption-Key", secret: result.sessionKey),
            hkdfExpand(salt: "Control-Salt", info: "Control-Read-Encryption-Key", secret: result.sessionKey)
        )
    }

    private static func pairingResponse(_ response: HTTPResponse) throws -> [UInt8: Data] {
        let tlv = TLV8.decode(response.body)
        if let error = tlv[TLV8.error] { throw AirPlayError(description: "pairing rejected (error \(error.first ?? 0))") }
        return tlv
    }
}

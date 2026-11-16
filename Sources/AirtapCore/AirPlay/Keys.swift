import CryptoKit
import Foundation

func hkdfExpand(salt: String, info: String, secret: Data) -> Data {
    let key = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: secret),
        salt: Data(salt.utf8),
        info: Data(info.utf8),
        outputByteCount: 32
    )
    return key.withUnsafeBytes { Data($0) }
}

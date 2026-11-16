import Foundation

enum TLV8 {
    static let method: UInt8 = 0x00
    static let salt: UInt8 = 0x02
    static let publicKey: UInt8 = 0x03
    static let proof: UInt8 = 0x04
    static let sequence: UInt8 = 0x06
    static let error: UInt8 = 0x07
    static let flags: UInt8 = 0x13

    static func encode(_ items: [(UInt8, Data)]) -> Data {
        var output = Data()
        for (tag, value) in items {
            var offset = 0
            repeat {
                let size = min(255, value.count - offset)
                output += [tag, UInt8(size)] + value[value.startIndex + offset ..< value.startIndex + offset + size]
                offset += size
            } while offset < value.count
        }
        return output
    }

    /// Fragments sharing a tag are joined, which is how values over 255 bytes are carried.
    static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var position = data.startIndex
        while position + 2 <= data.endIndex {
            let tag = data[position]
            let end = min(data.endIndex, position + 2 + Int(data[position + 1]))
            result[tag, default: Data()] += data[position + 2 ..< end]
            position = end
        }
        return result
    }
}

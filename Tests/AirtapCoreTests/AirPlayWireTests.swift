import XCTest
@testable import AirtapCore

extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...hex.index(hex.startIndex, offsetBy: $0 + 1)], radix: 16)!
        })
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

final class TLV8Tests: XCTestCase {
    func testEncodeSplitsValuesOver255Bytes() {
        let items: [(UInt8, Data)] = [(0, Data([0])), (6, Data([1])), (3, Data(0...255) + Data([1, 2]))]
        XCTAssertEqual(TLV8.encode(items).hex, Vectors.tlv)
    }

    func testDecodeJoinsFragments() {
        let decoded = TLV8.decode(Data(hex: Vectors.tlv))
        XCTAssertEqual(decoded[3], Data(0...255) + Data([1, 2]))
        XCTAssertEqual(decoded[6], Data([1]))
    }
}

final class SRPTests: XCTestCase {
    func testMatchesSrptoolsClient() throws {
        var srp = SRPClient(privateKey: Data(hex: Vectors.srpPrivate), user: "Pair-Setup", pin: "3939")
        XCTAssertEqual(srp.publicKey.hex, Vectors.srpClientPublic)
        let result = try srp.process(serverPublic: Data(hex: Vectors.srpServerPublic), salt: Data(hex: Vectors.srpSalt))
        XCTAssertEqual(result.proof.hex, Vectors.srpProof)
        XCTAssertEqual(result.sessionKey.hex, Vectors.srpSessionKey)
        XCTAssertEqual(result.serverProof.hex, Vectors.srpServerProof)
    }

    func testRejectsZeroServerKey() {
        var srp = SRPClient(privateKey: Data(hex: Vectors.srpPrivate), user: "Pair-Setup", pin: "3939")
        XCTAssertThrowsError(try srp.process(serverPublic: Data([0]), salt: Data(hex: Vectors.srpSalt)))
    }
}

final class KeyDerivationTests: XCTestCase {
    func testHKDFMatchesPyatv() {
        let shared = Data(hex: Vectors.srpSessionKey)
        XCTAssertEqual(hkdfExpand(salt: "Control-Salt", info: "Control-Write-Encryption-Key", secret: shared).hex, Vectors.hkdfControlWrite)
        XCTAssertEqual(hkdfExpand(salt: "Control-Salt", info: "Control-Read-Encryption-Key", secret: shared).hex, Vectors.hkdfControlRead)
        XCTAssertEqual(hkdfExpand(salt: "Events-Salt", info: "Events-Write-Encryption-Key", secret: shared).hex, Vectors.hkdfEventsWrite)
    }
}

final class HAPSessionTests: XCTestCase {
    private let writeKey = Data(hex: Vectors.hkdfControlWrite)
    private let readKey = Data(hex: Vectors.hkdfControlRead)
    private let plain = Data(hex: Vectors.hapPlain)

    func testEncryptMatchesPyatv() throws {
        let session = HAPSession(outKey: writeKey, inKey: readKey)
        let frames = try session.encrypt(plain) + session.encrypt(Data("second message".utf8))
        XCTAssertEqual(frames.hex, Vectors.hapFramesTwoMessages)
    }

    func testDecryptsPyatvFramesFedInArbitraryChunks() throws {
        let receiver = HAPSession(outKey: readKey, inKey: writeKey)
        var output = Data()
        let frames = Data(hex: Vectors.hapFramesTwoMessages)
        for start in stride(from: 0, to: frames.count, by: 97) {
            output += try receiver.decrypt(frames[start..<min(start + 97, frames.count)])
        }
        XCTAssertEqual(output, plain + Data("second message".utf8))
    }

    func testAFailedFrameDoesNotLeaveABacklogThatGrowsForever() throws {
        let receiver = HAPSession(outKey: readKey, inKey: writeKey)
        var frames = Data(hex: Vectors.hapFramesTwoMessages)
        frames[10] ^= 1
        XCTAssertThrowsError(try receiver.decrypt(frames))
        XCTAssertEqual(receiver.bufferedByteCount, 0, "nothing after a broken frame can be decoded, so nothing is kept")
        for _ in 0..<20 { _ = try? receiver.decrypt(Data(repeating: 7, count: 500)) }
        XCTAssertLessThan(receiver.bufferedByteCount, 600, "later garbage must not pile up")
    }

    func testTamperedFrameThrows() {
        let receiver = HAPSession(outKey: readKey, inKey: writeKey)
        var frames = Data(hex: Vectors.hapFramesTwoMessages)
        frames[10] ^= 1
        XCTAssertThrowsError(try receiver.decrypt(frames))
    }
}

final class RTPTests: XCTestCase {
    func testAudioPacketsMatchPyatv() throws {
        let cipher = AudioPacketCipher(key: Data(hex: Vectors.audioKey))
        let audio = Data(hex: Vectors.audioPayload)
        let first = try cipher.packet(first: true, seqno: 0xFFFE, timestamp: 123456789 + 0xFFFE, ssrc: 0xCAFEBABE, audio: audio)
        let second = try cipher.packet(first: false, seqno: 0xFFFF, timestamp: 123456789 + 0xFFFF, ssrc: 0xCAFEBABE, audio: audio)
        XCTAssertEqual(first.hex, Vectors.audioPacket0)
        XCTAssertEqual(second.hex, Vectors.audioPacket1)
    }

    func testSyncPackets() {
        XCTAssertEqual(RTP.sync(first: true, nowWithoutLatency: 1000, ntpSeconds: 3_000_000_000, ntpFraction: 123456, now: 67600).hex, Vectors.syncFirst)
        XCTAssertEqual(RTP.sync(first: false, nowWithoutLatency: 1000, ntpSeconds: 3_000_000_001, ntpFraction: 654321, now: 67600).hex, Vectors.syncLater)
    }

    func testTimingResponseEchoesSendTime() throws {
        let response = try RTP.timingResponse(to: Data(hex: Vectors.timingRequest), receivedSeconds: 3_900_000_005, receivedFraction: 99)
        XCTAssertEqual(response.hex, Vectors.timingResponse)
    }

    func testTimingResponseRejectsShortPackets() {
        XCTAssertThrowsError(try RTP.timingResponse(to: Data([1, 2, 3]), receivedSeconds: 0, receivedFraction: 0))
    }

    func testNtpConversionsMatchPyatv() {
        let ntp = UInt64(Vectors.ntpSample)!
        XCTAssertEqual(NTP.toTimestamp(ntp, rate: 44100), UInt64(Vectors.ntpToTs44100)!)
        XCTAssertEqual(NTP.fromTimestamp(172_800_000, rate: 44100), UInt64(Vectors.tsToNtp)!)
    }
}

final class VolumeTests: XCTestCase {
    func testPercentMapsToDecibelsLikePyatv() {
        XCTAssertEqual(AirPlaySender.decibels(percent: 0), -144)
        XCTAssertEqual(AirPlaySender.decibels(percent: 100), 0, accuracy: 0.0001)
        XCTAssertEqual(AirPlaySender.decibels(percent: 50), -15, accuracy: 0.0001)
        XCTAssertEqual(AirPlaySender.decibels(percent: 15), -25.5, accuracy: 0.0001)
    }

    func testOutOfRangeVolumeNeverBecomesLouderThanFullScale() {
        XCTAssertEqual(AirPlaySender.decibels(percent: 150), 0, accuracy: 0.0001)
        XCTAssertEqual(AirPlaySender.decibels(percent: 300), 0, accuracy: 0.0001)
        XCTAssertEqual(AirPlaySender.decibels(percent: -20), -144)
        XCTAssertEqual(AirPlaySender.decibels(percent: .nan), -144, "garbage means mute, never a loud guess")
        XCTAssertEqual(AirPlaySender.decibels(percent: .infinity), 0)
    }
}

final class SpeakerAddressTests: XCTestCase {
    func testParsesAnIPv4AddressWithPort() {
        XCTAssertEqual(Speaker(address: "192.168.68.27:7000"), Speaker(name: "192.168.68.27:7000", host: "192.168.68.27", port: 7000))
    }

    func testSpeakerNamesAreNotAddresses() {
        for name in ["Kitchen", "Living Room", "192.168.68.27", "host.local:7000", "1.2.3.4:0", "1.2.3.4:99999", "Studio: Left"] {
            XCTAssertNil(Speaker(address: name), name)
        }
    }
}

final class SpeakerMatchTests: XCTestCase {
    private let speakers = [
        Speaker(name: "Kitchen Display", host: "10.0.0.1", port: 7000),
        Speaker(name: "Kitchen", host: "10.0.0.2", port: 7000),
        Speaker(name: "Bedroom", host: "10.0.0.3", port: 7000),
    ]

    func testAnExactNameBeatsALongerNameThatContainsIt() {
        XCTAssertEqual(Speaker.bestMatch(for: "kitchen", in: speakers)?.host, "10.0.0.2")
    }

    func testFallsBackToASubstringMatch() {
        XCTAssertEqual(Speaker.bestMatch(for: "bed", in: speakers)?.name, "Bedroom")
        XCTAssertEqual(Speaker.bestMatch(for: "display", in: speakers)?.name, "Kitchen Display")
    }

    func testNoMatchIsNil() {
        XCTAssertNil(Speaker.bestMatch(for: "garage", in: speakers))
    }
}

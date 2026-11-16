import ArgumentParser
import XCTest
@testable import airtap

final class CommandLineTests: XCTestCase {
    private func parse(_ arguments: [String]) throws -> ParsableCommand {
        try Airtap.parseAsRoot(arguments)
    }

    private func fails(_ arguments: [String]) -> Bool {
        (try? parse(arguments)) == nil
    }

    func testSendTakesAnAppAndASpeaker() throws {
        let command = try XCTUnwrap(try parse(["send", "pocket-casts", "Kitchen"]) as? Send)
        XCTAssertEqual(command.app, "pocket-casts")
        XCTAssertEqual(command.speaker, "Kitchen")
        XCTAssertEqual(command.volume, 30)
        XCTAssertFalse(command.debug)
    }

    func testSendReadsItsOptions() throws {
        let command = try XCTUnwrap(try parse(["send", "music", "Living Room", "--volume", "55.5", "--debug"]) as? Send)
        XCTAssertEqual(command.volume, 55.5)
        XCTAssertTrue(command.debug)
    }

    func testAVolumeThatIsNotANumberIsAnErrorNotADefault() {
        XCTAssertTrue(fails(["send", "music", "Kitchen", "--volume", "loud"]))
        XCTAssertTrue(fails(["send", "music", "Kitchen", "--volume"]), "an option with no value")
    }

    func testAVolumeOutsideZeroToOneHundredIsRejected() {
        for value in ["300", "100.5", "-1", "nan", "inf"] {
            XCTAssertTrue(fails(["send", "music", "Kitchen", "--volume", value]), "--volume \(value)")
        }
        XCTAssertFalse(fails(["send", "music", "Kitchen", "--volume", "0"]))
        XCTAssertFalse(fails(["send", "music", "Kitchen", "--volume", "100"]))
    }

    func testBothArgumentsAreRequired() {
        XCTAssertTrue(fails(["send", "music"]))
        XCTAssertTrue(fails(["send"]))
    }

    func testToneParsesAnAddressAndOptions() throws {
        let command = try XCTUnwrap(try parse(["tone", "192.168.68.27", "7000", "--seconds", "3", "--amplitude", "0"]) as? Tone)
        XCTAssertEqual(command.host, "192.168.68.27")
        XCTAssertEqual(command.port, 7000)
        XCTAssertEqual(command.seconds, 3)
        XCTAssertEqual(command.amplitude, 0)
        XCTAssertEqual(command.volume, 20)
    }

    func testToneRejectsOutOfRangeValues() {
        XCTAssertTrue(fails(["tone", "10.0.0.1", "70000"]), "a port above 65535")
        XCTAssertTrue(fails(["tone", "10.0.0.1", "7000", "--amplitude", "2"]))
        XCTAssertTrue(fails(["tone", "10.0.0.1", "7000", "--volume", "101"]))
    }

    func testTheOtherCommandsTakeNoArguments() throws {
        XCTAssertTrue(try parse(["speakers"]) is Speakers)
        XCTAssertTrue(try parse(["apps"]) is Apps)
        XCTAssertTrue(fails(["apps", "extra"]))
    }

    func testAnUnknownCommandIsAnError() {
        XCTAssertTrue(fails(["stream", "music", "Kitchen"]))
    }

    func testHelpListsEveryCommand() {
        let help = Airtap.helpMessage()
        for name in ["send", "tone", "speakers", "apps"] { XCTAssertTrue(help.contains(name), "help is missing \(name)") }
    }

    func testTheToneIsASineAtTheRequestedAmplitude() {
        let packet = ToneSource(amplitude: 0.5).readPacket(frames: 352)
        XCTAssertEqual(packet.count, 352 * 4)
        let samples = stride(from: 0, to: packet.count, by: 4).map { Int16(bitPattern: UInt16(packet[$0]) << 8 | UInt16(packet[$0 + 1])) }
        XCTAssertEqual(Double(samples.map { abs(Int($0)) }.max() ?? 0), 0.5 * 32767, accuracy: 0.02 * 32767)
        XCTAssertEqual(ToneSource(amplitude: 0).readPacket(frames: 352), Data(repeating: 0, count: 352 * 4))
    }
}

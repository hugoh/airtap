import XCTest
@testable import AirtapCore

final class LogTests: XCTestCase {
    override func tearDown() {
        Log.sink = nil
        Log.isDebugEnabled = false
    }

    func testDebugLinesCarryCategoryAndAreSkippedWhenDisabled() {
        var lines: [String] = []
        Log.sink = { lines.append($0) }
        var evaluated = false

        Log.isDebugEnabled = false
        Log.debug("rtsp") { evaluated = true; return "hidden" }
        Log.flush()
        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(evaluated, "message must not be built when debug is off")

        Log.isDebugEnabled = true
        Log.debug("rtsp") { "POST /feedback" }
        Log.flush()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[rtsp]"))
        XCTAssertTrue(lines[0].hasSuffix("POST /feedback"))
    }

    func testInfoAlwaysLogs() {
        var lines: [String] = []
        Log.sink = { lines.append($0) }
        Log.isDebugEnabled = false
        Log.info("session", "connected")
        Log.flush()
        XCTAssertEqual(lines.count, 1)
    }

    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("airtap-test-\(UUID().uuidString).log")
    }

    func testFileSinkAppendsToAnExistingLog() throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("earlier run\n".utf8).write(to: url)

        let sink = Log.fileSink(url: url, maxBytes: 1000)
        sink("new line")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "earlier run\nnew line\n")
    }

    func testFileSinkRotatesAnOversizedLogAndKeepsIt() throws {
        let url = temporaryLog()
        let rotated = url.appendingPathExtension("1")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rotated)
        }
        try Data(repeating: 0x41, count: 2000).write(to: url)

        let sink = Log.fileSink(url: url, maxBytes: 1000)
        sink("fresh")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fresh\n")
        XCTAssertEqual(try Data(contentsOf: rotated).count, 2000)
    }
}

import XCTest
@testable import AirtapCore

final class HTTPMessageTests: XCTestCase {
    private let pairHeaders = [("User-Agent", "AirPlay/320.20"), ("Connection", "keep-alive"), ("X-Apple-HKP", "4"), ("Content-Type", "application/octet-stream")]
    private let rtspHeaders = [("CSeq", "4"), ("DACP-ID", "ABCDEF0123456789"), ("Active-Remote", "12345"), ("Client-Instance", "ABCDEF0123456789")]

    func testPairRequestsMatchPyatv() {
        XCTAssertEqual(HTTPMessage.format(method: "POST", uri: "/pair-pin-start", headers: pairHeaders).hex, Vectors.requestPairPinStart)
        XCTAssertEqual(HTTPMessage.format(method: "POST", uri: "/pair-setup", headers: pairHeaders, body: Data([0, 1, 2])).hex, Vectors.requestPairSetup)
    }

    func testRtspRequestsMatchPyatv() {
        let setup = HTTPMessage.format(
            method: "SETUP", uri: "rtsp://192.168.1.2/99", protocolName: "RTSP/1.0", userAgent: "AirPlay/550.10",
            contentType: "application/x-apple-binary-plist", headers: rtspHeaders, body: Data("bplist00".utf8)
        )
        XCTAssertEqual(setup.hex, Vectors.requestRtspSetup)
        let flush = HTTPMessage.format(
            method: "FLUSH", uri: "rtsp://192.168.1.2/99", protocolName: "RTSP/1.0", userAgent: "AirPlay/550.10",
            headers: rtspHeaders + [("Range", "npt=0-"), ("Session", "0"), ("RTP-Info", "seq=5;rtptime=66150")]
        )
        XCTAssertEqual(flush.hex, Vectors.requestRtspFlush)
    }

    func testParsesResponseWithBodyAndLeavesTheRest() throws {
        let raw = Data("RTSP/1.0 200 OK\r\nCSeq: 7\r\nContent-Length: 4\r\n\r\nbodyNEXT".utf8)
        let (response, consumed) = try XCTUnwrap(try HTTPMessage.parseResponse(raw))
        XCTAssertEqual(response.code, 200)
        XCTAssertEqual(response.headers["cseq"], "7")
        XCTAssertEqual(response.body, Data("body".utf8))
        XCTAssertEqual(raw.dropFirst(consumed), Data("NEXT".utf8))
    }

    func testIncompleteResponseNeedsMoreData() throws {
        XCTAssertNil(try HTTPMessage.parseResponse(Data("RTSP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nshort".utf8)))
        XCTAssertNil(try HTTPMessage.parseResponse(Data("RTSP/1.0 200".utf8)))
    }

    func testMalformedContentLengthIsRejectedInsteadOfCrashing() {
        for value in ["-5", "abc", "99999999999"] {
            let raw = Data("RTSP/1.0 200 OK\r\nContent-Length: \(value)\r\n\r\nbody".utf8)
            XCTAssertThrowsError(try HTTPMessage.parseResponse(raw), "Content-Length: \(value)")
        }
    }

    func testMalformedStatusLineIsRejected() {
        XCTAssertThrowsError(try HTTPMessage.parseResponse(Data("garbage\r\n\r\n".utf8)))
    }
}

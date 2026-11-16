import XCTest
@testable import AirtapCore

final class AirPlayLinkTests: XCTestCase {
    /// A listening socket that accepts connections (via the backlog) but never reads or replies.
    private func silentServer() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard Darwin.bind(descriptor, pointer, size) == 0, Darwin.listen(descriptor, 4) == 0 else { return -1 }
                return getsockname(descriptor, pointer, &size)
            }
        }
        try XCTSkipIf(bound != 0, "could not open a local listening socket")
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    func testRequestGivesUpAfterItsOwnTimeout() throws {
        let server = try silentServer()
        defer { close(server.descriptor) }
        let link = AirPlayLink(connection: try TCPConnection(host: "127.0.0.1", port: server.port))

        let started = Date()
        XCTAssertThrowsError(try link.request(method: "TEARDOWN", uri: "rtsp://127.0.0.1/1", protocolName: "RTSP/1.0", timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a short timeout must not wait for the default 10 s")
    }

    func testMalformedResponseFailsTheRequest() throws {
        let server = try silentServer()
        defer { close(server.descriptor) }
        let link = AirPlayLink(connection: try TCPConnection(host: "127.0.0.1", port: server.port))
        let peer = accept(server.descriptor, nil, nil)
        defer { close(peer) }
        let reply = Array("RTSP/1.0 200 OK\r\nContent-Length: -1\r\n\r\n".utf8)
        _ = reply.withUnsafeBytes { send(peer, $0.baseAddress, reply.count, 0) }

        XCTAssertThrowsError(try link.request(method: "GET", uri: "/info", protocolName: "RTSP/1.0", timeout: 2)) { error in
            XCTAssertTrue("\(error)".contains("Content-Length"), "\(error)")
        }
    }

    func testClosingFromAnotherThreadUnblocksAPendingReceive() throws {
        let server = try silentServer()
        defer { close(server.descriptor) }
        let connection = try TCPConnection(host: "127.0.0.1", port: server.port)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { connection.close() }

        let started = Date()
        XCTAssertThrowsError(try connection.receive(timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertThrowsError(try connection.receive(timeout: 1), "a closed connection stays closed")
    }
}

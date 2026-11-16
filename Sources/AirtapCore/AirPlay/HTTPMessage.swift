import Foundation

struct HTTPResponse {
    let code: Int
    let headers: [String: String]
    let body: Data
}

/// HTTP/1.1 and RTSP/1.0 share this wire format; AirPlay speaks both on one connection.
enum HTTPMessage {
    static func format(
        method: String,
        uri: String,
        protocolName: String = "HTTP/1.1",
        userAgent: String = "AirPlay/550.10",
        contentType: String? = nil,
        headers: [(String, String)] = [],
        body: Data? = nil
    ) -> Data {
        var head = "\(method) \(uri) \(protocolName)"
        if !headers.contains(where: { $0.0.lowercased() == "user-agent" }) { head += "\r\nUser-Agent: \(userAgent)" }
        if let contentType { head += "\r\nContent-Type: \(contentType)" }
        if let body, !body.isEmpty { head += "\r\nContent-Length: \(body.count)" }
        for (key, value) in headers { head += "\r\n\(key): \(value)" }
        head += "\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    private static let maxHeaderLength = 64 * 1024
    private static let maxBodyLength = 1024 * 1024

    /// Returns nil until a complete message is buffered; `consumed` is how many bytes it used.
    /// Throws on input no speaker should send, so a broken or hostile peer cannot crash or stall the app.
    static func parseResponse(_ data: Data) throws -> (response: HTTPResponse, consumed: Int)? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= maxHeaderLength else { throw AirPlayError(description: "response headers too large") }
            return nil
        }
        guard let head = String(bytes: data[data.startIndex ..< separator.lowerBound], encoding: .utf8) else {
            throw AirPlayError(description: "response headers are not valid UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else {
            throw AirPlayError(description: "malformed status line: \(lines[0].prefix(80))")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.range(of: ": ") else { continue }
            headers[line[..<colon.lowerBound].lowercased()] = String(line[colon.upperBound...])
        }
        let declared = headers["content-length"] ?? "0"
        guard let length = Int(declared), (0...maxBodyLength).contains(length) else {
            throw AirPlayError(description: "invalid Content-Length: \(declared.prefix(32))")
        }
        let bodyStart = separator.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        let consumed = bodyStart + length - data.startIndex
        return (HTTPResponse(code: code, headers: headers, body: Data(data[bodyStart ..< bodyStart + length])), consumed)
    }
}

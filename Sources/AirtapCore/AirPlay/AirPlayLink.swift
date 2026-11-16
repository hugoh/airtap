import Foundation

/// An HTTP/RTSP request channel that becomes HAP-encrypted after pairing.
final class AirPlayLink {
    private let connection: TCPConnection
    private var session: HAPSession?
    private var inbox = Data()
    private let lock = NSLock()
    var sharedSecret = Data()

    var localAddress: String { connection.localAddress }

    init(connection: TCPConnection) { self.connection = connection }

    func enableEncryption(outKey: Data, inKey: Data) {
        session = HAPSession(outKey: outKey, inKey: inKey)
    }

    func request(
        method: String, uri: String, protocolName: String = "HTTP/1.1", contentType: String? = nil,
        headers: [(String, String)] = [], body: Data? = nil, timeout: TimeInterval = 10,
        accepting isReply: (HTTPResponse) -> Bool = { _ in true }
    ) throws -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        let started = ProcessInfo.processInfo.systemUptime
        let elapsed = { Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
        let message = HTTPMessage.format(method: method, uri: uri, protocolName: protocolName, contentType: contentType, headers: headers, body: body)
        Log.debug("rtsp") { "> \(method) \(uri) (\(body?.count ?? 0) bytes)" }
        do {
            try connection.send(session.map { try $0.encrypt(message) } ?? message)
            while true {
                if let (response, consumed) = try HTTPMessage.parseResponse(inbox) {
                    inbox = Data(inbox.dropFirst(consumed))
                    guard isReply(response) else {
                        // The answer to a request that already timed out; taking it would pair every later reply with the wrong request.
                        Log.debug("rtsp") { "ignoring a late reply (CSeq \(response.headers["cseq"] ?? "?")) while waiting on \(method) \(uri)" }
                        continue
                    }
                    Log.debug("rtsp") { "< \(response.code) \(method) \(uri) (\(response.body.count) bytes, \(elapsed()) ms)" }
                    return response
                }
                let chunk = try connection.receive(timeout: timeout)
                inbox += try session?.decrypt(chunk) ?? chunk
            }
        } catch {
            Log.info("rtsp", "\(method) \(uri) failed after \(elapsed()) ms: \(error)")
            throw error
        }
    }

    func close() { connection.close() }
}

/// RTSP requests for one AirPlay session: numbers them and adds the headers every request carries.
final class RTSPSession {
    let link: AirPlayLink
    let sessionID = UInt32.random(in: 0...UInt32.max)
    private let dacpID = String(UInt64.random(in: 0...UInt64.max), radix: 16, uppercase: true)
    private let activeRemote = UInt32.random(in: 0...UInt32.max)
    private let lock = NSLock()
    private var cseq = 0

    init(link: AirPlayLink) { self.link = link }

    @discardableResult
    func exchange(
        _ method: String, uri: String? = nil, headers: [(String, String)] = [], body: [String: Any]? = nil,
        contentType: String? = nil, text: String? = nil, allowError: Bool = false, timeout: TimeInterval = 10
    ) throws -> HTTPResponse {
        lock.lock()
        let number = cseq
        cseq += 1
        lock.unlock()

        var payload: Data?
        var type = contentType
        if let body {
            payload = try PropertyListSerialization.data(fromPropertyList: body, format: .binary, options: 0)
            type = "application/x-apple-binary-plist"
        } else if let text {
            payload = Data(text.utf8)
        }
        let response = try link.request(
            method: method,
            uri: uri ?? "rtsp://\(link.localAddress)/\(sessionID)",
            protocolName: "RTSP/1.0",
            contentType: type,
            headers: [("CSeq", String(number)), ("DACP-ID", dacpID), ("Active-Remote", String(activeRemote)), ("Client-Instance", dacpID)] + headers,
            body: payload,
            timeout: timeout,
            accepting: { $0.headers["cseq"].map { $0 == String(number) } ?? true }
        )
        guard allowError || (200..<300).contains(response.code) else {
            throw AirPlayError(description: "\(method) failed with status \(response.code)")
        }
        return response
    }

    static func plist(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AirPlayError(description: "unexpected response payload")
        }
        return dictionary
    }
}

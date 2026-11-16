import Foundation

struct NetworkError: Error, CustomStringConvertible {
    let description: String

    static func posix(_ what: String) -> NetworkError {
        NetworkError(description: "\(what): \(String(cString: strerror(errno)))")
    }
}

private func waitReadable(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return poll(&pollDescriptor, 1, Int32(timeout * 1000)) > 0
}

private func ipv4Address(host: String, port: UInt16) throws -> sockaddr_in {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: 0, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
        throw NetworkError(description: "cannot resolve \(host)")
    }
    defer { freeaddrinfo(result) }
    return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
}

/// `close()` only shuts the socket down; the descriptor itself is released in `deinit`, once no thread can still be
/// blocked on it. Closing it earlier would let the kernel hand the same number to a new socket under a reader.
final class TCPConnection {
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    let localAddress: String

    init(host: String, port: UInt16, timeout: TimeInterval = 5) throws {
        descriptor = try Self.open(host: host, port: port, timeout: timeout)
        localAddress = Self.localName(of: descriptor)
    }

    deinit { Darwin.close(descriptor) }

    private static func open(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var address = try ipv4Address(host: host, port: port)
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw NetworkError.posix("socket") }
        var enabled: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(handle, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(handle, F_GETFL)
        _ = fcntl(handle, F_SETFL, flags | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        do {
            if connected != 0 {
                guard errno == EINPROGRESS else { throw NetworkError.posix("connect to \(host):\(port)") }
                var pollDescriptor = pollfd(fd: handle, events: Int16(POLLOUT), revents: 0)
                guard poll(&pollDescriptor, 1, Int32(timeout * 1000)) > 0 else { throw NetworkError(description: "connect to \(host):\(port) timed out") }
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(handle, SOL_SOCKET, SO_ERROR, &failure, &size)
                guard failure == 0 else { throw NetworkError(description: "connect to \(host):\(port): \(String(cString: strerror(failure)))") }
            }
        } catch {
            Darwin.close(handle)
            throw error
        }
        _ = fcntl(handle, F_SETFL, flags)
        return handle
    }

    private static func localName(of descriptor: Int32) -> String {
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(descriptor, $0, &size) }
        }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        return String(cString: text)
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func send(_ data: Data) throws {
        guard !isClosed else { throw NetworkError(description: "connection closed") }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < data.count {
                let written = Darwin.send(descriptor, buffer.baseAddress! + offset, data.count - offset, 0)
                guard written > 0 else { throw NetworkError.posix("send") }
                offset += written
            }
        }
    }

    /// Throws on timeout and when either side closed the connection.
    func receive(timeout: TimeInterval) throws -> Data {
        guard !isClosed else { throw NetworkError(description: "connection closed") }
        guard waitReadable(descriptor, timeout: timeout) else { throw NetworkError(description: "timed out waiting for data") }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw NetworkError(description: isClosed ? "connection closed" : count == 0 ? "connection closed by peer" : String(cString: strerror(errno)))
        }
        return Data(buffer[0..<count])
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(descriptor, SHUT_RDWR)
    }
}

final class UDPSocket {
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    let port: UInt16

    init() throws {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { throw NetworkError.posix("socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { Darwin.close(handle); throw NetworkError.posix("bind") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(handle, $0, &size) }
        }
        descriptor = handle
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { Darwin.close(descriptor) }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func connect(host: String, port: UInt16) throws {
        var address = try ipv4Address(host: host, port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw NetworkError.posix("udp connect") }
    }

    func send(_ data: Data) throws {
        let written = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, data.count, 0) }
        guard written == data.count else { throw NetworkError.posix("udp send") }
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        var address = try ipv4Address(host: host, port: port)
        try send(data, to: &address)
    }

    func send(_ data: Data, to address: inout sockaddr_in) throws {
        let written = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard written == data.count else { throw NetworkError.posix("udp sendto") }
    }

    /// Returns nil on timeout or once the socket is closed.
    func receive(timeout: TimeInterval) -> (data: Data, from: sockaddr_in)? {
        guard !isClosed, waitReadable(descriptor, timeout: timeout), !isClosed else { return nil }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &size) }
        }
        return count > 0 ? (Data(buffer[0..<count]), from) : nil
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

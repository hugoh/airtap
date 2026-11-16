import dnssd
import Foundation

public struct Speaker: Equatable, Hashable {
    public let name: String
    public let host: String
    public let port: UInt16

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }

    /// The speaker a user most likely means by `query`: an exact name if there is one, otherwise the first name containing it.
    public static func bestMatch(for query: String, in speakers: [Speaker]) -> Speaker? {
        speakers.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? speakers.first { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Parses "192.168.1.20:7000", for speakers Bonjour cannot resolve. Names never look like this.
    public init?(address: String) {
        let parts = address.split(separator: ":")
        var parsed = in_addr()
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0, inet_pton(AF_INET, String(parts[0]), &parsed) == 1 else { return nil }
        self.init(name: address, host: String(parts[0]), port: port)
    }
}

public enum SpeakerDiscovery {
    public struct Result {
        public let speakers: [Speaker]
        /// Announced over Bonjour but not answering, usually because the speaker is off or asleep.
        public let unreachable: [String]
    }

    public static func discover(timeout: TimeInterval = 4, matching query: String? = nil) -> [Speaker] {
        discoverDetailed(timeout: timeout, matching: query).speakers
    }

    /// Browses for AirPlay receivers, blocking the calling thread. Returns early once a speaker named exactly `query`
    /// resolves, a moment after the first partial match, or when `isCancelled` turns true.
    public static func discoverDetailed(timeout: TimeInterval = 4, matching query: String? = nil, isCancelled: () -> Bool = { false }) -> Result {
        let finder = Finder(query: query)
        finder.run(timeout: timeout, isCancelled: isCancelled)
        let found = Set(finder.speakers.map(\.name))
        return Result(
            speakers: finder.speakers.sorted { $0.name < $1.name },
            unreachable: finder.announced.subtracting(found).sorted()
        )
    }
}

/// One service instance on its way from "announced" to "has an IPv4 address and port".
private final class Lookup {
    unowned let finder: Finder
    let name: String
    let isRaop: Bool
    var port: UInt16 = 0

    init(finder: Finder, name: String, isRaop: Bool) {
        self.finder = finder
        self.name = name
        self.isRaop = isRaop
    }
}

/// Browses `_raop._tcp` and, as a fallback for speakers whose RAOP record will not resolve, `_airplay._tcp`
/// (same port on the AirPlay 2 receivers tested). Everything runs over one shared DNS-SD connection.
private final class Finder {
    private static let types = ["_raop._tcp", "_airplay._tcp"]
    private let query: String?
    private var connection: DNSServiceRef?
    private var lookups: [Lookup] = []
    private var byName: [String: (speaker: Speaker, isRaop: Bool)] = [:]
    private var announcedNames: Set<String> = []
    private var ownNames: Set<String> = []
    private let ownAddresses = Finder.interfaceAddresses()

    init(query: String?) { self.query = query }

    var announced: Set<String> { announcedNames.subtracting(ownNames) }

    private static func interfaceAddresses() -> Set<String> {
        var addresses: Set<String> = ["127.0.0.1"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return addresses }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                var source = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &source, &text, socklen_t(INET_ADDRSTRLEN))
                addresses.insert(String(cString: text))
            }
            entry = current.pointee.ifa_next
        }
        return addresses
    }

    var speakers: [Speaker] { byName.values.map(\.speaker) }

    private var firstPartialMatch: Date?

    /// An exact name ends the search at once. A partial match waits a second for a better-named speaker to show up.
    private func isSatisfied() -> Bool {
        guard let query else { return false }
        if speakers.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return true }
        guard speakers.contains(where: { $0.name.localizedCaseInsensitiveContains(query) }) else { return false }
        let since = firstPartialMatch ?? Date()
        firstPartialMatch = since
        return Date().timeIntervalSince(since) > 1
    }

    func run(timeout: TimeInterval, isCancelled: () -> Bool) {
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else {
            Log.info("discovery", "could not reach the system DNS-SD service")
            return
        }
        defer { DNSServiceRefDeallocate(connection) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in Self.types {
            var operation: DNSServiceRef? = connection
            DNSServiceBrowse(&operation, DNSServiceFlags(kDNSServiceFlagsShareConnection), 0, type, "local.", browseReply, context)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var descriptor = pollfd(fd: DNSServiceRefSockFD(connection), events: Int16(POLLIN), revents: 0)
        while !isSatisfied(), !isCancelled() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard poll(&descriptor, 1, Int32(min(remaining, 0.25) * 1000)) > 0 else { continue }
            guard DNSServiceProcessResult(connection) == kDNSServiceErr_NoError else { break }
        }
        for name in announced.subtracting(byName.keys).sorted() {
            Log.debug("discovery") { "\(name) is announced but did not resolve to an address" }
        }
    }

    fileprivate func found(name: String, type: String, domain: String, interface: UInt32) {
        // RAOP instance names look like "7828CAE437CA@Bedroom"; AirPlay ones are just the name.
        let displayName = name.split(separator: "@", maxSplits: 1).last.map(String.init) ?? name
        announcedNames.insert(displayName)
        let lookup = Lookup(finder: self, name: displayName, isRaop: type.hasPrefix("_raop"))
        lookups.append(lookup)
        var operation = connection
        DNSServiceResolve(&operation, DNSServiceFlags(kDNSServiceFlagsShareConnection), interface, name, type, domain, resolveReply, Unmanaged.passUnretained(lookup).toOpaque())
    }

    fileprivate func resolved(_ lookup: Lookup, host: String, interface: UInt32) {
        var operation = connection
        DNSServiceGetAddrInfo(
            &operation, DNSServiceFlags(kDNSServiceFlagsShareConnection), interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4),
            host, addressReply, Unmanaged.passUnretained(lookup).toOpaque()
        )
    }

    fileprivate func addressed(_ lookup: Lookup, host: String) {
        guard !ownAddresses.contains(host) else {
            ownNames.insert(lookup.name)  // this Mac's own AirPlay receiver
            byName[lookup.name] = nil
            return
        }
        guard !ownNames.contains(lookup.name) else { return }
        if let existing = byName[lookup.name], existing.isRaop || !lookup.isRaop { return }
        byName[lookup.name] = (Speaker(name: lookup.name, host: host, port: lookup.port), lookup.isRaop)
        Log.debug("discovery") { "found \(lookup.name) at \(host):\(lookup.port) via \(lookup.isRaop ? "raop" : "airplay")" }
    }
}

private let browseReply: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
    guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let name, let type, let domain, let context else { return }
    Unmanaged<Finder>.fromOpaque(context).takeUnretainedValue()
        .found(name: String(cString: name), type: String(cString: type), domain: String(cString: domain), interface: interface)
}

private let resolveReply: DNSServiceResolveReply = { _, _, interface, error, _, host, port, _, _, context in
    guard error == kDNSServiceErr_NoError, let host, let context else { return }
    let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
    lookup.port = UInt16(bigEndian: port)
    lookup.finder.resolved(lookup, host: String(cString: host), interface: interface)
}

private let addressReply: DNSServiceGetAddrInfoReply = { _, _, _, error, _, address, _, context in
    guard error == kDNSServiceErr_NoError, let address, let context, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
    var source = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &source, &text, socklen_t(INET_ADDRSTRLEN))
    let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
    lookup.finder.addressed(lookup, host: String(cString: text))
}

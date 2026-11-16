import Foundation

/// Timestamped logging to stderr. `info` always prints; `debug` only with AIRTAP_DEBUG set or `isDebugEnabled`.
public enum Log {
    public nonisolated(unsafe) static var isDebugEnabled = ProcessInfo.processInfo.environment["AIRTAP_DEBUG"] != nil
    public nonisolated(unsafe) static var sink: ((String) -> Void)?
    private static let queue = DispatchQueue(label: "airtap.log")
    private static let epoch = ProcessInfo.processInfo.systemUptime

    public static func info(_ category: String, _ message: @autoclosure () -> String) {
        emit(category, message())
    }

    public static func debug(_ category: String, _ message: () -> String) {
        guard isDebugEnabled else { return }
        emit(category, message())
    }

    /// A sink that appends to `url`, first moving a log over `maxBytes` aside to `<url>.1` so earlier runs stay readable.
    public static func fileSink(url: URL, maxBytes: Int) -> (String) -> Void {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return { line in handle?.write(Data((line + "\n").utf8)) }
    }

    /// Blocks until queued lines are written; used before exiting and in tests.
    public static func flush() { queue.sync {} }

    private static func emit(_ category: String, _ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - epoch
        let line = String(format: "%9.3f [%@] %@", elapsed, category, message)
        queue.async {
            if let sink { sink(line) } else { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        }
    }
}

import Foundation

/// One bounded log file. Lines past the byte limit are dropped with a single marker.
public final class SessionLog: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle?
    private let maxBytes: Int
    private var written = 0
    private var truncated = false
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.maxBytes = maxBytes
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: url)
        self.formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func append(_ text: String, source: String = "launcher") {
        lock.lock(); defer { lock.unlock() }
        guard let handle, !truncated else { return }
        let line = "\(formatter.string(from: Date())) [\(source)] \(text)\n"
        let data = Data(line.utf8)
        if written + data.count > maxBytes {
            truncated = true
            handle.write(Data("--- log truncated at \(maxBytes) bytes ---\n".utf8))
            return
        }
        handle.write(data)
        written += data.count
    }

    public func append(_ line: OutputLine) {
        append(line.text, source: line.stream.rawValue)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
    }
}

/// Rotating log directory: at most `maxFiles` logs of at most `maxFileBytes` each.
public struct LogStore: Sendable {
    public let directory: URL
    public let maxFileBytes: Int
    public let maxFiles: Int

    public init(directory: URL, maxFileBytes: Int = 5 * 1024 * 1024, maxFiles: Int = 10) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = max(1, maxFiles)
    }

    public func makeLog(named prefix: String) throws -> SessionLog {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rotate(keeping: maxFiles - 1)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(PathSafety.safeComponent(prefix))-\(stamp)-\(UUID().uuidString.prefix(8)).log"
        return SessionLog(url: directory.appendingPathComponent(name), maxBytes: maxFileBytes)
    }

    /// Newest first.
    public func logFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "log" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return da == db ? a.lastPathComponent > b.lastPathComponent : da > db
        }
    }

    public func rotate(keeping count: Int) throws {
        for old in logFiles().dropFirst(max(0, count)) {
            try FileManager.default.removeItem(at: old)
        }
    }

    /// Last `maxLines` lines, reading at most the final 256 KB of the file.
    public func tail(of url: URL, maxLines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(maxLines).map(String.init)
    }
}

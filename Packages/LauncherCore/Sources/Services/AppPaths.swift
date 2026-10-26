import Foundation

/// Locations the launcher owns. Prefixes and configuration live in Application Support,
/// logs in ~/Library/Logs, disposable data in Caches.
public struct AppPaths: Sendable, Equatable {
    public static let bundleIdentifier = "io.github.frogleim.stockade"

    public let applicationSupport: URL
    public let logs: URL
    public let caches: URL

    public init(applicationSupport: URL, logs: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.logs = logs
        self.caches = caches
    }

    /// Everything under one root, for tests and the development harness.
    public init(root: URL) {
        self.init(
            applicationSupport: root.appendingPathComponent("Application Support", isDirectory: true),
            logs: root.appendingPathComponent("Logs", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return AppPaths(
            applicationSupport: library.appendingPathComponent("Application Support/\(bundleIdentifier)", isDirectory: true),
            logs: library.appendingPathComponent("Logs/\(bundleIdentifier)", isDirectory: true),
            caches: library.appendingPathComponent("Caches/\(bundleIdentifier)", isDirectory: true)
        )
    }

    public var configurationFile: URL { applicationSupport.appendingPathComponent("configuration.json") }
    public var prefixesRoot: URL { applicationSupport.appendingPathComponent("Prefixes", isDirectory: true) }
    public var locksDirectory: URL { applicationSupport.appendingPathComponent("Locks", isDirectory: true) }
    public var backupsRoot: URL { applicationSupport.appendingPathComponent("Backups", isDirectory: true) }

    public func createDirectories(fileManager: FileManager = .default) throws {
        for url in [applicationSupport, logs, caches, prefixesRoot, locksDirectory, backupsRoot] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

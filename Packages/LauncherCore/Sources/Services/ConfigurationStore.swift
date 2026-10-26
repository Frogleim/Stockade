import Foundation

public enum ConfigurationLoadOutcome: Sendable, Equatable {
    case fresh(LauncherConfiguration)
    case loaded(LauncherConfiguration)
    /// The main file was unreadable; the last good copy was used and the damaged file kept.
    case recovered(LauncherConfiguration, damagedFile: URL)

    public var configuration: LauncherConfiguration {
        switch self {
        case .fresh(let c), .loaded(let c), .recovered(let c, _): return c
        }
    }
}

/// Atomic JSON persistence with schema checks and last-good recovery.
public struct ConfigurationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public var lastGoodURL: URL { fileURL.appendingPathExtension("lastgood") }

    private struct SchemaHeader: Decodable {
        var schemaVersion: Int
    }

    public func load() throws -> ConfigurationLoadOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            if let backup = try? decode(Data(contentsOf: lastGoodURL)) {
                return .recovered(backup, damagedFile: fileURL)
            }
            return .fresh(LauncherConfiguration())
        }
        do {
            let config = try decode(Data(contentsOf: fileURL))
            try? write(config, to: lastGoodURL)
            return .loaded(config)
        } catch let error as LauncherError where isFutureSchema(error) {
            throw error
        } catch {
            let damaged = fileURL.deletingLastPathComponent()
                .appendingPathComponent("configuration.damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: fileURL, to: damaged)
            if let backup = try? decode(Data(contentsOf: lastGoodURL)) {
                return .recovered(backup, damagedFile: damaged)
            }
            throw LauncherError.configurationCorrupt(detail: error.localizedDescription)
        }
    }

    /// Writes atomically. Refuses to overwrite a file written by a newer launcher.
    public func save(_ configuration: LauncherConfiguration) throws {
        if let existing = try? Data(contentsOf: fileURL),
           let header = try? JSONDecoder().decode(SchemaHeader.self, from: existing),
           header.schemaVersion > LauncherConfiguration.currentSchemaVersion {
            throw LauncherError.configurationFromFuture(
                found: header.schemaVersion,
                supported: LauncherConfiguration.currentSchemaVersion
            )
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(configuration, to: fileURL)
        try? write(configuration, to: lastGoodURL)
    }

    private func write(_ configuration: LauncherConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    private func decode(_ data: Data) throws -> LauncherConfiguration {
        let header = try JSONDecoder().decode(SchemaHeader.self, from: data)
        if header.schemaVersion > LauncherConfiguration.currentSchemaVersion {
            throw LauncherError.configurationFromFuture(
                found: header.schemaVersion,
                supported: LauncherConfiguration.currentSchemaVersion
            )
        }
        let migrated = try migrate(data, from: header.schemaVersion)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LauncherConfiguration.self, from: migrated)
    }

    /// Schema migrations go here, one step per version.
    private func migrate(_ data: Data, from version: Int) throws -> Data {
        switch version {
        case LauncherConfiguration.currentSchemaVersion:
            return data
        default:
            throw LauncherError.configurationCorrupt(detail: "unknown schema version \(version)")
        }
    }

    private func isFutureSchema(_ error: LauncherError) -> Bool {
        if case .configurationFromFuture = error { return true }
        return false
    }
}

import Foundation

public struct BackupManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var relativePath: String
        public var size: Int64
        public var sha256: String
    }

    public static let currentSchemaVersion = 1
    public static let fileName = "manifest.json"

    public var schemaVersion: Int
    public var createdAt: Date
    public var sourcePath: String
    public var gameVersion: String?
    public var files: [Entry]
}

public struct BackupRecord: Sendable, Equatable, Identifiable {
    public var url: URL
    public var manifest: BackupManifest
    public var id: URL { url }
}

/// Save backups with checksummed manifests, and restores that never destroy current saves.
/// Callers must make sure the game is closed first (see `LauncherEngine`).
public struct BackupService: Sendable {
    public init() {}

    private static var dataDirectoryName: String { "files" }

    public func createBackup(of saveDirectory: URL, into backupsRoot: URL, gameVersion: String?) throws -> BackupRecord {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: saveDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LauncherError.notConfigured("A verified save directory")
        }
        try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = backupsRoot.appendingPathComponent("Backup \(stamp) \(UUID().uuidString.prefix(4))", isDirectory: true)
        let staging = backupsRoot.appendingPathComponent(".incomplete-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        let data = staging.appendingPathComponent(Self.dataDirectoryName, isDirectory: true)
        try fm.copyItem(at: saveDirectory, to: data)
        let entries = try checksums(in: data)
        let source = try checksums(in: saveDirectory)
        guard entries == source else {
            throw LauncherError.backupVerificationFailed(file: "save files changed while copying; close the game and try again")
        }
        let manifest = BackupManifest(
            schemaVersion: BackupManifest.currentSchemaVersion,
            createdAt: Date(),
            sourcePath: saveDirectory.path,
            gameVersion: gameVersion,
            files: entries
        )
        try encode(manifest).write(to: staging.appendingPathComponent(BackupManifest.fileName), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
        let record = BackupRecord(url: destination, manifest: manifest)
        try verify(record)
        return record
    }

    public func listBackups(in backupsRoot: URL) -> [BackupRecord] {
        let items = (try? FileManager.default.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url in
            guard !url.lastPathComponent.hasPrefix("."),
                  let data = try? Data(contentsOf: url.appendingPathComponent(BackupManifest.fileName)),
                  let manifest = try? decode(data) else { return nil }
            return BackupRecord(url: url, manifest: manifest)
        }.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public func verify(_ record: BackupRecord) throws {
        try verify(directory: record.url.appendingPathComponent(Self.dataDirectoryName), against: record.manifest)
    }

    /// Stages and verifies the backup next to the save folder, moves current saves aside,
    /// then swaps the staged copy in. Returns where the previous saves were preserved.
    @discardableResult
    public func restore(_ record: BackupRecord, to saveDirectory: URL, confirmation: String) throws -> URL? {
        guard confirmation == saveDirectory.path else { throw LauncherError.confirmationMismatch }
        let fm = FileManager.default
        try verify(record)

        let parent = saveDirectory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(saveDirectory.lastPathComponent).restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.copyItem(at: record.url.appendingPathComponent(Self.dataDirectoryName), to: staging)
            try verify(directory: staging, against: record.manifest)
        } catch {
            throw LauncherError.restoreFailed(detail: "the staged copy could not be verified (\(error.localizedDescription))")
        }

        var preserved: URL?
        if fm.fileExists(atPath: saveDirectory.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = parent.appendingPathComponent("\(saveDirectory.lastPathComponent) before restore \(stamp)", isDirectory: true)
            do {
                try fm.moveItem(at: saveDirectory, to: aside)
            } catch {
                throw LauncherError.restoreFailed(detail: "current saves could not be moved aside (\(error.localizedDescription))")
            }
            preserved = aside
        }
        do {
            try fm.moveItem(at: staging, to: saveDirectory)
        } catch {
            if let preserved { try? fm.moveItem(at: preserved, to: saveDirectory) }
            throw LauncherError.restoreFailed(detail: "the restored files could not be put in place (\(error.localizedDescription))")
        }
        return preserved
    }

    func verify(directory: URL, against manifest: BackupManifest) throws {
        let actual = try checksums(in: directory)
        let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
        let found = Dictionary(uniqueKeysWithValues: actual.map { ($0.relativePath, $0) })
        for (path, entry) in expected where found[path] != entry {
            throw LauncherError.backupVerificationFailed(file: path)
        }
        if let extra = found.keys.first(where: { expected[$0] == nil }) {
            throw LauncherError.backupVerificationFailed(file: extra)
        }
    }

    /// Regular files only, sorted by relative path. Symlinks are rejected rather than followed.
    func checksums(in directory: URL) throws -> [BackupManifest.Entry] {
        let fm = FileManager.default
        let base = PathSafety.canonical(directory)
        guard let enumerator = fm.enumerator(atPath: base.path) else { return [] }
        var entries: [BackupManifest.Entry] = []
        for case let relative as String in enumerator {
            let url = base.appendingPathComponent(relative)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                throw LauncherError.backupVerificationFailed(file: "\(relative) is a symbolic link")
            }
            guard type == .typeRegular else { continue }
            entries.append(BackupManifest.Entry(
                relativePath: relative,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                sha256: try RuntimeDiscovery.sha256(of: url)
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private func encode(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func decode(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }
}

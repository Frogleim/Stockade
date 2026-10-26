import Foundation

/// Creates, inspects, initializes and deletes launcher-owned Wine prefixes.
public struct PrefixManager: Sendable {
    public static let initializingMarker = ".frontier-launcher-initializing"
    public static let initializedMarker = ".frontier-launcher-initialized.json"

    public let paths: AppPaths
    public let supervisor: ProcessSupervisor
    public let processSource: any PrefixProcessSource

    public init(paths: AppPaths, supervisor: ProcessSupervisor = ProcessSupervisor(), processSource: any PrefixProcessSource = WineServerProcessSource()) {
        self.paths = paths
        self.supervisor = supervisor
        self.processSource = processSource
    }

    public init(paths: AppPaths, supervisor: ProcessSupervisor = ProcessSupervisor(), observer: PrefixObserver) {
        self.init(paths: paths, supervisor: supervisor, processSource: EnvironmentProcessSource(observer: observer))
    }

    /// Creates an empty prefix folder inside the owned root. The default name contains a
    /// space on purpose, so quoting problems surface immediately.
    public func createPrefixDirectory(named name: String = "Farthest Frontier Prefix") throws -> URL {
        try paths.createDirectories()
        var url = paths.prefixesRoot.appendingPathComponent(PathSafety.safeComponent(name), isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = paths.prefixesRoot.appendingPathComponent("\(PathSafety.safeComponent(name)) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try PathSafety.validateOwnedLocation(url, ownedRoot: paths.prefixesRoot)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    public func status(of prefix: URL) -> PrefixStatus {
        let fm = FileManager.default
        if PathSafety.isOnUnmountedVolume(prefix) || !fm.fileExists(atPath: prefix.path) {
            return .missing
        }
        let initializing = fm.fileExists(atPath: prefix.appendingPathComponent(Self.initializingMarker).path)
        if marker(of: prefix) != nil, !initializing {
            return .initialized
        }
        if initializing {
            // Another process may hold the lock while initializing; otherwise it was interrupted.
            if let lock = try? PrefixLock.acquire(prefix: prefix, locksDirectory: paths.locksDirectory) {
                lock.release()
                return .interrupted
            }
            return .initializing
        }
        return .uninitialized
    }

    public func marker(of prefix: URL) -> PrefixMarker? {
        let url = prefix.appendingPathComponent(Self.initializedMarker)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PrefixMarker.self, from: data)
    }

    /// Runs `wineboot --init`, waits for the prefix to go idle, and only then writes the marker.
    public func initialize(
        prefix: URL,
        runtime: RuntimeDescriptor,
        verboseLogging: Bool = false,
        onOutput: @escaping OutputHandler = { _ in }
    ) async throws {
        try PathSafety.validateOwnedLocation(prefix, ownedRoot: paths.prefixesRoot)
        let lock = try PrefixLock.acquire(prefix: prefix, locksDirectory: paths.locksDirectory)
        defer { lock.release() }

        if let existing = marker(of: prefix), existing.runtimeID != runtime.id {
            throw LauncherError.runtimeMismatch(prefixRuntime: existing.runtimeVersion, selectedRuntime: runtime.versionOutput)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        let initializing = prefix.appendingPathComponent(Self.initializingMarker)
        try Data().write(to: initializing)

        let adapter = RuntimeAdapters.adapter(for: runtime.adapter)
        let context = LaunchContext(runtime: runtime, prefix: prefix, verboseLogging: verboseLogging)
        let boot = try await supervisor.run(try adapter.plan(.initializePrefix, context: context), onOutput: onOutput)
        guard boot.exit.succeeded else {
            throw LauncherError.processLaunchFailed(detail: "wineboot exited with status \(boot.exit.status)")
        }
        _ = try await supervisor.run(try adapter.plan(.waitForPrefixIdle, context: context), onOutput: onOutput)

        guard fm.fileExists(atPath: prefix.appendingPathComponent("drive_c").path),
              fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw LauncherError.processLaunchFailed(detail: "wineboot finished but the prefix has no drive_c or system.reg")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let marker = PrefixMarker(runtimeID: runtime.id, runtimeVersion: runtime.versionOutput)
        try encoder.encode(marker).write(to: prefix.appendingPathComponent(Self.initializedMarker), options: .atomic)
        try fm.removeItem(at: initializing)
    }

    /// Moves a prefix to another build of the same Wine version (for example the same release
    /// with a rebuilt driver). Different Wine versions are refused.
    public func adopt(prefix: URL, by runtime: RuntimeDescriptor) throws {
        guard let existing = marker(of: prefix) else { throw LauncherError.prefixNotInitialized(path: prefix.path) }
        guard existing.runtimeVersion == runtime.versionOutput else {
            throw LauncherError.runtimeMismatch(prefixRuntime: existing.runtimeVersion, selectedRuntime: runtime.versionOutput)
        }
        let lock = try PrefixLock.acquire(prefix: prefix, locksDirectory: paths.locksDirectory)
        defer { lock.release() }
        guard !isActive(prefix) else { throw LauncherError.prefixActive(path: prefix.path) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updated = PrefixMarker(runtimeID: runtime.id, runtimeVersion: runtime.versionOutput)
        try encoder.encode(updated).write(to: prefix.appendingPathComponent(Self.initializedMarker), options: .atomic)
    }

    public func isActive(_ prefix: URL) -> Bool {
        processSource.isActive(prefix: prefix)
    }

    /// Deletes a prefix only when it is owned, inactive, unlocked, and the confirmation
    /// equals its exact path.
    public func delete(prefix: URL, confirmation: String) throws {
        guard confirmation == prefix.path else { throw LauncherError.confirmationMismatch }
        try PathSafety.validateOwnedLocation(prefix, ownedRoot: paths.prefixesRoot)
        let lock = try PrefixLock.acquire(prefix: prefix, locksDirectory: paths.locksDirectory)
        defer { lock.release() }
        guard !isActive(prefix) else { throw LauncherError.prefixActive(path: prefix.path) }

        // Remove the canonical directory, never a symlink target outside the owned root.
        let canonical = PathSafety.canonical(prefix)
        try PathSafety.validateOwnedLocation(canonical, ownedRoot: paths.prefixesRoot)
        try FileManager.default.removeItem(at: canonical)
    }
}

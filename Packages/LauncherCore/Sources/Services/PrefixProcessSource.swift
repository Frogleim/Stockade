import Darwin
import Foundation

/// Answers "what is running in this prefix?" for the session monitor and maintenance checks.
public protocol PrefixProcessSource: Sendable {
    /// Cheap and free of side effects; used before maintenance and deletion.
    func isActive(prefix: URL) -> Bool
    func snapshot(prefix: URL, runtime: RuntimeDescriptor, gameHints: [String]) async -> PrefixSnapshot
}

/// Matches Unix processes by their WINEPREFIX environment variable. Kept for tests and as a
/// fallback: Wine rewrites its processes' argument area, which can hide the environment.
public struct EnvironmentProcessSource: PrefixProcessSource {
    public let observer: PrefixObserver

    public init(observer: PrefixObserver = PrefixObserver()) {
        self.observer = observer
    }

    public func isActive(prefix: URL) -> Bool {
        observer.snapshot(prefix: prefix, gameHints: []).isActive
    }

    public func snapshot(prefix: URL, runtime: RuntimeDescriptor, gameHints: [String]) async -> PrefixSnapshot {
        observer.snapshot(prefix: prefix, gameHints: gameHints)
    }
}

/// Asks Wine itself. A prefix is active while its wineserver holds the lock in
/// `/tmp/.wine-<uid>/server-<dev>-<inode>/lock`; the process list comes from `tasklist.exe`,
/// which only ever sees processes of that prefix.
public struct WineServerProcessSource: PrefixProcessSource {
    /// Wine's own background programs; they do not count as "something is running".
    public static let wineSystemImages: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "explorer.exe", "svchost.exe", "rpcss.exe",
        "tasklist.exe", "start.exe", "conhost.exe", "wineboot.exe", "winemenubuilder.exe",
    ]

    public var supervisor: ProcessSupervisor
    public var serverRoot: URL
    public var hostEnvironment: [String: String]

    public init(
        supervisor: ProcessSupervisor = ProcessSupervisor(),
        serverRoot: URL = URL(fileURLWithPath: "/tmp/.wine-\(getuid())", isDirectory: true),
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.supervisor = supervisor
        self.serverRoot = serverRoot
        self.hostEnvironment = hostEnvironment
    }

    public func serverDirectory(for prefix: URL) -> URL? {
        var info = stat()
        guard stat(PathSafety.canonical(prefix).path, &info) == 0 else { return nil }
        let name = String(format: "server-%llx-%llx", UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
        return serverRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// PID of the wineserver holding the prefix lock, or nil when no server runs.
    public func serverPID(prefix: URL) -> Int32? {
        guard let lockFile = serverDirectory(for: prefix)?.appendingPathComponent("lock") else { return nil }
        let fd = open(lockFile.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var query = flock()
        query.l_type = Int16(F_WRLCK)
        query.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &query) == 0, query.l_type != Int16(F_UNLCK) else { return nil }
        return query.l_pid
    }

    public func isActive(prefix: URL) -> Bool {
        serverPID(prefix: prefix) != nil
    }

    public func snapshot(prefix: URL, runtime: RuntimeDescriptor, gameHints: [String]) async -> PrefixSnapshot {
        let empty = PrefixSnapshot(prefixProcesses: [], steamProcesses: [], gameProcesses: [])
        // Never start a wineserver just to look: tasklist would bring an idle prefix up.
        guard isActive(prefix: prefix),
              let plan = try? RuntimeAdapters.adapter(for: runtime.adapter).plan(
                  .listProcesses,
                  context: LaunchContext(runtime: runtime, prefix: prefix, hostEnvironment: hostEnvironment)
              ),
              let result = try? await supervisor.run(plan, timeout: .seconds(15), keepLines: 500),
              result.exit.succeeded
        else { return empty }
        let processes = Self.parseTasklist(result.tail.filter { $0.stream == .stdout }.map(\.text))
        return Self.snapshot(from: processes, gameHints: gameHints)
    }

    /// Parses `tasklist /FO CSV /NH` lines: "image","pid","session","#","memory".
    public static func parseTasklist(_ lines: [String]) -> [(image: String, pid: Int32)] {
        lines.compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \r")) }
            guard fields.count >= 2, !fields[0].isEmpty, let pid = Int32(fields[1]) else { return nil }
            return (fields[0], pid)
        }
    }

    public static func snapshot(from processes: [(image: String, pid: Int32)], gameHints: [String]) -> PrefixSnapshot {
        // Windows PIDs, marked by a zero start time: they are not Unix processes.
        func observed(_ entry: (image: String, pid: Int32)) -> ObservedProcess {
            ObservedProcess(identity: ProcessIdentity(pid: entry.pid, startSeconds: 0, startMicroseconds: 0),
                            arguments: [entry.image], environment: [:])
        }
        let hints = gameHints.map { URL(fileURLWithPath: $0.replacingOccurrences(of: "\\", with: "/")).lastPathComponent.lowercased() }
        let user = processes.filter { !wineSystemImages.contains($0.image.lowercased()) }
        return PrefixSnapshot(
            prefixProcesses: user.map(observed),
            steamProcesses: user.filter { $0.image.lowercased() == "steam.exe" }.map(observed),
            gameProcesses: user.filter { hints.contains($0.image.lowercased()) }.map(observed)
        )
    }
}

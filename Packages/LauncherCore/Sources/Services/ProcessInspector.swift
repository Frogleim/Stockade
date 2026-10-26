import Darwin
import Foundation

extension ProcessIdentity {
    /// Reads the kernel start time for `pid`, or nil if no such process exists.
    public static func current(pid: Int32) -> ProcessIdentity? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return ProcessIdentity(pid: pid, startSeconds: Int(start.tv_sec), startMicroseconds: Int(start.tv_usec))
    }

    public var isAlive: Bool {
        ProcessIdentity.current(pid: pid) == self
    }
}

public struct ObservedProcess: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var arguments: [String]
    public var environment: [String: String]

    public init(identity: ProcessIdentity, arguments: [String], environment: [String: String]) {
        self.identity = identity
        self.arguments = arguments
        self.environment = environment
    }
}

public protocol ProcessInspecting: Sendable {
    /// Processes of the current user. Environment is only needed for WINEPREFIX matching.
    func userProcesses() -> [ObservedProcess]
}

/// Reads process arguments and environment through `KERN_PROCARGS2` (same-user processes only).
public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func userProcesses() -> [ObservedProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between calls.
        size += 16 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride

        var result: [ObservedProcess] = []
        for info in procs.prefix(count) {
            let pid = info.kp_proc.p_pid
            guard pid > 0, let (args, env) = Self.argumentsAndEnvironment(pid: pid) else { continue }
            let start = info.kp_proc.p_starttime
            let identity = ProcessIdentity(pid: pid, startSeconds: Int(start.tv_sec), startMicroseconds: Int(start.tv_usec))
            result.append(ObservedProcess(identity: identity, arguments: args, environment: env))
        }
        return result
    }

    static func argumentsAndEnvironment(pid: Int32) -> ([String], [String: String])? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMIB, 2, &argMax, &argMaxSize, nil, 0) == 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = Int(argMax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout: argc (Int32), exec path, NUL padding, argc argument strings, environment strings.
    static func parseProcArgs(_ bytes: [UInt8]) -> ([String], [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // exec path
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // padding

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }

        var args: [String] = []
        for _ in 0..<max(0, argc) {
            guard let arg = nextString() else { break }
            args.append(arg)
        }
        var env: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            if let equals = entry.firstIndex(of: "=") {
                env[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
        }
        return (args, env)
    }
}

/// What is running inside one prefix right now.
public struct PrefixSnapshot: Sendable, Equatable {
    public var prefixProcesses: [ObservedProcess]
    public var steamProcesses: [ObservedProcess]
    public var gameProcesses: [ObservedProcess]

    public var isActive: Bool { !prefixProcesses.isEmpty }
}

public struct PrefixObserver: Sendable {
    public let inspector: any ProcessInspecting

    public init(inspector: any ProcessInspecting = SystemProcessInspector()) {
        self.inspector = inspector
    }

    /// Matches processes by their WINEPREFIX, so programs in other prefixes are never counted.
    public func snapshot(prefix: URL, gameHints: [String]) -> PrefixSnapshot {
        let target = PathSafety.canonical(prefix).path
        let inPrefix = inspector.userProcesses().filter { process in
            guard let value = process.environment["WINEPREFIX"], !value.isEmpty else { return false }
            return PathSafety.canonical(URL(fileURLWithPath: value)).path == target
        }
        let lowerHints = gameHints.map { $0.lowercased() }.filter { !$0.isEmpty }
        func matches(_ process: ObservedProcess, _ needles: [String]) -> Bool {
            process.arguments.contains { arg in
                let lower = arg.lowercased()
                return needles.contains { lower.contains($0) }
            }
        }
        return PrefixSnapshot(
            prefixProcesses: inPrefix,
            steamProcesses: inPrefix.filter { matches($0, ["steam.exe"]) },
            gameProcesses: inPrefix.filter { matches($0, lowerHints) }
        )
    }
}

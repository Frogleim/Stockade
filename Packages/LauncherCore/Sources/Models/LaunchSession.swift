import Foundation

/// `Not configured → Ready → Launch requested → Starting → Running observed → Exited`,
/// with `failed` and `statusUnknown` reachable from the active stages.
public enum SessionPhase: String, Codable, Sendable, Equatable {
    case notConfigured
    case ready
    case launchRequested
    case starting
    case runningObserved
    case exited
    case failed
    case statusUnknown

    public var isActive: Bool {
        switch self {
        case .launchRequested, .starting, .runningObserved, .statusUnknown: return true
        default: return false
        }
    }

    public var headline: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .ready: return "Ready"
        case .launchRequested: return "Launch requested"
        case .starting: return "Steam is running — waiting for the game"
        case .runningObserved: return "Game running"
        case .exited: return "Game exited"
        case .failed: return "Launch failed"
        case .statusUnknown: return "Launch requested — check Steam"
        }
    }
}

/// A PID plus the kernel-reported start time, so a recycled PID is never mistaken for ours.
public struct ProcessIdentity: Codable, Sendable, Hashable {
    public var pid: Int32
    public var startSeconds: Int
    public var startMicroseconds: Int

    public init(pid: Int32, startSeconds: Int, startMicroseconds: Int) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct VersionInfo: Codable, Sendable, Equatable {
    public var macOS: String
    public var hardwareModel: String
    public var runtime: String
    public var launcher: String

    public init(macOS: String, hardwareModel: String, runtime: String, launcher: String) {
        self.macOS = macOS
        self.hardwareModel = hardwareModel
        self.runtime = runtime
        self.launcher = launcher
    }
}

public struct LaunchSession: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var requestedAt: Date
    public var endedAt: Date?
    public var phase: SessionPhase
    public var failureReason: String?
    public var observedGameProcesses: [ProcessIdentity]
    /// Exit status of the steam.exe invocation we started. It may hand off to an existing
    /// Steam instance and exit immediately, so it says nothing about the game's result.
    public var steamRequestExitStatus: Int32?
    public var logFileName: String?
    public var versions: VersionInfo

    public init(
        id: UUID = UUID(),
        requestedAt: Date = Date(),
        phase: SessionPhase = .launchRequested,
        versions: VersionInfo,
        logFileName: String? = nil
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.phase = phase
        self.observedGameProcesses = []
        self.versions = versions
        self.logFileName = logFileName
    }
}

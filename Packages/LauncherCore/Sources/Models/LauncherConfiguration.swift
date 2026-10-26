import Foundation

public struct LauncherConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maxRecentSessions = 20

    public var schemaVersion: Int
    public var runtimes: [RuntimeDescriptor]
    public var prefixes: [PrefixDescriptor]
    public var profiles: [GameProfile]
    public var activeRuntimeID: UUID?
    public var activePrefixID: UUID?
    public var activeProfileID: UUID?
    public var steamInstaller: URL?
    /// A steam.exe inside the prefix chosen manually when automatic discovery fails.
    public var steamExecutableOverride: URL?
    /// Options for the Steam client itself (for example `-cef-disable-gpu`), used whenever
    /// steam.exe starts. Optional so configurations written before this field still load.
    public var steamClientArguments: [String]?
    /// When set, this shim replaces steamwebhelper.exe before every Steam start (see WebHelperShim).
    public var steamWebHelperShim: URL?
    /// Verbose Wine logging distorts performance and uses disk space, so it is opt-in.
    public var verboseWineLogging: Bool
    public var recentSessions: [LaunchSession]

    public init() {
        schemaVersion = Self.currentSchemaVersion
        runtimes = []
        prefixes = []
        profiles = []
        verboseWineLogging = false
        recentSessions = []
    }

    public var activeRuntime: RuntimeDescriptor? {
        runtimes.first { $0.id == activeRuntimeID }
    }

    public var activePrefix: PrefixDescriptor? {
        prefixes.first { $0.id == activePrefixID }
    }

    public var activeProfile: GameProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    public mutating func record(_ session: LaunchSession) {
        if let index = recentSessions.firstIndex(where: { $0.id == session.id }) {
            recentSessions[index] = session
        } else {
            recentSessions.insert(session, at: 0)
        }
        if recentSessions.count > Self.maxRecentSessions {
            recentSessions.removeLast(recentSessions.count - Self.maxRecentSessions)
        }
    }
}

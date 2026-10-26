import Foundation

public enum LaunchAction: Sendable, Equatable {
    case queryVersion
    case initializePrefix
    /// `wineserver -w`: wait until every program in the prefix has exited.
    case waitForPrefixIdle
    case runInstaller(URL)
    case openSteam(steamExecutable: URL)
    case launchGame(steamExecutable: URL, appID: Int, arguments: [String])
    /// `wineserver -k`: stops every program in this prefix, and only this prefix.
    case shutdownPrefix
    /// `tasklist.exe`: the Windows processes of this prefix, as CSV.
    case listProcesses
}

public struct LaunchContext: Sendable {
    public var runtime: RuntimeDescriptor
    public var prefix: URL
    public var backend: GraphicsBackend
    public var verboseLogging: Bool
    /// Passed to steam.exe before any `-applaunch` request.
    public var steamClientArguments: [String]
    public var hostEnvironment: [String: String]

    public init(
        runtime: RuntimeDescriptor,
        prefix: URL,
        backend: GraphicsBackend = .runtimeDefault,
        verboseLogging: Bool = false,
        steamClientArguments: [String] = [],
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runtime = runtime
        self.prefix = prefix
        self.backend = backend
        self.verboseLogging = verboseLogging
        self.steamClientArguments = steamClientArguments
        self.hostEnvironment = hostEnvironment
    }
}

/// Translates project-level actions into runtime-specific invocations.
public protocol RuntimeAdapter: Sendable {
    var kind: RuntimeAdapterKind { get }
    var supportedBackends: [GraphicsBackend] { get }
    func plan(_ action: LaunchAction, context: LaunchContext) throws -> LaunchPlan
}

public enum RuntimeAdapters {
    public static func adapter(for kind: RuntimeAdapterKind) -> any RuntimeAdapter {
        switch kind {
        case .standardWine: return StandardWineAdapter()
        }
    }
}

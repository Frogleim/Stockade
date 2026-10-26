import Foundation

/// A Wine build used as `wine <program>` with `wineserver` beside it.
///
/// The executable is started directly. x86-64 builds run through Rosetta automatically;
/// nothing is wrapped in `arch -x86_64` or a shell.
public struct StandardWineAdapter: RuntimeAdapter {
    public init() {}

    public var kind: RuntimeAdapterKind { .standardWine }

    /// Backend switching is deliberately absent until two combinations are verified,
    /// so only the runtime's own default is offered.
    public var supportedBackends: [GraphicsBackend] { [.runtimeDefault] }

    public func plan(_ action: LaunchAction, context: LaunchContext) throws -> LaunchPlan {
        guard supportedBackends.contains(context.backend) else {
            throw LauncherError.processLaunchFailed(detail: "backend \(context.backend.displayName) is not supported by this runtime adapter")
        }
        let wine = context.runtime.wineExecutable
        let wineserver = context.runtime.wineserverExecutable
        let environment = makeEnvironment(context)

        switch action {
        case .queryVersion:
            return LaunchPlan(
                purpose: .queryVersion,
                executable: wine,
                arguments: ["--version"],
                workingDirectory: wine.deletingLastPathComponent(),
                environment: environment
            )
        case .initializePrefix:
            return LaunchPlan(
                purpose: .initializePrefix,
                executable: wine,
                arguments: ["wineboot", "--init"],
                workingDirectory: context.prefix,
                environment: environment
            )
        case .waitForPrefixIdle:
            return LaunchPlan(
                purpose: .waitForPrefixIdle,
                executable: wineserver,
                arguments: ["-w"],
                workingDirectory: context.prefix,
                environment: environment
            )
        case .runInstaller(let installer):
            return LaunchPlan(
                purpose: .runInstaller,
                executable: wine,
                arguments: [installer.path],
                workingDirectory: installer.deletingLastPathComponent(),
                environment: environment
            )
        case .openSteam(let steam):
            return LaunchPlan(
                purpose: .openSteam,
                executable: wine,
                arguments: [steam.path] + context.steamClientArguments,
                workingDirectory: steam.deletingLastPathComponent(),
                environment: environment
            )
        case .launchGame(let steam, let appID, let arguments):
            return LaunchPlan(
                purpose: .launchGame,
                executable: wine,
                arguments: [steam.path] + context.steamClientArguments + ["-applaunch", String(appID)] + arguments,
                workingDirectory: steam.deletingLastPathComponent(),
                environment: environment
            )
        case .listProcesses:
            var quiet = environment
            quiet["WINEDEBUG"] = "-all"
            return LaunchPlan(
                purpose: .listProcesses,
                executable: wine,
                arguments: ["tasklist.exe", "/FO", "CSV", "/NH"],
                workingDirectory: context.prefix,
                environment: quiet
            )
        case .shutdownPrefix:
            return LaunchPlan(
                purpose: .shutdownPrefix,
                executable: wineserver,
                arguments: ["-k"],
                workingDirectory: context.prefix,
                environment: environment,
                affectsWholePrefix: true
            )
        }
    }

    private func makeEnvironment(_ context: LaunchContext) -> [String: String] {
        var env = EnvironmentPolicy.base(from: context.hostEnvironment)
        let runtimeBin = context.runtime.wineExecutable.deletingLastPathComponent().path
        env["PATH"] = runtimeBin + ":" + EnvironmentPolicy.basePath
        env["WINEPREFIX"] = context.prefix.path
        env["WINEDEBUG"] = context.verboseLogging ? "err+all,warn+all,fixme-all" : "-all"
        return env
    }
}

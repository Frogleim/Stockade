import Foundation
import LauncherCore

/// Development harness over the same LauncherEngine API the app uses.
let usage = """
usage: stockade-cli [--data-dir <path>] <command> [arguments]

commands:
  status                         show what is configured and what is missing
  select-runtime <wine> [name]   validate a Wine executable and make it active
  create-prefix [name]           create (or reuse) the prefix for the active runtime
  prefixes                       list prefixes; * marks the active one
  use-prefix <number>            switch to a prefix and the runtime that owns it
  adopt-prefix <number>          hand a prefix to the active runtime (same Wine version only)
  import-game <number>           clone the installed game from another prefix (Steam closed)
  init-prefix                    run wineboot in the prefix
  install-steam <SteamSetup.exe> run the Windows Steam installer in the prefix
  open-steam                     open Windows Steam (sign in and install the game there)
  ps                             show what is running in the active prefix
  plan                           print the sanitized game launch plan without running it
  launch                         request the game launch and follow its status
  shutdown-prefix --yes          stop every program in the launcher's prefix (wineserver -k)
  diagnostics [file]             print or write a sanitized diagnostics report
  backup                         back up the verified save directory
  backups                        list save backups
  set-saves <directory>          record the verified save directory
  game-args [args… | --clear]    show or set arguments passed to the game after -applaunch
  steam-args [args… | --clear]   show or set options passed to steam.exe (e.g. -cef-disable-gpu)
  verbose <on|off>               verbose Wine logging (slower; for investigating problems)
  webhelper-shim <shim.exe | --remove>  install the black-window fix (build it with scripts/build-shim.sh)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ error: Error) -> String {
    if let error = error as? LauncherError {
        return [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n  ")
    }
    return error.localizedDescription
}

var args = Array(CommandLine.arguments.dropFirst())
var paths = AppPaths.standard()
if let index = args.firstIndex(of: "--data-dir") {
    guard index + 1 < args.count else { fail(usage) }
    paths = AppPaths(root: URL(fileURLWithPath: args[index + 1]))
    args.removeSubrange(index...index + 1)
}
guard let command = args.first else { fail(usage) }
let rest = Array(args.dropFirst())
// Status lines must appear immediately, even when stdout is a pipe or a file.
setvbuf(stdout, nil, _IOLBF, 0)

let printLine: OutputHandler = { print("[\($0.stream.rawValue)] \($0.text)") }

let engine = LauncherEngine(paths: paths)

do {
    try await engine.load()

    switch command {
    case "status":
        let ready = await engine.readiness()
        print("runtime:  \(ready.runtime.map { "\($0.displayName) — \($0.versionOutput)" } ?? "none")")
        print("prefix:   \(ready.prefix?.url.path ?? "none") [\(ready.prefixStatus?.rawValue ?? "-")]")
        print("steam:    \(ready.steamExecutable?.path ?? "not found")")
        print("game:     \(ready.installStatus?.summary ?? "unknown")")
        print("launch:   \(ready.canLaunch ? "ready" : "not ready")")
        ready.problems.forEach { print("  - \($0)") }

    case "select-runtime":
        guard let path = rest.first else { fail(usage) }
        let report = try await engine.selectRuntime(
            wineExecutable: URL(fileURLWithPath: path),
            displayName: rest.dropFirst().first
        )
        let d = report.descriptor
        print("validated \(d.versionOutput)")
        print("  wine:       \(d.wineExecutable.path)")
        print("  wineserver: \(d.wineserverExecutable.path)")
        print("  arch:       \(d.architectures.map(\.rawValue).joined(separator: ", "))")
        print("  backends:   \(d.detectedBackends.map(\.displayName).joined(separator: ", "))")
        print("  sha256:     \(d.executableSHA256)")
        report.warnings.forEach { print("  warning: \($0)") }

    case "create-prefix":
        let prefix = try await engine.createPrefix(named: rest.first)
        print("prefix: \(prefix.url.path)")

    case "prefixes":
        let config = await engine.configuration
        for (index, prefix) in config.prefixes.enumerated() {
            let runtime = config.runtimes.first { $0.id == prefix.runtimeID }?.displayName ?? "unknown runtime"
            print("\(prefix.id == config.activePrefixID ? "*" : " ") \(index + 1). \(prefix.url.lastPathComponent) — \(runtime)")
        }

    case "use-prefix", "import-game", "adopt-prefix":
        let config = await engine.configuration
        guard let number = rest.first.flatMap(Int.init), config.prefixes.indices.contains(number - 1) else { fail(usage) }
        let id = config.prefixes[number - 1].id
        if command == "adopt-prefix" {
            try await engine.adoptPrefix(id)
            print("prefix \(config.prefixes[number - 1].url.lastPathComponent) now uses the active runtime")
        } else if command == "use-prefix" {
            try await engine.selectPrefix(id)
            print("active prefix: \(config.prefixes[number - 1].url.lastPathComponent)")
        } else {
            let destination = try await engine.importGame(from: id)
            print("game available at \(destination.path)")
        }

    case "init-prefix":
        try await engine.initializePrefix(onOutput: printLine)
        print("prefix initialized")

    case "install-steam":
        guard let path = rest.first else { fail(usage) }
        let exit = try await engine.runSteamInstaller(URL(fileURLWithPath: path))
        print("installer exited with status \(exit.status)")

    case "open-steam":
        try await engine.openSteam()
        print("Steam requested. Sign in and install the game inside Steam.")
        // Keep the harness alive briefly so the child is fully detached before we exit.
        try await Task.sleep(for: .seconds(2))

    case "ps":
        guard let snapshot = await engine.prefixSnapshot() else { fail("No prefix configured.") }
        print("prefix active: \(snapshot.isActive ? "yes" : "no")")
        print("steam:  \(snapshot.steamProcesses.isEmpty ? "not running" : "running")")
        print("game:   \(snapshot.gameProcesses.isEmpty ? "not running" : "running")")
        snapshot.prefixProcesses.forEach { print("  \($0.identity.pid)  \($0.arguments.first ?? "?")") }

    case "plan":
        print(try await engine.launchPlan().sanitizedDescription(redactor: Redactor()))

    case "launch":
        let done = AsyncStream<LaunchSession>.makeStream()
        _ = try await engine.launchGame { session in
            let reason = session.failureReason.map { " — \($0)" } ?? ""
            print("\(ISO8601DateFormatter().string(from: Date()))  \(session.phase.headline)\(reason)")
            done.continuation.yield(session)
        }
        for await session in done.stream {
            if session.phase == .exited || session.phase == .failed { break }
        }

    case "shutdown-prefix":
        guard rest.contains("--yes") else {
            fail("This stops every Windows program in the launcher's prefix, including Steam. Re-run with --yes.")
        }
        let exit = try await engine.shutdownPrefix()
        print("wineserver -k exited with status \(exit.status)")

    case "diagnostics":
        if let path = rest.first {
            try await engine.exportDiagnostics(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } else {
            print(await engine.diagnosticsReport())
        }

    case "set-saves":
        guard let path = rest.first else { fail(usage) }
        let url = URL(fileURLWithPath: path)
        try await engine.update { config in
            guard let id = config.activeProfileID, let i = config.profiles.firstIndex(where: { $0.id == id }) else { return }
            config.profiles[i].saveDirectory = url
        }
        print("save directory: \(path)")

    case "game-args":
        let values = rest == ["--clear"] ? [] : rest
        if !rest.isEmpty {
            try await engine.update { config in
                guard let id = config.activeProfileID, let i = config.profiles.firstIndex(where: { $0.id == id }) else { return }
                config.profiles[i].launchArguments = values
            }
        }
        let current = await engine.configuration.activeProfile?.launchArguments ?? []
        print("game arguments: \(current.isEmpty ? "none" : current.joined(separator: " "))")

    case "steam-args":
        if rest == ["--clear"] {
            try await engine.update { $0.steamClientArguments = nil }
        } else if !rest.isEmpty {
            let values = rest
            try await engine.update { $0.steamClientArguments = values }
        }
        let current = await engine.configuration.steamClientArguments ?? []
        print("steam client arguments: \(current.isEmpty ? "none" : current.joined(separator: " "))")

    case "verbose":
        guard let value = rest.first, value == "on" || value == "off" else { fail(usage) }
        let enabled = value == "on"
        try await engine.update { $0.verboseWineLogging = enabled }
        print("verbose Wine logging: \(value)")

    case "webhelper-shim":
        guard let value = rest.first else { fail(usage) }
        if value == "--remove" {
            try await engine.setWebHelperShim(nil)
            print("Steam's original steamwebhelper.exe restored")
        } else {
            try await engine.setWebHelperShim(URL(fileURLWithPath: value))
            print("steamwebhelper shim installed; it is re-applied before every Steam start")
        }

    case "backup":
        let record = try await engine.backupSaves()
        print("backup: \(record.url.path) (\(record.manifest.files.count) files, verified)")

    case "backups":
        for record in await engine.listBackups() {
            print("\(record.manifest.createdAt)  \(record.manifest.files.count) files  \(record.url.lastPathComponent)")
        }

    default:
        fail(usage)
    }
} catch {
    fail("error: \(describe(error))")
}

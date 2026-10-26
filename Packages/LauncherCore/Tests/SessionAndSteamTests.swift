import Foundation
import Testing
@testable import LauncherCore

@Suite struct SessionStateMachineTests {
    let versions = VersionInfo(macOS: "x", hardwareModel: "x", runtime: "x", launcher: "x")
    let prefix = URL(fileURLWithPath: "/tmp/p")

    func snapshot(steam: Bool = false, game: Bool = false) -> PrefixSnapshot {
        let s = steam ? [fakeProcess(pid: 1, args: ["steam.exe"], prefix: prefix)] : []
        let g = game ? [fakeProcess(pid: 2, args: ["Farthest Frontier.exe"], prefix: prefix)] : []
        return PrefixSnapshot(prefixProcesses: s + g, steamProcesses: s, gameProcesses: g)
    }

    @Test func handoffToRunningSteamIsNotTreatedAsGameExit() {
        var session = LaunchSession(versions: versions)
        SessionStateMachine.apply(.launchRequested, to: &session)
        // steam.exe forwards the request to the existing Steam and exits 0 right away.
        SessionStateMachine.apply(.steamRequestExited(ProcessExit(status: 0, reason: .exited)), to: &session)
        #expect(session.phase == .launchRequested)
        SessionStateMachine.apply(.snapshot(snapshot(steam: true)), to: &session)
        #expect(session.phase == .starting)
        SessionStateMachine.apply(.snapshot(snapshot(steam: true, game: true)), to: &session)
        #expect(session.phase == .runningObserved)
        #expect(session.observedGameProcesses.map(\.pid) == [2])
        // Steam stays open after the game exits.
        SessionStateMachine.apply(.snapshot(snapshot(steam: true)), to: &session)
        #expect(session.phase == .exited)
    }

    @Test func nothingObservedBecomesUnknownNotRunning() {
        var session = LaunchSession(versions: versions)
        SessionStateMachine.apply(.launchRequested, to: &session)
        SessionStateMachine.apply(.snapshot(snapshot()), to: &session)
        SessionStateMachine.apply(.observationWindowElapsed, to: &session)
        #expect(session.phase == .statusUnknown)
        #expect(session.phase.headline == "Launch requested — check Steam")
        SessionStateMachine.apply(.snapshot(snapshot(game: true)), to: &session)
        #expect(session.phase == .runningObserved)
    }

    @Test func earlyNonZeroExitIsAFailure() {
        var session = LaunchSession(versions: versions)
        SessionStateMachine.apply(.launchRequested, to: &session)
        SessionStateMachine.apply(.steamRequestExited(ProcessExit(status: 3, reason: .exited)), to: &session)
        #expect(session.phase == .failed)
        #expect(session.failureReason?.contains("3") == true)
    }

    @Test func emptyPrefixAfterHandoffEndsTheSession() {
        var session = LaunchSession(versions: versions)
        SessionStateMachine.apply(.launchRequested, to: &session)
        SessionStateMachine.apply(.snapshot(snapshot(steam: true)), to: &session)
        // Before the request process exits, an empty snapshot is not conclusive.
        SessionStateMachine.apply(.snapshot(snapshot()), to: &session)
        #expect(session.phase == .starting)
        SessionStateMachine.apply(.steamRequestExited(ProcessExit(status: 0, reason: .exited)), to: &session)
        SessionStateMachine.apply(.snapshot(snapshot()), to: &session)
        #expect(session.phase == .failed)
        #expect(session.endedAt != nil)
    }

    @Test func steamExitDuringGameDoesNotChangeTheGameResult() {
        var session = LaunchSession(versions: versions)
        SessionStateMachine.apply(.launchRequested, to: &session)
        SessionStateMachine.apply(.snapshot(snapshot(steam: true, game: true)), to: &session)
        SessionStateMachine.apply(.steamRequestExited(ProcessExit(status: 1, reason: .exited)), to: &session)
        #expect(session.phase == .runningObserved)
    }
}

@Suite struct SteamTests {
    @Test func vdfParsesNestedLibrariesWithEscapes() throws {
        let text = #"""
        "libraryfolders"
        {
            // comment
            "0"
            {
                "path"		"C:\\Program Files (x86)\\Steam"
                "apps" { "228980" "1" }
            }
            "1"
            {
                "path"		"D:\\Steam Library"
            }
        }
        """#
        let root = try VDFNode.parse(text)
        #expect(root["libraryfolders"]?["0"]?["path"]?.stringValue == #"C:\Program Files (x86)\Steam"#)
        #expect(root["LIBRARYFOLDERS"]?["1"]?["path"]?.stringValue == #"D:\Steam Library"#)
        #expect(throws: VDFParseError.self) { try VDFNode.parse(#""a" { "b" "c" "#) }
    }

    @Test func windowsPathsMapIntoThePrefix() {
        let prefix = URL(fileURLWithPath: "/tmp/My Prefix")
        #expect(WindowsPath.toPOSIX(#"C:\Program Files (x86)\Steam"#, prefix: prefix)?.path
            == "/tmp/My Prefix/drive_c/Program Files (x86)/Steam")
        #expect(WindowsPath.toPOSIX(#"C:\..\..\etc"#, prefix: prefix) == nil)
        #expect(WindowsPath.toPOSIX("relative", prefix: prefix) == nil)
    }

    @Test func installStatusReadsManifestsAcrossLibraries() throws {
        let dir = TempDirectory()
        let prefix = dir.url
        let steamExe = dir.file("drive_c/Program Files (x86)/Steam/steam.exe")
        _ = dir.file("drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf", contents: #"""
        "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "1" { "path" "C:\\Games Library" } }
        """#)
        let service = SteamService()
        #expect(service.installStatus(appID: 1044720, steamExecutable: steamExe, prefix: prefix) == .notInstalled)

        let manifest = dir.file("drive_c/Games Library/steamapps/appmanifest_1044720.acf", contents: #"""
        "AppState" { "appid" "1044720" "StateFlags" "1026" "installdir" "Farthest Frontier" "buildid" "42" }
        """#)
        #expect(service.installStatus(appID: 1044720, steamExecutable: steamExe, prefix: prefix) == .incomplete(stateFlags: 1026))

        try Data(#""AppState" { "StateFlags" "4" "installdir" "Farthest Frontier" "buildid" "42" }"#.utf8).write(to: manifest)
        _ = dir.file("drive_c/Games Library/steamapps/common/Farthest Frontier/game.exe")
        guard case .installed(_, let build) = service.installStatus(appID: 1044720, steamExecutable: steamExe, prefix: prefix) else {
            Issue.record("expected installed"); return
        }
        #expect(build == "42")
    }

    @Test func steamOverrideMustBeInsidePrefix() throws {
        let dir = TempDirectory()
        let prefix = dir.url.appendingPathComponent("Prefix")
        let outside = dir.file("Elsewhere/steam.exe")
        #expect(throws: LauncherError.self) { try SteamService().locateSteam(prefix: prefix, override: outside) }
        let inside = dir.file("Prefix/drive_c/Custom/Steam.exe")
        #expect(try SteamService().locateSteam(prefix: prefix, override: inside) == inside)
    }
}

@Suite struct EngineIntegrationTests {
    @Test func fullSetupAndTruthfulLaunchWithFakeRuntime() async throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url.appendingPathComponent("Launcher Data"))
        let wine = FakeRuntime.make(in: dir)
        let gamePrefix = paths.prefixesRoot.appendingPathComponent("Farthest Frontier Prefix")

        // Poll 1–2: only Steam. Poll 3–5: game running. Afterwards: Steam only again.
        let inspector = FakeInspector { n in
            var list = [fakeProcess(pid: 100, args: [#"C:\Program Files (x86)\Steam\steam.exe"#], prefix: gamePrefix)]
            if (3...5).contains(n) {
                list.append(fakeProcess(pid: 200, args: [#"C:\Games\Farthest Frontier.exe"#], prefix: gamePrefix))
            }
            return list
        }
        let engine = LauncherEngine(paths: paths, inspector: inspector, pollInterval: .milliseconds(20))
        try await engine.load()

        let report = try await engine.selectRuntime(wineExecutable: wine)
        #expect(report.descriptor.versionOutput.contains("fake"))
        let prefix = try await engine.createPrefix()
        #expect(prefix.url.path == gamePrefix.path)
        try await engine.initializePrefix()

        var ready = await engine.readiness()
        #expect(ready.prefixStatus == .initialized)
        #expect(!ready.canLaunch)   // Steam not installed yet

        // Stand in for the Steam installer.
        try FileManager.default.createDirectory(
            at: gamePrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam"),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: gamePrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path,
            contents: nil
        )
        ready = await engine.readiness()
        #expect(ready.canLaunch, "problems: \(ready.problems)")

        let phases = PhaseRecorder()
        let first = try await engine.launchGame { phases.add($0.phase) }
        #expect(first.phase == .launchRequested)
        await #expect(throws: LauncherError.self) { _ = try await engine.launchGame() }

        let finished = await eventually { phases.all.last == .exited }
        #expect(finished, "phases: \(phases.all)")
        #expect(phases.all.contains(.runningObserved))
        #expect(!phases.all.contains(.failed))
        #expect(await engine.hasActiveSession == false)

        let config = await engine.configuration
        #expect(config.recentSessions.first?.phase == .exited)
        #expect(config.activePrefix?.lastSuccessfulLaunch != nil)

        // Configuration survives a restart.
        let reloaded = LauncherEngine(paths: paths, inspector: inspector)
        try await reloaded.load()
        #expect(await reloaded.configuration.activeRuntime?.id == report.descriptor.id)

        let diagnostics = await engine.diagnosticsReport()
        #expect(diagnostics.contains("1044720"))
        #expect(!diagnostics.contains(NSHomeDirectory()))
    }

    @Test func activeSessionsFromAPreviousRunBecomeUnknown() async throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url)
        var config = LauncherConfiguration()
        config.record(LaunchSession(phase: .runningObserved, versions: VersionInfo(macOS: "", hardwareModel: "", runtime: "", launcher: "")))
        try ConfigurationStore(fileURL: paths.configurationFile).save(config)
        let engine = LauncherEngine(paths: paths, inspector: FakeInspector { _ in [] })
        try await engine.load()
        #expect(await engine.configuration.recentSessions.first?.phase == .statusUnknown)
    }
}

final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [SessionPhase] = []
    func add(_ phase: SessionPhase) { lock.lock(); phases.append(phase); lock.unlock() }
    var all: [SessionPhase] { lock.lock(); defer { lock.unlock() }; return phases }
}

@Suite struct MultiPrefixTests {
    @Test func eachRuntimeGetsItsOwnPrefixAndSwitchingFollowsOwnership() async throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url.appendingPathComponent("Data"))
        let engine = LauncherEngine(paths: paths, inspector: FakeInspector { _ in [] })
        try await engine.load()

        let first = try await engine.selectRuntime(wineExecutable: FakeRuntime.make(in: dir)).descriptor
        let a = try await engine.createPrefix()
        #expect(try await engine.createPrefix() == a)

        let second = TempDirectory()
        let other = try await engine.selectRuntime(wineExecutable: FakeRuntime.make(in: second), displayName: "Other").descriptor
        let b = try await engine.createPrefix()
        #expect(b.id != a.id)
        #expect(b.runtimeID == other.id)
        #expect(a.url != b.url)

        try await engine.selectPrefix(a.id)
        var config = await engine.configuration
        #expect(config.activeRuntimeID == first.id)
        #expect(config.activeProfile?.prefixID == a.id)

        try await engine.update { $0.activeRuntimeID = other.id }
        let again = try await engine.createPrefix()
        #expect(again.id == b.id, "got \(again.url.lastPathComponent) runtime \(again.runtimeID == other.id) vs b \(b.url.lastPathComponent)")
        #expect(again.url.path == b.url.path)
        config = await engine.configuration
        #expect(config.activePrefixID == b.id)
    }
}

import Foundation
import Testing
@testable import LauncherCore

@Suite struct LaunchPlanTests {
    @Test func gameLaunchArgumentsSurviveSpacesQuotesUnicodeAndShellSyntax() async throws {
        let dir = TempDirectory()
        let wine = FakeRuntime.make(in: dir)
        let steam = dir.file("Prefix With Spaces/drive_c/Program Files (x86)/Steam/steam.exe")
        let tricky = ["-windowed", "it's \"quoted\"", "ünïcødé 🚀", "$(touch /tmp/pwned)", "; rm -rf ~", "a\\b", ""]

        let plan = try StandardWineAdapter().plan(
            .launchGame(steamExecutable: steam, appID: 1044720, arguments: tricky),
            context: LaunchContext(runtime: sampleRuntime(wine: wine), prefix: dir.url.appendingPathComponent("Prefix With Spaces"))
        )
        #expect(plan.executable == wine)
        #expect(plan.arguments == [steam.path, "-applaunch", "1044720"] + tricky)

        // The fake wine prints each argument on its own line; nothing may be reinterpreted.
        let result = try await ProcessSupervisor().run(plan, timeout: .seconds(10))
        let printed = result.tail.filter { $0.stream == .stdout }.map(\.text)
        #expect(printed == plan.arguments)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    @Test func environmentIsAllowlistedAndPrefixIsExplicit() throws {
        let dir = TempDirectory()
        let wine = FakeRuntime.make(in: dir)
        let host = [
            "HOME": "/Users/someone", "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "DYLD_INSERT_LIBRARIES": "/evil.dylib",
            "WINEDLLOVERRIDES": "d3d11=n",
            "WINEPREFIX": "/somewhere/else",
            "AWS_SECRET_ACCESS_KEY": "nope",
        ]
        let prefix = dir.url.appendingPathComponent("My Prefix")
        let plan = try StandardWineAdapter().plan(
            .initializePrefix,
            context: LaunchContext(runtime: sampleRuntime(wine: wine), prefix: prefix, hostEnvironment: host)
        )
        #expect(plan.environment["WINEPREFIX"] == prefix.path)
        #expect(plan.environment["WINEDLLOVERRIDES"] == nil)
        #expect(plan.environment["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(plan.environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(plan.environment["PATH"] == wine.deletingLastPathComponent().path + ":" + EnvironmentPolicy.basePath)
        #expect(plan.environment["LC_ALL"] == "C")
        #expect(plan.environment["WINEDEBUG"] == "-all")
        #expect(plan.arguments == ["wineboot", "--init"])
    }

    @Test func steamClientArgumentsComeBeforeTheLaunchRequest() throws {
        let dir = TempDirectory()
        let runtime = sampleRuntime(wine: FakeRuntime.make(in: dir))
        let steam = dir.file("steam.exe")
        let context = LaunchContext(runtime: runtime, prefix: dir.url, steamClientArguments: ["-cef-disable-gpu"])
        let open = try StandardWineAdapter().plan(.openSteam(steamExecutable: steam), context: context)
        #expect(open.arguments == [steam.path, "-cef-disable-gpu"])
        let launch = try StandardWineAdapter().plan(
            .launchGame(steamExecutable: steam, appID: 1044720, arguments: ["-windowed"]), context: context
        )
        #expect(launch.arguments == [steam.path, "-cef-disable-gpu", "-applaunch", "1044720", "-windowed"])
    }

    @Test func configurationWithoutNewerOptionalFieldsStillLoads() throws {
        let dir = TempDirectory()
        let file = dir.url.appendingPathComponent("configuration.json")
        let legacy = #"{"schemaVersion":1,"runtimes":[],"prefixes":[],"profiles":[],"verboseWineLogging":false,"recentSessions":[]}"#
        try Data(legacy.utf8).write(to: file)
        #expect(try ConfigurationStore(fileURL: file).load().configuration.steamClientArguments == nil)
    }

    @Test func shutdownIsMarkedPrefixWide() throws {
        let dir = TempDirectory()
        let runtime = sampleRuntime(wine: FakeRuntime.make(in: dir))
        let plan = try StandardWineAdapter().plan(.shutdownPrefix, context: LaunchContext(runtime: runtime, prefix: dir.url))
        #expect(plan.executable == runtime.wineserverExecutable)
        #expect(plan.arguments == ["-k"])
        #expect(plan.affectsWholePrefix)
    }

    @Test func unverifiedBackendIsRejected() throws {
        let dir = TempDirectory()
        let runtime = sampleRuntime(wine: FakeRuntime.make(in: dir))
        #expect(throws: LauncherError.self) {
            try StandardWineAdapter().plan(.queryVersion, context: LaunchContext(runtime: runtime, prefix: dir.url, backend: .dxmt))
        }
    }

    @Test func sanitizedDescriptionHidesUnlistedVariables() throws {
        let plan = LaunchPlan(
            purpose: .launchGame,
            executable: URL(fileURLWithPath: "/Users/alice/wine/bin/wine"),
            arguments: ["/Users/alice/prefix/steam.exe"],
            workingDirectory: URL(fileURLWithPath: "/Users/alice"),
            environment: ["WINEPREFIX": "/Users/alice/prefix", "HOME": "/Users/alice", "SECRET": "x"]
        )
        let text = plan.sanitizedDescription(redactor: Redactor(homeDirectory: "/Users/alice", userName: "alice"))
        #expect(!text.contains("alice"))
        #expect(!text.contains("SECRET"))
        #expect(text.contains("WINEPREFIX=~/prefix"))
        #expect(text.contains("2 other variable(s) omitted"))
    }
}

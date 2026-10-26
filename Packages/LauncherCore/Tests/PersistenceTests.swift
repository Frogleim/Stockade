import Foundation
import Testing
@testable import LauncherCore

@Suite struct ConfigurationStoreTests {
    @Test func roundTrip() throws {
        let dir = TempDirectory()
        let store = ConfigurationStore(fileURL: dir.url.appendingPathComponent("configuration.json"))
        #expect(try store.load() == .fresh(LauncherConfiguration()))
        var config = LauncherConfiguration()
        config.verboseWineLogging = true
        config.steamInstaller = URL(fileURLWithPath: "/Users/x/Downloads/SteamSetup.exe")
        try store.save(config)
        #expect(try store.load().configuration == config)
    }

    @Test func futureSchemaIsRejectedAndNeverOverwritten() throws {
        let dir = TempDirectory()
        let file = dir.url.appendingPathComponent("configuration.json")
        let future = #"{"schemaVersion": 99, "somethingNew": true}"#
        try Data(future.utf8).write(to: file)
        let store = ConfigurationStore(fileURL: file)
        #expect(throws: LauncherError.configurationFromFuture(found: 99, supported: 1)) { try store.load() }
        #expect(throws: LauncherError.configurationFromFuture(found: 99, supported: 1)) { try store.save(LauncherConfiguration()) }
        #expect(try String(contentsOf: file, encoding: .utf8) == future)
    }

    @Test func interruptedWriteRecoversLastGood() throws {
        let dir = TempDirectory()
        let file = dir.url.appendingPathComponent("configuration.json")
        let store = ConfigurationStore(fileURL: file)
        var config = LauncherConfiguration()
        config.verboseWineLogging = true
        try store.save(config)
        // Simulate a torn write from a crash or a hand edit.
        try Data(#"{"schemaVersion": 1, "runti"#.utf8).write(to: file)

        guard case .recovered(let recovered, let damaged) = try store.load() else {
            Issue.record("expected recovery"); return
        }
        #expect(recovered == config)
        #expect(FileManager.default.fileExists(atPath: damaged.path))
    }

    @Test func corruptWithoutBackupThrows() throws {
        let dir = TempDirectory()
        let file = dir.url.appendingPathComponent("configuration.json")
        try Data("not json".utf8).write(to: file)
        #expect(throws: LauncherError.self) { try ConfigurationStore(fileURL: file).load() }
    }
}

@Suite struct LogStoreTests {
    @Test func rotationBoundsFileCount() throws {
        let dir = TempDirectory()
        let store = LogStore(directory: dir.url, maxFileBytes: 1024, maxFiles: 3)
        for i in 0..<6 {
            let log = try store.makeLog(named: "session \(i)")
            log.append("line \(i)")
            log.close()
        }
        #expect(store.logFiles().count == 3)
    }

    @Test func fileSizeIsBounded() throws {
        let dir = TempDirectory()
        let store = LogStore(directory: dir.url, maxFileBytes: 2000, maxFiles: 2)
        let log = try store.makeLog(named: "big")
        for i in 0..<1000 { log.append("a fairly long log line number \(i)") }
        log.close()
        let size = try FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as! Int
        #expect(size < 2100)
        #expect(store.tail(of: log.url, maxLines: 1).first?.contains("truncated") == true)
    }

    @Test func redactionRemovesPersonalAndSecretData() {
        let r = Redactor(homeDirectory: "/Users/alice", userName: "alice")
        let input = """
        prefix /Users/alice/Library/Application Support/x
        other /Users/bob/file
        wine C:\\users\\alice\\AppData\\Local\\Steam
        token=abc123 password: "hunter 2" Authorization: Bearer
        jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
        hello Alice
        C:\\users\\Public\\Documents
        """
        let out = r.redact(input)
        #expect(!out.lowercased().contains("alice"))
        #expect(!out.contains("bob"))
        #expect(!out.contains("abc123"))
        #expect(!out.contains("hunter"))
        #expect(!out.contains("eyJhbGci"))
        #expect(out.contains("~/Library/Application Support/x"))
        #expect(out.contains("Public"))
    }
}

@Suite struct DiagnosticsTests {
    @Test func reportExcludesEnvironmentDumpAndRedacts() {
        var config = LauncherConfiguration()
        let runtime = sampleRuntime(wine: URL(fileURLWithPath: "/Users/alice/Wine/bin/wine"))
        config.runtimes = [runtime]
        config.activeRuntimeID = runtime.id
        let plan = LaunchPlan(
            purpose: .launchGame,
            executable: runtime.wineExecutable,
            arguments: ["-applaunch", "1044720"],
            workingDirectory: URL(fileURLWithPath: "/Users/alice"),
            environment: ["WINEPREFIX": "/Users/alice/p", "STEAM_TOKEN": "zzz", "HOME": "/Users/alice"]
        )
        let report = DiagnosticsReportBuilder(redactor: Redactor(homeDirectory: "/Users/alice", userName: "alice")).build(
            DiagnosticsInput(
                configuration: config,
                versions: VersionInfo(macOS: "26", hardwareModel: "Mac15,7", runtime: "wine", launcher: "dev"),
                launchPlan: plan,
                logTail: ["Logged in as alice with token=deadbeef"]
            )
        )
        #expect(!report.contains("alice"))
        #expect(!report.contains("zzz"))
        #expect(!report.contains("deadbeef"))
        #expect(report.contains("1044720"))
    }
}

@Suite struct BackupServiceTests {
    func makeSaves(_ dir: TempDirectory) -> URL {
        _ = dir.file("Saves/settlement one.sav", contents: "original 1")
        _ = dir.file("Saves/sub/settlement two.sav", contents: "original 2")
        return dir.url.appendingPathComponent("Saves")
    }

    @Test func backupAndRestorePreservesCurrentSaves() throws {
        let dir = TempDirectory()
        let saves = makeSaves(dir)
        let service = BackupService()
        let record = try service.createBackup(of: saves, into: dir.url.appendingPathComponent("Backups"), gameVersion: "123")
        #expect(record.manifest.files.map(\.relativePath) == ["settlement one.sav", "sub/settlement two.sav"])
        #expect(service.listBackups(in: dir.url.appendingPathComponent("Backups")).map(\.manifest.files) == [record.manifest.files])

        try Data("changed after backup".utf8).write(to: saves.appendingPathComponent("settlement one.sav"))
        let preserved = try service.restore(record, to: saves, confirmation: saves.path)

        #expect(try String(contentsOf: saves.appendingPathComponent("settlement one.sav"), encoding: .utf8) == "original 1")
        let kept = try #require(preserved)
        #expect(try String(contentsOf: kept.appendingPathComponent("settlement one.sav"), encoding: .utf8) == "changed after backup")
    }

    @Test func damagedBackupNeverTouchesCurrentSaves() throws {
        let dir = TempDirectory()
        let saves = makeSaves(dir)
        let service = BackupService()
        let record = try service.createBackup(of: saves, into: dir.url.appendingPathComponent("Backups"), gameVersion: nil)
        try Data("bit rot".utf8).write(to: record.url.appendingPathComponent("files/settlement one.sav"))
        try Data("current".utf8).write(to: saves.appendingPathComponent("settlement one.sav"))

        #expect(throws: LauncherError.self) { try service.restore(record, to: saves, confirmation: saves.path) }
        #expect(try String(contentsOf: saves.appendingPathComponent("settlement one.sav"), encoding: .utf8) == "current")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.contains("restore") }
        #expect(leftovers.isEmpty)
    }

    @Test func restoreRequiresExactConfirmation() throws {
        let dir = TempDirectory()
        let saves = makeSaves(dir)
        let service = BackupService()
        let record = try service.createBackup(of: saves, into: dir.url.appendingPathComponent("Backups"), gameVersion: nil)
        #expect(throws: LauncherError.confirmationMismatch) { try service.restore(record, to: saves, confirmation: "ok") }
    }
}

@Suite struct SharedConfigurationTests {
    @Test func changesFromAnotherProcessAreNotOverwritten() async throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url)
        let app = LauncherEngine(paths: paths, inspector: FakeInspector { _ in [] })
        let cli = LauncherEngine(paths: paths, inspector: FakeInspector { _ in [] })
        try await app.load()
        try await cli.load()
        try await cli.update { $0.steamClientArguments = ["-cef-disable-gpu"] }
        try await app.update { $0.verboseWineLogging = true }
        let reloaded = LauncherEngine(paths: paths, inspector: FakeInspector { _ in [] })
        try await reloaded.load()
        let config = await reloaded.configuration
        #expect(config.steamClientArguments == ["-cef-disable-gpu"])
        #expect(config.verboseWineLogging)
    }
}

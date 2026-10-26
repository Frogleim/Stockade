import Foundation
import Testing
@testable import LauncherCore

@Suite struct WineServerProcessSourceTests {
    @Test func tasklistCSVIsParsedAndWineServicesAreIgnored() {
        let lines = [
            #""steam.exe","32","Console","1","0 K""#,
            #""services.exe","56","Console","1","0 K""#,
            #""Farthest Frontier.exe","952","Console","1","1,234 K""#,
            #""tasklist.exe","1616","Console","1","0 K""#,
            "garbage",
        ]
        let parsed = WineServerProcessSource.parseTasklist(lines)
        #expect(parsed.map(\.image) == ["steam.exe", "services.exe", "Farthest Frontier.exe", "tasklist.exe"])
        let snapshot = WineServerProcessSource.snapshot(from: parsed, gameHints: ["Farthest Frontier.exe"])
        #expect(snapshot.prefixProcesses.map(\.identity.pid) == [32, 952])
        #expect(snapshot.steamProcesses.map(\.identity.pid) == [32])
        #expect(snapshot.gameProcesses.map(\.identity.pid) == [952])
        let idle = WineServerProcessSource.snapshot(from: [("services.exe", 56), ("explorer.exe", 112)], gameHints: [])
        #expect(!idle.isActive)
    }

    @Test func hintsWithWindowsPathsMatchTheImageName() {
        let snapshot = WineServerProcessSource.snapshot(
            from: [("Farthest Frontier.exe", 7)],
            gameHints: [#"C:\Program Files (x86)\Steam\steamapps\common\Farthest Frontier\Farthest Frontier.exe"#]
        )
        #expect(snapshot.gameProcesses.count == 1)
    }

    @Test func serverLockHeldByAnotherProcessMeansActive() async throws {
        let dir = TempDirectory()
        let prefix = dir.url.appendingPathComponent("Prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let source = WineServerProcessSource(serverRoot: dir.url.appendingPathComponent("wine-uid"))
        #expect(!source.isActive(prefix: prefix))

        let serverDir = try #require(source.serverDirectory(for: prefix))
        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        let lock = serverDir.appendingPathComponent("lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        #expect(!source.isActive(prefix: prefix))

        // fcntl locks are per process, so a helper process plays the wineserver.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(30)", lock.path]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        defer { holder.terminate() }
        _ = pipe.fileHandleForReading.availableData   // waits for "locked"
        #expect(source.isActive(prefix: prefix))
        #expect(source.serverPID(prefix: prefix) == holder.processIdentifier)
    }
}

import Foundation
import Testing
@testable import LauncherCore

/// Process-level tests use /bin/sh as a fixture program. The launcher itself never uses a shell.
@Suite struct ProcessSupervisorTests {
    func shellPlan(_ script: String, in dir: URL = FileManager.default.temporaryDirectory) -> LaunchPlan {
        LaunchPlan(
            purpose: .queryVersion,
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectory: dir,
            environment: ["PATH": EnvironmentPolicy.basePath]
        )
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        var stdout = 0
        var stderr = 0
        func add(_ line: OutputLine) {
            lock.lock()
            if line.stream == .stdout { stdout += 1 } else { stderr += 1 }
            lock.unlock()
        }
    }

    @Test func largeConcurrentStreamsDoNotDeadlock() async throws {
        let counter = Counter()
        let script = "i=0; while [ $i -lt 20000 ]; do echo \"out $i\"; echo \"err $i\" 1>&2; i=$((i+1)); done"
        let result = try await ProcessSupervisor().run(shellPlan(script), timeout: .seconds(60), keepLines: 10) {
            counter.add($0)
        }
        #expect(result.exit.succeeded)
        #expect(counter.stdout == 20000)
        #expect(counter.stderr == 20000)
        #expect(result.tail.count == 10)
    }

    @Test func partialAndOverlongLinesAreHandled() async throws {
        let supervisor = ProcessSupervisor(maxLineBytes: 100)
        let result = try await supervisor.run(shellPlan("printf 'no newline'; printf '%0300d' 0 1>&2"))
        let out = result.tail.filter { $0.stream == .stdout }.map(\.text)
        let err = result.tail.filter { $0.stream == .stderr }.map(\.text)
        #expect(out == ["no newline"])
        #expect(err.allSatisfy { $0.utf8.count <= 100 })
        #expect(err.joined().count == 300)
    }

    @Test func timeoutTerminatesOnlyTheChild() async throws {
        await #expect(throws: LauncherError.processTimedOut(seconds: 0)) {
            _ = try await ProcessSupervisor().run(self.shellPlan("sleep 30"), timeout: .milliseconds(300))
        }
    }

    @Test func terminateStopsTheOwnedProcess() async throws {
        let child = try ProcessSupervisor().start(shellPlan("sleep 30")) { _ in }
        #expect(child.identity?.isAlive == true)
        let exit = await child.terminate(grace: .seconds(2))
        #expect(exit.reason == .signaled)
        #expect(child.identity?.isAlive == false)
    }

    @Test func exitIsReportedEvenIfAGrandchildKeepsThePipeOpen() async throws {
        // Like wineserver, the background sleep inherits stdout and keeps it open.
        let supervisor = ProcessSupervisor(drainGrace: .milliseconds(300))
        let started = ContinuousClock.now
        let result = try await supervisor.run(shellPlan("sleep 5 & echo started"), timeout: .seconds(4))
        #expect(result.exit.succeeded)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func launchFailureIsActionable() {
        let plan = LaunchPlan(
            purpose: .queryVersion,
            executable: URL(fileURLWithPath: "/nonexistent/wine"),
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: [:]
        )
        #expect(throws: LauncherError.self) {
            _ = try ProcessSupervisor().start(plan) { _ in }
        }
    }

    @Test func detachedProcessWritesToItsLogFile() async throws {
        let dir = TempDirectory()
        let log = dir.url.appendingPathComponent("out.log")
        let child = try ProcessSupervisor().startDetached(shellPlan("echo hello; echo oops 1>&2"), logFile: log)
        let exit = await child.waitForExit()
        #expect(exit.succeeded)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("hello"))
        #expect(text.contains("oops"))
    }

    @Test func procArgsParserReadsArgumentsAndEnvironment() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes += $0 }
        bytes += Array("/usr/bin/wine".utf8) + [0, 0, 0]
        bytes += Array("C:\\Games\\Farthest Frontier.exe".utf8) + [0]
        bytes += Array("-flag".utf8) + [0]
        bytes += Array("WINEPREFIX=/p q".utf8) + [0]
        bytes += Array("A=b=c".utf8) + [0, 0]
        let parsed = SystemProcessInspector.parseProcArgs(bytes)
        #expect(parsed?.0 == ["C:\\Games\\Farthest Frontier.exe", "-flag"])
        #expect(parsed?.1 == ["WINEPREFIX": "/p q", "A": "b=c"])
    }

    @Test func currentProcessIdentityIsStable() {
        let me = ProcessIdentity.current(pid: getpid())
        #expect(me != nil)
        #expect(me?.isAlive == true)
        #expect(ProcessIdentity.current(pid: getpid()) == me)
    }
}

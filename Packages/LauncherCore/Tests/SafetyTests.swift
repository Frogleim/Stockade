import Foundation
import Testing
@testable import LauncherCore

@Suite struct PathSafetyTests {
    @Test func symlinkEscapingTheOwnedRootIsRejected() throws {
        let dir = TempDirectory()
        let owned = dir.url.appendingPathComponent("Owned")
        let outside = dir.url.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = owned.appendingPathComponent("Sneaky")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: LauncherError.self) { try PathSafety.validateOwnedLocation(link, ownedRoot: owned) }
        #expect(throws: LauncherError.self) {
            try PathSafety.validateOwnedLocation(link.appendingPathComponent("child"), ownedRoot: owned)
        }
    }

    @Test func traversalAndTheRootItselfAreRejected() throws {
        let dir = TempDirectory()
        let owned = dir.url.appendingPathComponent("Owned")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        #expect(throws: LauncherError.self) { try PathSafety.validateOwnedLocation(owned, ownedRoot: owned) }
        let traversal = URL(fileURLWithPath: owned.path + "/../Outside")
        #expect(throws: LauncherError.self) { try PathSafety.validateOwnedLocation(traversal, ownedRoot: owned) }
        try PathSafety.validateOwnedLocation(owned.appendingPathComponent("Not Yet Created/Inner"), ownedRoot: owned)
    }

    @Test func safeComponentStripsSeparators() {
        #expect(PathSafety.safeComponent("../../etc") == "-..-etc")
        #expect(!PathSafety.safeComponent("a/b").contains("/"))
        #expect(PathSafety.safeComponent("...") == "Prefix")
    }

    @Test func unmountedVolumesAreDetected() {
        #expect(PathSafety.isOnUnmountedVolume(URL(fileURLWithPath: "/Volumes/DefinitelyNotMounted-\(UUID())/wine")))
        #expect(!PathSafety.isOnUnmountedVolume(URL(fileURLWithPath: "/usr/bin/true")))
    }
}

@Suite struct PrefixLockTests {
    @Test func secondAcquireFailsUntilReleased() throws {
        let dir = TempDirectory()
        let prefix = dir.url.appendingPathComponent("Prefix")
        let locks = dir.url.appendingPathComponent("Locks")
        let first = try PrefixLock.acquire(prefix: prefix, locksDirectory: locks)
        #expect(throws: LauncherError.prefixBusy(path: prefix.path)) {
            _ = try PrefixLock.acquire(prefix: prefix, locksDirectory: locks)
        }
        first.release()
        let second = try PrefixLock.acquire(prefix: prefix, locksDirectory: locks)
        second.release()
    }

    @Test func differentPrefixesDoNotConflict() throws {
        let dir = TempDirectory()
        let locks = dir.url.appendingPathComponent("Locks")
        let a = try PrefixLock.acquire(prefix: dir.url.appendingPathComponent("A"), locksDirectory: locks)
        let b = try PrefixLock.acquire(prefix: dir.url.appendingPathComponent("B"), locksDirectory: locks)
        a.release()
        b.release()
    }
}

@Suite struct PrefixManagerTests {
    @Test func initializationWritesMarkerOnlyAfterSuccess() async throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url)
        let runtime = sampleRuntime(wine: FakeRuntime.make(in: dir))
        let manager = PrefixManager(paths: paths, observer: PrefixObserver(inspector: FakeInspector { _ in [] }))

        let prefix = try manager.createPrefixDirectory()
        #expect(prefix.lastPathComponent.contains(" "))
        #expect(manager.status(of: prefix) == .uninitialized)
        try await manager.initialize(prefix: prefix, runtime: runtime)
        #expect(manager.status(of: prefix) == .initialized)
        #expect(manager.marker(of: prefix)?.runtimeID == runtime.id)

        var other = runtime
        other.id = UUID()
        await #expect(throws: LauncherError.self) { try await manager.initialize(prefix: prefix, runtime: other) }
    }

    @Test func leftoverInitializingMarkerMeansInterrupted() throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url)
        let manager = PrefixManager(paths: paths, observer: PrefixObserver(inspector: FakeInspector { _ in [] }))
        let prefix = try manager.createPrefixDirectory()
        try Data().write(to: prefix.appendingPathComponent(PrefixManager.initializingMarker))
        #expect(manager.status(of: prefix) == .interrupted)
    }

    @Test func deleteRequiresExactConfirmationAndInactivePrefix() throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url)
        let active = PrefixManager(paths: paths, observer: PrefixObserver(inspector: FakeInspector { _ in
            [fakeProcess(pid: 10, args: ["steam.exe"], prefix: paths.prefixesRoot.appendingPathComponent("Farthest Frontier Prefix"))]
        }))
        let prefix = try active.createPrefixDirectory()
        #expect(throws: LauncherError.confirmationMismatch) { try active.delete(prefix: prefix, confirmation: "yes") }
        #expect(throws: LauncherError.prefixActive(path: prefix.path)) { try active.delete(prefix: prefix, confirmation: prefix.path) }

        let idle = PrefixManager(paths: paths, observer: PrefixObserver(inspector: FakeInspector { _ in [] }))
        try idle.delete(prefix: prefix, confirmation: prefix.path)
        #expect(!FileManager.default.fileExists(atPath: prefix.path))
    }

    @Test func deleteRefusesPathsOutsideTheOwnedRoot() throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url)
        try paths.createDirectories()
        let victim = dir.url.appendingPathComponent("Important")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let link = paths.prefixesRoot.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        let manager = PrefixManager(paths: paths, observer: PrefixObserver(inspector: FakeInspector { _ in [] }))
        #expect(throws: LauncherError.self) { try manager.delete(prefix: link, confirmation: link.path) }
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }
}

@Suite struct ObserverTests {
    @Test func onlyProcessesInOurPrefixCount() {
        let ours = URL(fileURLWithPath: "/tmp/ours prefix")
        let inspector = FakeInspector { _ in [
            fakeProcess(pid: 1, args: ["C:\\Steam\\steam.exe"], prefix: ours),
            fakeProcess(pid: 2, args: ["C:\\Games\\Farthest Frontier.exe"], prefix: URL(fileURLWithPath: "/tmp/other")),
            fakeProcess(pid: 3, args: ["/usr/bin/vim"], prefix: nil),
        ] }
        let snapshot = PrefixObserver(inspector: inspector).snapshot(prefix: ours, gameHints: ["Farthest Frontier.exe"])
        #expect(snapshot.prefixProcesses.map(\.identity.pid) == [1])
        #expect(snapshot.steamProcesses.count == 1)
        #expect(snapshot.gameProcesses.isEmpty)
    }
}

@Suite struct RuntimeDiscoveryTests {
    @Test func validatesFakeRuntimeAndRecordsProvenance() async throws {
        let dir = TempDirectory()
        let wine = FakeRuntime.make(in: dir)
        let report = try await RuntimeDiscovery().validate(wineExecutable: wine)
        #expect(report.descriptor.versionOutput == "wine-9.0 (fake)")
        #expect(report.descriptor.architectures == [.script])
        #expect(report.descriptor.executableSHA256.count == 64)
        #expect(report.descriptor.wineserverExecutable.lastPathComponent == "wineserver")
    }

    @Test func missingCompanionAndMissingFileAreDistinct() async throws {
        let dir = TempDirectory()
        let lonely = dir.file("bin/wine", contents: FakeRuntime.wineScript, executable: true)
        await #expect(throws: LauncherError.self) { try await RuntimeDiscovery().validate(wineExecutable: lonely) }
        do {
            _ = try await RuntimeDiscovery().validate(wineExecutable: dir.url.appendingPathComponent("nope/wine"))
            Issue.record("expected failure")
        } catch let error as LauncherError {
            guard case .runtimeNotFound = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func machOArchitecturesAreRead() {
        #expect(MachO.architectures(of: URL(fileURLWithPath: "/bin/ls")).contains(.arm64))
        #expect(MachO.architectures(of: URL(fileURLWithPath: "/etc/hosts")) == [.unknown])
    }

    @Test func dxmtIsDetectedFromRuntimeLayout() {
        let dir = TempDirectory()
        _ = dir.file("lib/wine/x86_64-windows/winemetal.dll")
        #expect(RuntimeDiscovery.detectBackends(runtimeRoot: dir.url).contains(.dxmt))
    }
}

@Suite struct PrefixAdoptionTests {
    @Test func sameVersionIsAdoptedDifferentVersionIsRefused() async throws {
        let dir = TempDirectory()
        let paths = AppPaths(root: dir.url)
        let manager = PrefixManager(paths: paths, observer: PrefixObserver(inspector: FakeInspector { _ in [] }))
        let original = sampleRuntime(wine: FakeRuntime.make(in: dir))
        let prefix = try manager.createPrefixDirectory()
        try await manager.initialize(prefix: prefix, runtime: original)

        var rebuilt = original
        rebuilt.id = UUID()
        try manager.adopt(prefix: prefix, by: rebuilt)
        #expect(manager.marker(of: prefix)?.runtimeID == rebuilt.id)

        var newer = original
        newer.id = UUID()
        newer.versionOutput = "wine-12.0"
        #expect(throws: LauncherError.self) { try manager.adopt(prefix: prefix, by: newer) }
        #expect(manager.marker(of: prefix)?.runtimeID == rebuilt.id)
    }
}

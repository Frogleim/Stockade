import Foundation
@testable import LauncherCore

/// A temporary directory whose path contains spaces and Unicode, removed on deinit.
final class TempDirectory {
    let url: URL

    init(_ name: String = "Stockade Tests ✦") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name) \(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relative: String, contents: String = "", executable: Bool = false) -> URL {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: target)
        if executable {
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        return target
    }
}

/// A fake Wine runtime made of shell scripts, so lifecycle tests need no Wine, Steam or game.
enum FakeRuntime {
    static let wineScript = """
    #!/bin/sh
    case "$1" in
      --version) echo "wine-9.0 (fake)"; exit 0 ;;
      wineboot)
        mkdir -p "$WINEPREFIX/drive_c/windows"
        : > "$WINEPREFIX/system.reg"
        echo "wineboot done"
        exit 0 ;;
      *) printf '%s\\n' "$@"; exit 0 ;;
    esac
    """

    static let wineserverScript = """
    #!/bin/sh
    exit 0
    """

    static func make(in dir: TempDirectory) -> URL {
        _ = dir.file("Fake Runtime/bin/wineserver", contents: wineserverScript, executable: true)
        return dir.file("Fake Runtime/bin/wine", contents: wineScript, executable: true)
    }
}

/// Lets a test decide which processes "exist" on each poll.
final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let script: @Sendable (Int) -> [ObservedProcess]

    init(_ script: @escaping @Sendable (Int) -> [ObservedProcess]) {
        self.script = script
    }

    func userProcesses() -> [ObservedProcess] {
        lock.lock()
        calls += 1
        let n = calls
        lock.unlock()
        return script(n)
    }
}

func fakeProcess(pid: Int32, args: [String], prefix: URL?) -> ObservedProcess {
    ObservedProcess(
        identity: ProcessIdentity(pid: pid, startSeconds: 1, startMicroseconds: 0),
        arguments: args,
        environment: prefix.map { ["WINEPREFIX": $0.path] } ?? [:]
    )
}

func sampleRuntime(wine: URL) -> RuntimeDescriptor {
    RuntimeDescriptor(
        displayName: "Fake",
        wineExecutable: wine,
        wineserverExecutable: wine.deletingLastPathComponent().appendingPathComponent("wineserver"),
        versionOutput: "wine-9.0 (fake)",
        architectures: [.arm64],
        detectedBackends: [.wined3d],
        executableSHA256: "abc"
    )
}

/// Polls `condition` until it is true or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

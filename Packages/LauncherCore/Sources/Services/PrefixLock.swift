import Darwin
import Foundation

/// Cross-process exclusive lock for one prefix, held across initialization, maintenance and launch.
/// The lock file lives outside the prefix so a reset can hold it while deleting the prefix.
public final class PrefixLock: @unchecked Sendable {
    public let prefix: URL
    private var descriptor: Int32
    private let lock = NSLock()

    private init(prefix: URL, descriptor: Int32) {
        self.prefix = prefix
        self.descriptor = descriptor
    }

    public static func lockFile(for prefix: URL, in locksDirectory: URL) -> URL {
        let path = PathSafety.canonical(prefix).path
        // FNV-1a keeps the file name stable and short.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return locksDirectory.appendingPathComponent(String(format: "prefix-%016llx.lock", hash))
    }

    /// Fails immediately with `prefixBusy` instead of waiting.
    public static func acquire(prefix: URL, locksDirectory: URL) throws -> PrefixLock {
        try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
        let file = lockFile(for: prefix, in: locksDirectory)
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw LauncherError.processLaunchFailed(detail: "cannot open lock file: \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LauncherError.prefixBusy(path: prefix.path)
        }
        return PrefixLock(prefix: prefix, descriptor: fd)
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

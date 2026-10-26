import Foundation

public enum OutputStream: String, Codable, Sendable {
    case stdout
    case stderr
}

public struct OutputLine: Sendable, Equatable {
    public var stream: OutputStream
    public var text: String

    public init(stream: OutputStream, text: String) {
        self.stream = stream
        self.text = text
    }
}

public struct ProcessExit: Sendable, Equatable {
    public enum Reason: String, Sendable { case exited, signaled }
    public var status: Int32
    public var reason: Reason

    public var succeeded: Bool { reason == .exited && status == 0 }
}

public typealias OutputHandler = @Sendable (OutputLine) -> Void

/// Splits a byte stream into lines, keeping partial lines across reads and bounding line length.
final class LineSplitter: @unchecked Sendable {
    private let stream: OutputStream
    private let maxLineBytes: Int
    private let handler: OutputHandler
    private var buffer = Data()
    private let lock = NSLock()

    init(stream: OutputStream, maxLineBytes: Int, handler: @escaping OutputHandler) {
        self.stream = stream
        self.maxLineBytes = maxLineBytes
        self.handler = handler
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        // An overlong line is split into bounded chunks rather than buffered without limit.
        while buffer.count >= maxLineBytes {
            lines.append(buffer.prefix(maxLineBytes))
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + maxLineBytes)
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func finish() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { emit(rest) }
    }

    private func emit(_ data: Data) {
        var text = String(decoding: data.prefix(maxLineBytes), as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        handler(OutputLine(stream: stream, text: text))
    }
}

/// One running child process started from a `LaunchPlan`.
public final class SupervisedProcess: @unchecked Sendable {
    public let plan: LaunchPlan
    public let identity: ProcessIdentity?

    private let process: Process
    private let lock = NSLock()
    private var exitResult: ProcessExit?
    private var waiters: [CheckedContinuation<ProcessExit, Never>] = []

    init(plan: LaunchPlan, process: Process, identity: ProcessIdentity?) {
        self.plan = plan
        self.process = process
        self.identity = identity
    }

    public var pid: Int32 { process.processIdentifier }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitResult == nil
    }

    func complete(_ exit: ProcessExit) {
        lock.lock()
        guard exitResult == nil else { lock.unlock(); return }
        exitResult = exit
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: exit) }
    }

    public func waitForExit() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitResult {
                lock.unlock()
                continuation.resume(returning: exitResult)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Sends SIGTERM to this process only, then SIGKILL after `grace` if it is still ours and alive.
    /// The PID stays valid until we reap it, and we re-check its start identity before signalling.
    @discardableResult
    public func terminate(grace: Duration = .seconds(5)) async -> ProcessExit {
        if isRunning, ownsPID() {
            process.terminate()
        }
        let deadline = ContinuousClock.now + grace
        while isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isRunning, ownsPID() {
            kill(process.processIdentifier, SIGKILL)
        }
        return await waitForExit()
    }

    private func ownsPID() -> Bool {
        guard let identity else { return process.isRunning }
        return ProcessIdentity.current(pid: identity.pid) == identity
    }
}

/// Starts plans with `Process`, drains stdout and stderr concurrently and reports exit.
public struct ProcessSupervisor: Sendable {
    public var maxLineBytes: Int
    /// Wine helpers such as wineserver can inherit our pipes and keep them open after the
    /// direct child exits, so exit is reported after this grace even without EOF.
    public var drainGrace: Duration

    public init(maxLineBytes: Int = 16 * 1024, drainGrace: Duration = .seconds(2)) {
        self.maxLineBytes = maxLineBytes
        self.drainGrace = drainGrace
    }

    public func start(_ plan: LaunchPlan, onOutput: @escaping OutputHandler) throws -> SupervisedProcess {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        process.environment = plan.environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let group = DispatchGroup()
        for (pipe, stream) in [(stdoutPipe, OutputStream.stdout), (stderrPipe, .stderr)] {
            let splitter = LineSplitter(stream: stream, maxLineBytes: maxLineBytes, handler: onOutput)
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    splitter.finish()
                    group.leave()
                } else {
                    splitter.append(data)
                }
            }
        }

        let holder = SupervisedProcessHolder()
        let grace = drainGrace
        process.terminationHandler = { finished in
            let exit = ProcessExit(
                status: finished.terminationStatus,
                reason: finished.terminationReason == .exit ? .exited : .signaled
            )
            DispatchQueue.global().async {
                let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
                _ = group.wait(timeout: .now() + seconds)
                holder.deliver(exit)
            }
        }

        do {
            try process.run()
        } catch {
            for pipe in [stdoutPipe, stderrPipe] {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            throw LauncherError.processLaunchFailed(detail: "\(plan.executable.lastPathComponent): \(error.localizedDescription)")
        }

        // Close our copies of the write ends so EOF arrives when the child side closes.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let supervised = SupervisedProcess(
            plan: plan,
            process: process,
            identity: ProcessIdentity.current(pid: process.processIdentifier)
        )
        holder.set(supervised)
        return supervised
    }

    /// Starts a long-lived process (Steam, installers) whose output goes straight to `logFile`.
    /// No pipe connects it to the launcher, so quitting the launcher cannot break it with SIGPIPE.
    public func startDetached(_ plan: LaunchPlan, logFile: URL) throws -> SupervisedProcess {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFile.path) {
            fm.createFile(atPath: logFile.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: logFile)
        try output.seekToEnd()

        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        process.environment = plan.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let holder = SupervisedProcessHolder()
        process.terminationHandler = { finished in
            holder.deliver(ProcessExit(
                status: finished.terminationStatus,
                reason: finished.terminationReason == .exit ? .exited : .signaled
            ))
        }
        do {
            try process.run()
        } catch {
            try? output.close()
            throw LauncherError.processLaunchFailed(detail: "\(plan.executable.lastPathComponent): \(error.localizedDescription)")
        }
        try? output.close()

        let supervised = SupervisedProcess(
            plan: plan,
            process: process,
            identity: ProcessIdentity.current(pid: process.processIdentifier)
        )
        holder.set(supervised)
        return supervised
    }

    /// Runs a plan to completion, keeping only the last `keepLines` lines in memory.
    public func run(
        _ plan: LaunchPlan,
        timeout: Duration? = nil,
        keepLines: Int = 200,
        onOutput: @escaping OutputHandler = { _ in }
    ) async throws -> (exit: ProcessExit, tail: [OutputLine]) {
        let tail = BoundedBuffer<OutputLine>(capacity: keepLines)
        let child = try start(plan) { line in
            tail.append(line)
            onOutput(line)
        }
        guard let timeout else {
            return (await child.waitForExit(), tail.snapshot())
        }
        let timedOut = Flag()
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            timedOut.set()
            await child.terminate(grace: .seconds(2))
        }
        let exit = await child.waitForExit()
        watchdog.cancel()
        if timedOut.isSet {
            throw LauncherError.processTimedOut(seconds: Int(timeout.components.seconds))
        }
        return (exit, tail.snapshot())
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

/// Lets the termination handler reach the SupervisedProcess created after `run()`,
/// even when a very short-lived child exits before that object exists.
private final class SupervisedProcessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SupervisedProcess?
    private var pendingExit: ProcessExit?

    func deliver(_ exit: ProcessExit) {
        lock.lock()
        let target = stored
        if target == nil { pendingExit = exit }
        lock.unlock()
        target?.complete(exit)
    }

    func set(_ process: SupervisedProcess) {
        lock.lock()
        stored = process
        let pending = pendingExit
        lock.unlock()
        if let pending { process.complete(pending) }
    }
}

/// Thread-safe ring buffer.
public final class BoundedBuffer<Element: Sendable>: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Element] = []
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()
    }

    public func snapshot() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

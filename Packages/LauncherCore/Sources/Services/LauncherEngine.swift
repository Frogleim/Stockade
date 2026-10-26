import Foundation

/// What is ready and what is not, each problem detected separately.
public struct Readiness: Sendable, Equatable {
    public var runtime: RuntimeDescriptor?
    public var prefix: PrefixDescriptor?
    public var prefixStatus: PrefixStatus?
    public var steamExecutable: URL?
    public var installStatus: GameInstallStatus?
    public var problems: [String]

    public init(
        runtime: RuntimeDescriptor? = nil,
        prefix: PrefixDescriptor? = nil,
        prefixStatus: PrefixStatus? = nil,
        steamExecutable: URL? = nil,
        installStatus: GameInstallStatus? = nil,
        problems: [String] = []
    ) {
        self.runtime = runtime
        self.prefix = prefix
        self.prefixStatus = prefixStatus
        self.steamExecutable = steamExecutable
        self.installStatus = installStatus
        self.problems = problems
    }

    public var canInitializePrefix: Bool {
        runtime != nil && prefix != nil && prefixStatus != .initialized && prefixStatus != .initializing
    }

    public var canInstallSteam: Bool {
        runtime != nil && prefixStatus == .initialized
    }

    public var canOpenSteam: Bool {
        canInstallSteam && steamExecutable != nil
    }

    /// Launching is allowed even when install detection is unsure; Steam has the final say.
    public var canLaunch: Bool {
        canOpenSteam && problems.isEmpty
    }

    public var phase: SessionPhase {
        canLaunch ? .ready : .notConfigured
    }
}

/// The single API shared by the SwiftUI app and the `stockade-cli` development harness.
public actor LauncherEngine {
    public nonisolated let paths: AppPaths
    public let observationWindow: Duration
    public let pollInterval: Duration

    private let store: ConfigurationStore
    private let supervisor: ProcessSupervisor
    private let processSource: any PrefixProcessSource
    private let prefixManager: PrefixManager
    private let steam = SteamService()
    private let logs: LogStore
    private let backups = BackupService()
    private let discovery: RuntimeDiscovery
    private let hostEnvironment: [String: String]
    private let redactor: Redactor

    public private(set) var configuration = LauncherConfiguration()
    /// Set when the configuration on disk must not be overwritten (for example a newer schema).
    public private(set) var readOnlyReason: LauncherError?
    private var monitorTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var steamLaunchers: [SupervisedProcess] = []

    public init(
        paths: AppPaths = .standard(),
        /// Tests pass fake processes here; by default the prefix's wineserver is asked.
        inspector: (any ProcessInspecting)? = nil,
        supervisor: ProcessSupervisor = ProcessSupervisor(),
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        observationWindow: Duration = .seconds(600),
        pollInterval: Duration = .seconds(2),
        redactor: Redactor = Redactor()
    ) {
        self.paths = paths
        self.store = ConfigurationStore(fileURL: paths.configurationFile)
        self.supervisor = supervisor
        let source: any PrefixProcessSource = inspector.map { EnvironmentProcessSource(observer: PrefixObserver(inspector: $0)) }
            ?? WineServerProcessSource(supervisor: supervisor, hostEnvironment: hostEnvironment)
        self.processSource = source
        self.prefixManager = PrefixManager(paths: paths, supervisor: supervisor, processSource: source)
        self.logs = LogStore(directory: paths.logs, maxFiles: 24)
        self.discovery = RuntimeDiscovery(supervisor: supervisor)
        self.hostEnvironment = hostEnvironment
        self.observationWindow = observationWindow
        self.pollInterval = pollInterval
        self.redactor = redactor
    }

    // MARK: Configuration

    @discardableResult
    public func load() throws -> ConfigurationLoadOutcome {
        try paths.createDirectories()
        do {
            let outcome = try store.load()
            configuration = outcome.configuration
            readOnlyReason = nil
            reconcileStaleSessions()
            return outcome
        } catch let error as LauncherError {
            if case .configurationFromFuture = error {
                configuration = LauncherConfiguration()
                readOnlyReason = error
            }
            throw error
        }
    }

    /// Re-reads the configuration from disk. The app and `stockade-cli` may both change it,
    /// so every change starts from the latest saved state instead of a stale copy.
    public func reload() {
        guard readOnlyReason == nil, let outcome = try? store.load() else { return }
        configuration = outcome.configuration
    }

    public func update(_ body: @Sendable (inout LauncherConfiguration) -> Void) throws {
        reload()
        var copy = configuration
        body(&copy)
        configuration = copy
        try persist()
    }

    private func persist() throws {
        if let readOnlyReason { throw readOnlyReason }
        // Keep sessions recorded by another launcher process (for example stockade-cli) as well.
        if let onDisk = try? store.load().configuration {
            for session in onDisk.recentSessions.reversed()
            where !configuration.recentSessions.contains(where: { $0.id == session.id }) {
                configuration.recentSessions.append(session)
            }
            configuration.recentSessions.sort { $0.requestedAt > $1.requestedAt }
            configuration.recentSessions = Array(configuration.recentSessions.prefix(LauncherConfiguration.maxRecentSessions))
        }
        try store.save(configuration)
    }

    /// Sessions recorded as active by a previous launcher run can no longer be observed by
    /// this process, so they are marked unknown instead of pretending they are still running.
    private func reconcileStaleSessions() {
        for index in configuration.recentSessions.indices where configuration.recentSessions[index].phase.isActive {
            configuration.recentSessions[index].phase = .statusUnknown
        }
    }

    // MARK: Setup

    public func selectRuntime(wineExecutable: URL, displayName: String? = nil) async throws -> RuntimeValidationReport {
        var report = try await discovery.validate(
            wineExecutable: wineExecutable,
            displayName: displayName,
            hostEnvironment: hostEnvironment
        )
        // Re-selecting the same binary keeps its identity so existing prefix markers still match.
        if let existing = configuration.runtimes.first(where: {
            $0.wineExecutable == report.descriptor.wineExecutable && $0.executableSHA256 == report.descriptor.executableSHA256
        }) {
            report.descriptor.id = existing.id
        }
        let descriptor = report.descriptor
        try update { config in
            config.runtimes.removeAll { $0.id == descriptor.id }
            config.runtimes.append(descriptor)
            config.activeRuntimeID = descriptor.id
        }
        return report
    }

    /// Returns the active runtime's prefix, creating one (with its game profile) if needed.
    /// A prefix belongs to one runtime: selecting another runtime gets a separate prefix,
    /// because one prefix must never be shared between Wine versions.
    public func createPrefix(named name: String? = nil) throws -> PrefixDescriptor {
        guard let runtime = configuration.activeRuntime else { throw LauncherError.notConfigured("A runtime") }
        if name == nil, let existing = configuration.activePrefix, existing.runtimeID == runtime.id {
            return existing
        }
        if name == nil, let owned = configuration.prefixes.first(where: { $0.runtimeID == runtime.id }) {
            try selectPrefix(owned.id)
            return owned
        }
        let url = try prefixManager.createPrefixDirectory(named: name ?? "Farthest Frontier Prefix")
        let prefix = PrefixDescriptor(url: url, runtimeID: runtime.id)
        let template = configuration.activeProfile
        try update { config in
            config.prefixes.append(prefix)
            config.activePrefixID = prefix.id
            var profile = GameProfile(prefixID: prefix.id)
            if let template {
                profile.launchArguments = template.launchArguments
                profile.processMatchHints = template.processMatchHints
            }
            config.profiles.append(profile)
            config.activeProfileID = profile.id
            config.steamExecutableOverride = nil
        }
        return prefix
    }

    /// Makes a prefix active together with the runtime that owns it and its game profile.
    public func selectPrefix(_ id: UUID) throws {
        guard let prefix = configuration.prefixes.first(where: { $0.id == id }) else {
            throw LauncherError.notConfigured("That prefix")
        }
        guard monitorTask == nil else { throw LauncherError.gameRunning }
        try update { config in
            config.activePrefixID = prefix.id
            if config.runtimes.contains(where: { $0.id == prefix.runtimeID }) {
                config.activeRuntimeID = prefix.runtimeID
            }
            config.activeProfileID = config.profiles.first { $0.prefixID == prefix.id }?.id
            config.steamExecutableOverride = nil
        }
    }

    /// Hands a prefix to the active runtime when both are the same Wine version.
    public func adoptPrefix(_ id: UUID) throws {
        guard let runtime = configuration.activeRuntime else { throw LauncherError.notConfigured("A runtime") }
        guard let prefix = configuration.prefixes.first(where: { $0.id == id }) else { throw LauncherError.notConfigured("That prefix") }
        guard monitorTask == nil else { throw LauncherError.gameRunning }
        try prefixManager.adopt(prefix: prefix.url, by: runtime)
        try update { config in
            guard let index = config.prefixes.firstIndex(where: { $0.id == id }) else { return }
            config.prefixes[index].runtimeID = runtime.id
            config.activePrefixID = id
            config.activeProfileID = config.profiles.first { $0.prefixID == id }?.id
        }
    }

    /// Copies an installed game from another launcher prefix into the active one, so Steam
    /// does not download it again. On APFS the copy is a clone and uses no extra space.
    /// Steam in the active prefix must be installed and closed.
    @discardableResult
    public func importGame(from sourceID: UUID) throws -> URL {
        let (_, target) = try requireInitializedPrefix()
        guard let source = configuration.prefixes.first(where: { $0.id == sourceID }), source.id != target.id else {
            throw LauncherError.notConfigured("A different source prefix")
        }
        guard !prefixManager.isActive(target.url) else { throw LauncherError.prefixActive(path: target.url.path) }
        let appID = configuration.activeProfile?.steamAppID ?? GameProfile.farthestFrontierAppID
        let sourceSteam = try steam.locateSteam(prefix: source.url)
        guard case .installed(let gameDirectory, _) = steam.installStatus(appID: appID, steamExecutable: sourceSteam, prefix: source.url) else {
            throw LauncherError.notConfigured("An installed game in the source prefix")
        }
        let targetSteam = try steam.locateSteam(prefix: target.url, override: configuration.steamExecutableOverride)
        let steamapps = targetSteam.deletingLastPathComponent().appendingPathComponent("steamapps", isDirectory: true)
        let common = steamapps.appendingPathComponent("common", isDirectory: true)
        let destination = common.appendingPathComponent(gameDirectory.lastPathComponent, isDirectory: true)
        let manifestName = "appmanifest_\(appID).acf"
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return destination }
        try fm.createDirectory(at: common, withIntermediateDirectories: true)
        try fm.copyItem(at: gameDirectory, to: destination)
        let sourceManifest = gameDirectory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(manifestName)
        let targetManifest = steamapps.appendingPathComponent(manifestName)
        if fm.fileExists(atPath: targetManifest.path) { try fm.removeItem(at: targetManifest) }
        try fm.copyItem(at: sourceManifest, to: targetManifest)
        return destination
    }

    public func initializePrefix(onOutput: @escaping OutputHandler = { _ in }) async throws {
        let (runtime, prefix) = try requireRuntimeAndPrefix()
        let log = try logs.makeLog(named: "prefix-init")
        log.append("initializing \(redactor.redact(prefix.url.path)) with \(runtime.versionOutput)")
        do {
            try await prefixManager.initialize(
                prefix: prefix.url,
                runtime: runtime,
                verboseLogging: configuration.verboseWineLogging
            ) { line in
                log.append(line)
                onOutput(line)
            }
            log.append("initialization completed")
        } catch {
            log.append("initialization failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func runSteamInstaller(_ installer: URL) async throws -> ProcessExit {
        try steam.validateInstaller(installer)
        let (runtime, prefix) = try requireInitializedPrefix()
        let lock = try PrefixLock.acquire(prefix: prefix.url, locksDirectory: paths.locksDirectory)
        defer { lock.release() }
        try update { $0.steamInstaller = installer }

        let plan = try adapter(runtime).plan(.runInstaller(installer), context: context(runtime, prefix))
        let log = try logs.makeLog(named: "steam-installer")
        log.append("running installer \(redactor.redact(installer.lastPathComponent))")
        let child = try supervisor.startDetached(plan, logFile: wineLogURL(for: log))
        // No timeout: the person may take as long as they need in the installer.
        let exit = await child.waitForExit()
        log.append("installer exited with status \(exit.status)")
        return exit
    }

    public func openSteam() throws {
        let (runtime, prefix) = try requireInitializedPrefix()
        let steamExe = try steam.locateSteam(prefix: prefix.url, override: configuration.steamExecutableOverride)
        let plan = try adapter(runtime).plan(.openSteam(steamExecutable: steamExe), context: context(runtime, prefix))
        let log = try logs.makeLog(named: "steam")
        try prepareSteam(steamExe, log: log)
        log.append("opening Steam")
        let child = try supervisor.startDetached(plan, logFile: wineLogURL(for: log))
        steamLaunchers.append(child)
        steamLaunchers.removeAll { !$0.isRunning && $0 !== child }
    }

    // MARK: Status

    public func readiness() -> Readiness {
        var result = Readiness(problems: [])
        guard let runtime = configuration.activeRuntime else {
            result.problems.append("No Wine runtime is selected.")
            return result
        }
        result.runtime = runtime
        let fm = FileManager.default
        if PathSafety.isOnUnmountedVolume(runtime.wineExecutable) {
            result.problems.append("The runtime's volume is not mounted: \(runtime.wineExecutable.path)")
        } else if !fm.isExecutableFile(atPath: runtime.wineExecutable.path) {
            result.problems.append("The selected runtime is missing: \(runtime.wineExecutable.path)")
        }
        if let profile = configuration.activeProfile,
           !adapter(runtime).supportedBackends.contains(profile.backend) {
            result.problems.append("The \(profile.backend.displayName) backend is not supported by this runtime.")
        }
        guard let prefix = configuration.activePrefix else {
            result.problems.append("No prefix has been created.")
            return result
        }
        result.prefix = prefix
        let status = prefixManager.status(of: prefix.url)
        result.prefixStatus = status
        switch status {
        case .missing:
            result.problems.append(PathSafety.isOnUnmountedVolume(prefix.url)
                ? "The prefix's volume is not mounted."
                : "The prefix folder no longer exists.")
            return result
        case .uninitialized:
            result.problems.append("The prefix has not been initialized.")
            return result
        case .initializing:
            result.problems.append("The prefix is being initialized.")
            return result
        case .interrupted:
            result.problems.append("Prefix initialization was interrupted. Reset the prefix and initialize again.")
            return result
        case .initialized:
            break
        }
        if let marker = prefixManager.marker(of: prefix.url), marker.runtimeID != runtime.id {
            result.problems.append("The prefix was created by \(marker.runtimeVersion), not the selected runtime. Do not mix runtimes in one prefix.")
        }
        do {
            let steamExe = try steam.locateSteam(prefix: prefix.url, override: configuration.steamExecutableOverride)
            result.steamExecutable = steamExe
            let appID = configuration.activeProfile?.steamAppID ?? GameProfile.farthestFrontierAppID
            result.installStatus = steam.installStatus(appID: appID, steamExecutable: steamExe, prefix: prefix.url)
        } catch {
            result.problems.append(error.localizedDescription)
        }
        return result
    }

    public func prefixSnapshot() async -> PrefixSnapshot? {
        guard let prefix = configuration.activePrefix, let runtime = configuration.activeRuntime else { return nil }
        return await processSource.snapshot(prefix: prefix.url, runtime: runtime, gameHints: configuration.activeProfile?.processMatchHints ?? [])
    }

    public func launchPlan() throws -> LaunchPlan {
        let (runtime, prefix) = try requireInitializedPrefix()
        guard let profile = configuration.activeProfile else { throw LauncherError.notConfigured("A game profile") }
        let steamExe = try steam.locateSteam(prefix: prefix.url, override: configuration.steamExecutableOverride)
        return try adapter(runtime).plan(
            .launchGame(steamExecutable: steamExe, appID: profile.steamAppID, arguments: profile.launchArguments),
            context: context(runtime, prefix, backend: profile.backend)
        )
    }

    // MARK: Launch

    public var hasActiveSession: Bool { monitorTask != nil }

    /// Requests the game launch and returns immediately. Observation continues in the
    /// background and every phase change is reported through `onUpdate`.
    public func launchGame(onUpdate: @escaping @Sendable (LaunchSession) -> Void = { _ in }) throws -> LaunchSession {
        guard monitorTask == nil else { throw LauncherError.prefixBusy(path: configuration.activePrefix?.url.path ?? "") }
        let ready = readiness()
        guard ready.canLaunch, let prefix = ready.prefix, let runtime = ready.runtime, let profile = configuration.activeProfile else {
            throw LauncherError.notConfigured(ready.problems.first ?? "Setup")
        }
        let plan = try launchPlan()
        let lock = try PrefixLock.acquire(prefix: prefix.url, locksDirectory: paths.locksDirectory)

        let log = try logs.makeLog(named: "launch")
        var session = LaunchSession(versions: HostInfo.versions(runtime: ready.runtime), logFileName: log.url.lastPathComponent)
        log.append("launch requested for \(profile.name) (app \(profile.steamAppID))")
        log.append(plan.sanitizedDescription(redactor: redactor))

        let child: SupervisedProcess
        do {
            if let steamExe = ready.steamExecutable { try prepareSteam(steamExe, log: log) }
            child = try supervisor.startDetached(plan, logFile: wineLogURL(for: log))
        } catch {
            lock.release()
            SessionStateMachine.apply(.launchFailed(error.localizedDescription), to: &session)
            configuration.record(session)
            try? persist()
            throw error
        }
        SessionStateMachine.apply(.launchRequested, to: &session)
        configuration.record(session)
        try? persist()
        onUpdate(session)

        activeSessionID = session.id
        let hints = profile.processMatchHints
        monitorTask = Task {
            await self.monitor(session: session, child: child, lock: lock, log: log, prefix: prefix, runtime: runtime, hints: hints, onUpdate: onUpdate)
        }
        return session
    }

    /// Stops observing. The game and Steam keep running.
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func monitor(
        session initial: LaunchSession,
        child: SupervisedProcess,
        lock: PrefixLock,
        log: SessionLog,
        prefix: PrefixDescriptor,
        runtime: RuntimeDescriptor,
        hints: [String],
        onUpdate: @Sendable (LaunchSession) -> Void
    ) async {
        var session = initial
        let started = ContinuousClock.now
        var reportedExit = false
        defer {
            lock.release()
            monitorTask = nil
            activeSessionID = nil
        }

        while !Task.isCancelled {
            let before = session
            if !reportedExit, !child.isRunning {
                let exit = await child.waitForExit()
                reportedExit = true
                log.append("steam request process exited with status \(exit.status)")
                SessionStateMachine.apply(.steamRequestExited(exit), to: &session)
                // Steam has the request; maintenance checks the live process list from here on.
                lock.release()
            }
            if !SessionStateMachine.isTerminal(session.phase) {
                let snapshot = await processSource.snapshot(prefix: prefix.url, runtime: runtime, gameHints: hints)
                SessionStateMachine.apply(.snapshot(snapshot), to: &session)
            }
            if ContinuousClock.now - started > observationWindow {
                SessionStateMachine.apply(.observationWindowElapsed, to: &session)
            }
            if session.phase == .statusUnknown {
                lock.release()
            }

            if session != before {
                if session.phase != before.phase {
                    log.append("phase: \(session.phase.rawValue)")
                }
                if session.phase == .runningObserved, before.phase != .runningObserved {
                    // Maintenance checks the live process list, so the lock is no longer needed.
                    lock.release()
                    if let index = configuration.prefixes.firstIndex(where: { $0.id == prefix.id }) {
                        configuration.prefixes[index].lastSuccessfulLaunch = Date()
                    }
                }
                configuration.record(session)
                try? persist()
                onUpdate(session)
            }
            if SessionStateMachine.isTerminal(session.phase) { break }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Stops every program in the launcher's prefix with `wineserver -k`. Never touches other prefixes.
    public func shutdownPrefix() async throws -> ProcessExit {
        let (runtime, prefix) = try requireRuntimeAndPrefix()
        let plan = try adapter(runtime).plan(.shutdownPrefix, context: context(runtime, prefix))
        let log = try logs.makeLog(named: "shutdown")
        log.append("wineserver -k for \(redactor.redact(prefix.url.path))")
        let result = try await supervisor.run(plan, timeout: .seconds(60)) { log.append($0) }
        return result.exit
    }

    /// Deletes the prefix after an exact-path confirmation. Saves inside it are lost unless backed up.
    public func resetPrefix(confirmation: String) throws {
        guard let prefix = configuration.activePrefix else { throw LauncherError.notConfigured("A prefix") }
        guard monitorTask == nil else { throw LauncherError.gameRunning }
        try prefixManager.delete(prefix: prefix.url, confirmation: confirmation)
        try update { config in
            config.prefixes.removeAll { $0.id == prefix.id }
            config.profiles.removeAll { $0.prefixID == prefix.id }
            config.activePrefixID = nil
            config.activeProfileID = nil
            config.steamExecutableOverride = nil
        }
    }

    // MARK: Diagnostics

    public func diagnosticsReport(logLines: Int = 200) -> String {
        let ready = readiness()
        let last = configuration.recentSessions.first
        var tail: [String] = []
        if let name = last?.logFileName {
            let eventLog = paths.logs.appendingPathComponent(name)
            tail += logs.tail(of: eventLog, maxLines: logLines / 2)
            tail += logs.tail(of: wineLogURL(forEventLog: eventLog), maxLines: logLines / 2)
        } else if let newest = logs.logFiles().first {
            tail = logs.tail(of: newest, maxLines: logLines)
        }
        let input = DiagnosticsInput(
            configuration: configuration,
            versions: HostInfo.versions(runtime: configuration.activeRuntime),
            prefixStatus: ready.prefixStatus,
            installStatus: ready.installStatus,
            launchPlan: try? launchPlan(),
            lastSession: last,
            logTail: tail,
            problems: ready.problems
        )
        return DiagnosticsReportBuilder(redactor: redactor).build(input)
    }

    public func exportDiagnostics(to url: URL) throws {
        try Data(diagnosticsReport().utf8).write(to: url, options: .atomic)
    }

    public func logFiles() -> [URL] {
        logs.logFiles()
    }

    // MARK: Saves

    public func backupSaves() throws -> BackupRecord {
        guard let saves = configuration.activeProfile?.saveDirectory else {
            throw LauncherError.notConfigured("A verified save directory")
        }
        try requireGameClosed()
        let build: String?
        if case .installed(_, let id) = readiness().installStatus { build = id } else { build = nil }
        return try backups.createBackup(of: saves, into: paths.backupsRoot, gameVersion: build)
    }

    public func listBackups() -> [BackupRecord] {
        backups.listBackups(in: paths.backupsRoot)
    }

    @discardableResult
    public func restore(_ record: BackupRecord, confirmation: String) throws -> URL? {
        guard let saves = configuration.activeProfile?.saveDirectory else {
            throw LauncherError.notConfigured("A verified save directory")
        }
        try requireGameClosed()
        return try backups.restore(record, to: saves, confirmation: confirmation)
    }

    private func requireGameClosed() throws {
        if monitorTask != nil { throw LauncherError.gameRunning }
        if let prefix = configuration.activePrefix, prefixManager.isActive(prefix.url) {
            throw LauncherError.gameRunning
        }
    }

    // MARK: Helpers

    /// Re-applies the web helper shim when configured, because Steam updates replace it.
    private func prepareSteam(_ steamExe: URL, log: SessionLog) throws {
        guard let shim = configuration.steamWebHelperShim else { return }
        let changed = try WebHelperShim().install(shim, steamExecutable: steamExe)
        for directory in changed {
            log.append("installed steamwebhelper shim in \(redactor.redact(directory.lastPathComponent))")
        }
    }

    /// Installs the shim now and remembers it for future Steam starts. Pass nil to remove it.
    public func setWebHelperShim(_ shim: URL?) throws {
        let (_, prefix) = try requireInitializedPrefix()
        let steamExe = try steam.locateSteam(prefix: prefix.url, override: configuration.steamExecutableOverride)
        if let shim {
            try WebHelperShim().install(shim, steamExecutable: steamExe)
        } else {
            try WebHelperShim().uninstall(steamExecutable: steamExe)
        }
        try update { $0.steamWebHelperShim = shim }
    }

    private func adapter(_ runtime: RuntimeDescriptor) -> any RuntimeAdapter {
        RuntimeAdapters.adapter(for: runtime.adapter)
    }

    private func context(_ runtime: RuntimeDescriptor, _ prefix: PrefixDescriptor, backend: GraphicsBackend = .runtimeDefault) -> LaunchContext {
        LaunchContext(
            runtime: runtime,
            prefix: prefix.url,
            backend: backend,
            verboseLogging: configuration.verboseWineLogging,
            steamClientArguments: configuration.steamClientArguments ?? [],
            hostEnvironment: hostEnvironment
        )
    }

    private func requireRuntimeAndPrefix() throws -> (RuntimeDescriptor, PrefixDescriptor) {
        guard let runtime = configuration.activeRuntime else { throw LauncherError.notConfigured("A runtime") }
        guard let prefix = configuration.activePrefix else { throw LauncherError.notConfigured("A prefix") }
        return (runtime, prefix)
    }

    private func requireInitializedPrefix() throws -> (RuntimeDescriptor, PrefixDescriptor) {
        let (runtime, prefix) = try requireRuntimeAndPrefix()
        switch prefixManager.status(of: prefix.url) {
        case .initialized: break
        case .interrupted: throw LauncherError.prefixInterrupted(path: prefix.url.path)
        case .missing:
            if PathSafety.isOnUnmountedVolume(prefix.url) { throw LauncherError.volumeUnavailable(path: prefix.url.path) }
            throw LauncherError.prefixNotInitialized(path: prefix.url.path)
        default: throw LauncherError.prefixNotInitialized(path: prefix.url.path)
        }
        if let marker = prefixManager.marker(of: prefix.url), marker.runtimeID != runtime.id {
            throw LauncherError.runtimeMismatch(prefixRuntime: marker.runtimeVersion, selectedRuntime: runtime.versionOutput)
        }
        return (runtime, prefix)
    }

    private func wineLogURL(for log: SessionLog) -> URL {
        wineLogURL(forEventLog: log.url)
    }

    private func wineLogURL(forEventLog url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("wine.log")
    }
}

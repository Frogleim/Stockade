import AppKit
import Foundation
import LauncherCore
import Observation

struct PresentedError: Identifiable {
    let id = UUID()
    let message: String
    let suggestion: String?

    init(_ error: Error) {
        if let error = error as? LauncherError {
            message = error.errorDescription ?? "\(error)"
            suggestion = error.recoverySuggestion
        } else {
            message = error.localizedDescription
            suggestion = nil
        }
    }
}

/// UI state over LauncherEngine. All engine work runs off the main actor; results land here.
@MainActor
@Observable
final class AppModel {
    static let maxOutputLines = 500

    let engine: LauncherEngine
    private(set) var configuration = LauncherConfiguration()
    private(set) var readiness = Readiness(problems: [])
    private(set) var session: LaunchSession?
    private(set) var backups: [BackupRecord] = []
    private(set) var output: [String] = []
    private(set) var runtimeWarnings: [String] = []
    private(set) var busy: String?
    private(set) var readOnlyMessage: String?
    private(set) var notice: String?
    var error: PresentedError?

    init(engine: LauncherEngine = LauncherEngine()) {
        self.engine = engine
    }

    var isBusy: Bool { busy != nil }
    var sessionActive: Bool { session?.phase.isActive == true && sessionIsLive }
    private(set) var sessionIsLive = false

    var displayPhase: SessionPhase {
        if let session, sessionIsLive || SessionStateMachine.isTerminal(session.phase) || session.phase == .statusUnknown {
            return session.phase
        }
        return readiness.phase
    }

    func start() async {
        do {
            switch try await engine.load() {
            case .recovered(_, let damaged):
                notice = "The configuration file was damaged and was restored from the last good copy. The damaged file was kept at \(damaged.lastPathComponent)."
            default:
                break
            }
        } catch {
            if case .configurationFromFuture = error as? LauncherError {
                readOnlyMessage = PresentedError(error).message + " Changes will not be saved."
            }
            self.error = PresentedError(error)
        }
        await refresh()
    }

    func refresh() async {
        await engine.reload()
        configuration = await engine.configuration
        readiness = await engine.readiness()
        sessionIsLive = await engine.hasActiveSession
        session = configuration.recentSessions.first
        backups = await engine.listBackups()
    }

    private func perform(_ label: String, _ operation: @escaping () async throws -> Void) async {
        guard busy == nil else { return }
        busy = label
        defer { busy = nil }
        do {
            try await operation()
        } catch {
            self.error = PresentedError(error)
        }
        await refresh()
    }

    private var outputHandler: OutputHandler {
        { [weak self] line in
            Task { @MainActor in self?.appendOutput("[\(line.stream.rawValue)] \(line.text)") }
        }
    }

    func appendOutput(_ line: String) {
        output.append(line)
        if output.count > Self.maxOutputLines {
            output.removeFirst(output.count - Self.maxOutputLines)
        }
    }

    // MARK: Setup

    func selectRuntime(_ url: URL) async {
        await perform("Validating runtime…") {
            let report = try await self.engine.selectRuntime(wineExecutable: url)
            self.runtimeWarnings = report.warnings
            self.appendOutput("validated runtime \(report.descriptor.versionOutput)")
        }
    }

    func createAndInitializePrefix() async {
        await perform("Initializing prefix… this can take a few minutes") {
            _ = try await self.engine.createPrefix()
            try await self.engine.initializePrefix(onOutput: self.outputHandler)
        }
    }

    func runSteamInstaller(_ url: URL) async {
        await perform("Steam installer is running — finish it in its window") {
            let exit = try await self.engine.runSteamInstaller(url)
            self.appendOutput("Steam installer exited with status \(exit.status)")
            if !exit.succeeded {
                self.notice = "The Steam installer exited with status \(exit.status). If you cancelled it, run it again."
            }
        }
    }

    func openSteam() async {
        await perform("Opening Steam…") {
            try await self.engine.openSteam()
        }
    }

    // MARK: Game

    func launch() async {
        await perform("Requesting launch…") {
            let first = try await self.engine.launchGame { [weak self] session in
                Task { @MainActor in
                    guard let self else { return }
                    self.session = session
                    self.appendOutput("phase: \(session.phase.headline)")
                    self.sessionIsLive = await self.engine.hasActiveSession
                    if SessionStateMachine.isTerminal(session.phase) {
                        await self.refresh()
                    }
                }
            }
            self.session = first
            self.sessionIsLive = true
        }
    }

    func stopObserving() async {
        await engine.stopMonitoring()
        await refresh()
    }

    func shutdownPrefix() async {
        await perform("Shutting down the prefix…") {
            let exit = try await self.engine.shutdownPrefix()
            self.appendOutput("wineserver -k exited with status \(exit.status)")
        }
    }

    func resetPrefix(confirmation: String) async {
        await perform("Deleting prefix…") {
            try await self.engine.resetPrefix(confirmation: confirmation)
            self.notice = "The prefix was deleted. Create a new one in Setup."
        }
    }

    // MARK: Settings

    func setLaunchArguments(_ text: String) async {
        let arguments = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        await updateProfile { $0.launchArguments = arguments }
    }

    func setProcessHints(_ text: String) async {
        let hints = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        await updateProfile { $0.processMatchHints = hints }
    }

    func setSteamClientArguments(_ text: String) async {
        let arguments = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        await perform("Saving…") {
            try await self.engine.update { $0.steamClientArguments = arguments.isEmpty ? nil : arguments }
        }
    }

    func setSaveDirectory(_ url: URL?) async {
        await updateProfile { $0.saveDirectory = url }
    }

    func setVerboseLogging(_ enabled: Bool) async {
        await perform("Saving…") {
            try await self.engine.update { $0.verboseWineLogging = enabled }
        }
    }

    func setSteamOverride(_ url: URL?) async {
        await perform("Saving…") {
            try await self.engine.update { $0.steamExecutableOverride = url }
        }
    }

    private func updateProfile(_ change: @escaping @Sendable (inout GameProfile) -> Void) async {
        await perform("Saving…") {
            try await self.engine.update { config in
                guard let id = config.activeProfileID,
                      let index = config.profiles.firstIndex(where: { $0.id == id }) else { return }
                change(&config.profiles[index])
            }
        }
    }

    // MARK: Diagnostics and saves

    func diagnosticsReport() async -> String {
        await engine.diagnosticsReport()
    }

    func exportDiagnostics(to url: URL) async {
        await perform("Exporting diagnostics…") {
            try await self.engine.exportDiagnostics(to: url)
            self.notice = "Diagnostics written to \(url.lastPathComponent)."
        }
    }

    func backupNow() async {
        await perform("Backing up saves…") {
            let record = try await self.engine.backupSaves()
            self.notice = "Backed up and verified \(record.manifest.files.count) file(s)."
        }
    }

    func restore(_ record: BackupRecord) async {
        guard let saves = configuration.activeProfile?.saveDirectory else { return }
        await perform("Restoring saves…") {
            let preserved = try await self.engine.restore(record, confirmation: saves.path)
            self.notice = "Restored. Your previous saves were kept at “\(preserved?.lastPathComponent ?? "—")”."
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

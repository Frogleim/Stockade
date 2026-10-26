import Foundation

/// Every failure the launcher reports to a person. Each case carries enough context
/// to produce an actionable message without exposing credentials.
public enum LauncherError: Error, Equatable, Sendable, LocalizedError {
    case runtimeNotFound(path: String)
    case runtimeNotExecutable(path: String)
    case runtimeCompanionMissing(name: String, searched: [String])
    case runtimeVersionFailed(detail: String)
    case runtimeMismatch(prefixRuntime: String, selectedRuntime: String)
    case volumeUnavailable(path: String)
    case unsafePath(path: String, reason: String)
    case prefixBusy(path: String)
    case prefixNotInitialized(path: String)
    case prefixInterrupted(path: String)
    case prefixActive(path: String)
    case steamNotFound(searched: [String])
    case steamOverrideInvalid(path: String, reason: String)
    case steamInstallerInvalid(path: String)
    case webHelperOriginalMissing(directory: String)
    case configurationFromFuture(found: Int, supported: Int)
    case configurationCorrupt(detail: String)
    case processLaunchFailed(detail: String)
    case processTimedOut(seconds: Int)
    case backupVerificationFailed(file: String)
    case restoreFailed(detail: String)
    case confirmationMismatch
    case gameRunning
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotFound(let path):
            return "No Wine executable exists at \(path)."
        case .runtimeNotExecutable(let path):
            return "\(path) exists but is not an executable file."
        case .runtimeCompanionMissing(let name, _):
            return "The runtime is missing its companion tool “\(name)”."
        case .runtimeVersionFailed(let detail):
            return "The runtime did not report a version: \(detail)"
        case .runtimeMismatch(let prefixRuntime, let selectedRuntime):
            return "This prefix was initialized by \(prefixRuntime), but \(selectedRuntime) is selected."
        case .volumeUnavailable(let path):
            return "The volume holding \(path) is not mounted."
        case .unsafePath(let path, let reason):
            return "Refusing to use \(path): \(reason)"
        case .prefixBusy:
            return "Another setup, maintenance or launch operation is already using this prefix."
        case .prefixNotInitialized:
            return "The Wine prefix has not been initialized yet."
        case .prefixInterrupted:
            return "Wine prefix initialization was interrupted and did not complete."
        case .prefixActive:
            return "Windows programs are still running in this prefix."
        case .steamNotFound:
            return "Windows Steam was not found inside the prefix."
        case .steamOverrideInvalid(let path, let reason):
            return "The Steam location \(path) cannot be used: \(reason)"
        case .steamInstallerInvalid(let path):
            return "\(path) does not look like a Windows installer (.exe)."
        case .webHelperOriginalMissing(let directory):
            return "Steam's original steamwebhelper.exe is missing in \(directory)."
        case .configurationFromFuture(let found, let supported):
            return "The saved configuration uses schema \(found); this version of the launcher supports up to \(supported)."
        case .configurationCorrupt(let detail):
            return "The saved configuration could not be read: \(detail)"
        case .processLaunchFailed(let detail):
            return "The process could not be started: \(detail)"
        case .processTimedOut(let seconds):
            return "The process did not finish within \(seconds) seconds."
        case .backupVerificationFailed(let file):
            return "Backup verification failed for \(file)."
        case .restoreFailed(let detail):
            return "Restore failed: \(detail)"
        case .confirmationMismatch:
            return "The confirmation did not match the affected path."
        case .gameRunning:
            return "The game or another program in its prefix is running."
        case .notConfigured(let what):
            return "\(what) is not configured yet."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .runtimeNotFound, .runtimeNotExecutable:
            return "Choose the `wine` (or `wine64`) binary inside your runtime's bin folder."
        case .runtimeCompanionMissing(_, let searched):
            return "Looked in: \(searched.joined(separator: ", ")). Select a complete runtime installation."
        case .runtimeVersionFailed:
            return "Make sure the runtime runs on this Mac. x86-64 runtimes need Rosetta 2 installed."
        case .runtimeMismatch:
            return "Select the runtime that created the prefix, or create a separate prefix for the new runtime. Never share an active prefix between Wine versions."
        case .volumeUnavailable:
            return "Connect or mount the drive, then try again."
        case .unsafePath:
            return "Pick a location inside the launcher's own Application Support folder."
        case .prefixBusy:
            return "Wait for the current operation to finish."
        case .prefixNotInitialized:
            return "Open Setup and initialize the prefix."
        case .prefixInterrupted:
            return "Reset the prefix from Settings and initialize it again."
        case .prefixActive, .gameRunning:
            return "Quit the game and Steam first, or use “Shut down prefix” to stop every program in this prefix."
        case .steamNotFound:
            return "Run the Windows Steam installer from Setup, or set a Steam location in Settings."
        case .steamOverrideInvalid:
            return "Choose a steam.exe that lives inside the launcher's prefix."
        case .steamInstallerInvalid:
            return "Download SteamSetup.exe from the official Steam website."
        case .webHelperOriginalMissing:
            return "Run the Steam installer again from Setup to restore Steam's files, then start Steam."
        case .configurationFromFuture:
            return "Update the launcher. The existing configuration was left untouched."
        case .configurationCorrupt:
            return "The damaged file was kept for inspection; the launcher started with defaults."
        case .processLaunchFailed, .processTimedOut:
            return "Open Diagnostics to see the process output."
        case .backupVerificationFailed:
            return "The backup may be damaged. Create a new backup while the game is closed."
        case .restoreFailed:
            return "Your current saves were left in place."
        case .confirmationMismatch:
            return "Type the exact path shown to confirm."
        case .notConfigured:
            return "Finish Setup first."
        }
    }
}

import Foundation

public enum GameInstallStatus: Sendable, Equatable {
    case installed(directory: URL, buildID: String?)
    case needsUpdate(directory: URL, stateFlags: Int)
    case incomplete(stateFlags: Int)
    case notInstalled
    case unknown(String)

    public var summary: String {
        switch self {
        case .installed(_, let build): return "Installed" + (build.map { " (build \($0))" } ?? "")
        case .needsUpdate: return "Installed — Steam reports an update is pending"
        case .incomplete: return "Download or installation in progress in Steam"
        case .notInstalled: return "Not installed — install it from Steam"
        case .unknown(let reason): return "Unknown: \(reason)"
        }
    }
}

/// Converts Windows paths from Steam metadata into paths inside a prefix.
public enum WindowsPath {
    public static func toPOSIX(_ windowsPath: String, prefix: URL) -> URL? {
        let normalized = windowsPath.replacingOccurrences(of: "\\", with: "/")
        let scalars = Array(normalized)
        guard scalars.count >= 2, scalars[1] == ":", scalars[0].isLetter else { return nil }
        let drive = scalars[0].lowercased()
        let rest = String(scalars.dropFirst(2)).split(separator: "/").map(String.init)
        if rest.contains("..") { return nil }
        var base: URL
        if drive == "c" {
            base = prefix.appendingPathComponent("drive_c", isDirectory: true)
        } else {
            base = prefix.appendingPathComponent("dosdevices/\(drive):", isDirectory: true)
            base = PathSafety.canonical(base)
        }
        for component in rest {
            base.appendPathComponent(component)
        }
        return base
    }
}

/// Finds Windows Steam inside the prefix and reads its metadata conservatively.
/// Downloads and updates stay Steam's job.
public struct SteamService: Sendable {
    public static let candidatePaths = [
        "drive_c/Program Files (x86)/Steam/steam.exe",
        "drive_c/Program Files/Steam/steam.exe",
    ]

    public init() {}

    public func locateSteam(prefix: URL, override: URL? = nil) throws -> URL {
        let fm = FileManager.default
        if let override {
            guard override.lastPathComponent.caseInsensitiveCompare("steam.exe") == .orderedSame else {
                throw LauncherError.steamOverrideInvalid(path: override.path, reason: "the file is not steam.exe.")
            }
            guard PathSafety.isContained(override, in: prefix) else {
                throw LauncherError.steamOverrideInvalid(path: override.path, reason: "it is outside the launcher's prefix.")
            }
            guard fm.fileExists(atPath: override.path) else {
                throw LauncherError.steamOverrideInvalid(path: override.path, reason: "the file does not exist.")
            }
            return override
        }
        let candidates = Self.candidatePaths.map { prefix.appendingPathComponent($0) }
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            return found
        }
        throw LauncherError.steamNotFound(searched: candidates.map(\.path))
    }

    public func validateInstaller(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "exe",
              FileManager.default.fileExists(atPath: url.path) else {
            throw LauncherError.steamInstallerInvalid(path: url.path)
        }
    }

    /// Library folders listed in libraryfolders.vdf, always including Steam's own folder.
    public func libraryFolders(steamExecutable: URL, prefix: URL) -> [URL] {
        let steamRoot = steamExecutable.deletingLastPathComponent()
        var folders = [steamRoot]
        let vdfURL = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: vdfURL, encoding: .utf8),
              let root = try? VDFNode.parse(text),
              let libraries = root["libraryfolders"] else {
            return folders
        }
        for (_, entry) in libraries.children {
            // Older files map "1" → "D:\\Games"; newer ones nest a "path" key.
            let raw = entry["path"]?.stringValue ?? entry.stringValue
            guard let raw, let url = WindowsPath.toPOSIX(raw, prefix: prefix) else { continue }
            if !folders.contains(where: { PathSafety.canonical($0) == PathSafety.canonical(url) }) {
                folders.append(url)
            }
        }
        return folders
    }

    public func installStatus(appID: Int, steamExecutable: URL, prefix: URL) -> GameInstallStatus {
        let fm = FileManager.default
        for library in libraryFolders(steamExecutable: steamExecutable, prefix: prefix) {
            let steamapps = library.appendingPathComponent("steamapps")
            let manifestURL = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
                  let root = try? VDFNode.parse(text),
                  let state = root["AppState"] else {
                return .unknown("appmanifest_\(appID).acf could not be read")
            }
            let flags = Int(state["StateFlags"]?.stringValue ?? "") ?? 0
            let installDir = state["installdir"]?.stringValue ?? ""
            let directory = steamapps.appendingPathComponent("common").appendingPathComponent(installDir)
            let buildID = state["buildid"]?.stringValue
            // StateFlags bit 4 = fully installed. Other bits mean update/download work is pending.
            if flags == 4, !installDir.isEmpty, fm.fileExists(atPath: directory.path) {
                return .installed(directory: directory, buildID: buildID)
            }
            if flags & 4 != 0 {
                return .needsUpdate(directory: directory, stateFlags: flags)
            }
            return .incomplete(stateFlags: flags)
        }
        return .notInstalled
    }
}

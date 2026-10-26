import Foundation

/// Installs the steamwebhelper shim (Tools/steamwebhelper-shim) into Steam's CEF folders.
///
/// Steam's own `steamwebhelper.exe` is kept as `steamwebhelper_real.exe`. Steam updates
/// overwrite the shim with a new original, so installation runs before every Steam start
/// and refreshes the kept original when that happens.
public struct WebHelperShim: Sendable {
    public static let marker = Data("FRONTIER_LAUNCHER_WEBHELPER_SHIM_V1".utf8)
    public static let helperName = "steamwebhelper.exe"
    public static let originalName = "steamwebhelper_real.exe"

    public init() {}

    public static func isShim(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return data.range(of: marker) != nil
    }

    public func cefDirectories(steamExecutable: URL) -> [URL] {
        let root = steamExecutable.deletingLastPathComponent().appendingPathComponent("bin/cef", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("cef.win") }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.helperName).path) }
            .sorted { $0.path < $1.path }
    }

    /// Returns the folders that were changed. Never overwrites the only copy of Valve's binary.
    @discardableResult
    public func install(_ shim: URL, steamExecutable: URL) throws -> [URL] {
        guard Self.isShim(shim) else {
            throw LauncherError.steamOverrideInvalid(path: shim.path, reason: "it is not a Stockade steamwebhelper shim.")
        }
        let shimData = try Data(contentsOf: shim)
        var changed: [URL] = []
        for directory in cefDirectories(steamExecutable: steamExecutable) {
            let helper = directory.appendingPathComponent(Self.helperName)
            let original = directory.appendingPathComponent(Self.originalName)
            if Self.isShim(helper) {
                guard FileManager.default.fileExists(atPath: original.path), !Self.isShim(original) else {
                    throw LauncherError.webHelperOriginalMissing(directory: directory.path)
                }
                if (try? Data(contentsOf: helper)) != shimData {
                    try replace(helper, with: shimData)
                    changed.append(directory)
                }
            } else {
                // A fresh install or a Steam update: the current helper is Valve's. Keep it first.
                try replace(original, with: try Data(contentsOf: helper))
                try replace(helper, with: shimData)
                changed.append(directory)
            }
        }
        return changed
    }

    /// Puts Valve's binaries back and removes the kept copies.
    public func uninstall(steamExecutable: URL) throws {
        for directory in cefDirectories(steamExecutable: steamExecutable) {
            let helper = directory.appendingPathComponent(Self.helperName)
            let original = directory.appendingPathComponent(Self.originalName)
            guard Self.isShim(helper), FileManager.default.fileExists(atPath: original.path), !Self.isShim(original) else { continue }
            try replace(helper, with: try Data(contentsOf: original))
            try FileManager.default.removeItem(at: original)
        }
    }

    private func replace(_ url: URL, with data: Data) throws {
        try data.write(to: url, options: .atomic)
    }
}

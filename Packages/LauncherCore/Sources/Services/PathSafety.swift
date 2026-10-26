import Foundation

/// Path checks used before anything is created, locked or deleted.
public enum PathSafety {
    /// Resolves symlinks for the deepest existing ancestor and appends the remaining
    /// components, so paths that do not exist yet still compare correctly.
    public static func canonical(_ url: URL) -> URL {
        var pending: [String] = []
        var current = url.standardizedFileURL
        while true {
            if let real = realPath(current.path) {
                // Built from strings: URL standardization rewrites /private/var to /var
                // only for some paths, which would break containment comparisons.
                let path = ([real == "/" ? "" : real] + pending.reversed()).joined(separator: "/")
                return URL(fileURLWithPath: path.isEmpty ? "/" : path)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return url.standardizedFileURL
            }
            pending.append(current.lastPathComponent)
            current = parent
        }
    }

    /// True when `child` is strictly inside `root` after resolving symlinks.
    public static func isContained(_ child: URL, in root: URL) -> Bool {
        let childComponents = canonical(child).pathComponents
        let rootComponents = canonical(root).pathComponents
        return childComponents.count > rootComponents.count
            && Array(childComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// A prefix must sit strictly inside the launcher-owned prefixes root.
    public static func validateOwnedLocation(_ url: URL, ownedRoot: URL) throws {
        if url.pathComponents.contains("..") {
            throw LauncherError.unsafePath(path: url.path, reason: "the path contains “..”.")
        }
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw LauncherError.unsafePath(path: url.path, reason: "the path is not absolute.")
        }
        guard isContained(url, in: ownedRoot) else {
            throw LauncherError.unsafePath(
                path: url.path,
                reason: "it resolves outside the launcher-owned folder \(canonical(ownedRoot).path)."
            )
        }
    }

    /// Detects paths on an external volume that is not mounted.
    public static func isOnUnmountedVolume(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        let volume = "/Volumes/" + components[2]
        return !fileManager.fileExists(atPath: volume)
    }

    /// Turns a display name into a single safe path component.
    public static func safeComponent(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let filtered = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "Prefix" : trimmed
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

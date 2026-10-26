import Foundation

/// Child processes get a documented allowlist of host variables plus runtime-required ones.
/// User DLL overrides, DYLD_* preloads and the interactive shell PATH are never inherited.
public enum EnvironmentPolicy {
    public static let inheritedKeys: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]
    public static let inheritedPrefixes = ["LC_"]
    public static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Keys whose values are safe to show (after redaction) in a diagnostics report.
    public static let reportableKeys: Set<String> = [
        "PATH", "LANG", "WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES", "WINEARCH",
    ]

    public static func base(from host: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in host {
            if inheritedKeys.contains(key) || inheritedPrefixes.contains(where: key.hasPrefix) {
                result[key] = value
            }
        }
        result["PATH"] = basePath
        return result
    }
}

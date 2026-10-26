import Foundation

public enum LaunchPurpose: String, Codable, Sendable {
    case queryVersion
    case initializePrefix
    case waitForPrefixIdle
    case runInstaller
    case openSteam
    case launchGame
    case shutdownPrefix
    case listProcesses
}

/// Everything needed to start one process, built without executing it.
/// Arguments are passed straight to `Process`; nothing is ever interpreted by a shell.
public struct LaunchPlan: Codable, Sendable, Equatable {
    public var purpose: LaunchPurpose
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    /// True when the action affects every program in the prefix (for example `wineserver -k`).
    public var affectsWholePrefix: Bool

    public init(
        purpose: LaunchPurpose,
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        affectsWholePrefix: Bool = false
    ) {
        self.purpose = purpose
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.affectsWholePrefix = affectsWholePrefix
    }

    /// A human-readable form for diagnostics. Only allowlisted environment keys are shown.
    public func sanitizedDescription(redactor: Redactor) -> String {
        var lines: [String] = []
        lines.append("purpose: \(purpose.rawValue)")
        lines.append("executable: \(redactor.redact(executable.path))")
        let args = arguments.map { "  - \(redactor.redact($0))" }
        lines.append("arguments:" + (args.isEmpty ? " []" : "\n" + args.joined(separator: "\n")))
        lines.append("workingDirectory: \(redactor.redact(workingDirectory.path))")
        lines.append("environment:")
        for key in environment.keys.sorted() where EnvironmentPolicy.reportableKeys.contains(key) {
            lines.append("  \(key)=\(redactor.redact(environment[key] ?? ""))")
        }
        let hidden = environment.keys.filter { !EnvironmentPolicy.reportableKeys.contains($0) }.count
        if hidden > 0 {
            lines.append("  (\(hidden) other variable(s) omitted)")
        }
        return lines.joined(separator: "\n")
    }
}

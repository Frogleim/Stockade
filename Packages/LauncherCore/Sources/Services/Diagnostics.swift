import Foundation

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum HostInfo {
    public static var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    public static var hardwareModel: String {
        sysctlString("hw.model") ?? "unknown"
    }

    public static var cpuBrand: String {
        sysctlString("machdep.cpu.brand_string") ?? "unknown"
    }

    public static var memoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    public static var launcherVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    public static func versions(runtime: RuntimeDescriptor?) -> VersionInfo {
        VersionInfo(
            macOS: macOSVersion,
            hardwareModel: "\(hardwareModel), \(cpuBrand), \(memoryGB) GB",
            runtime: runtime?.versionOutput ?? "none",
            launcher: launcherVersion
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct DiagnosticsInput: Sendable {
    public var configuration: LauncherConfiguration
    public var versions: VersionInfo
    public var prefixStatus: PrefixStatus?
    public var installStatus: GameInstallStatus?
    public var launchPlan: LaunchPlan?
    public var lastSession: LaunchSession?
    public var logTail: [String]
    public var problems: [String]

    public init(
        configuration: LauncherConfiguration,
        versions: VersionInfo,
        prefixStatus: PrefixStatus? = nil,
        installStatus: GameInstallStatus? = nil,
        launchPlan: LaunchPlan? = nil,
        lastSession: LaunchSession? = nil,
        logTail: [String] = [],
        problems: [String] = []
    ) {
        self.configuration = configuration
        self.versions = versions
        self.prefixStatus = prefixStatus
        self.installStatus = installStatus
        self.launchPlan = launchPlan
        self.lastSession = lastSession
        self.logTail = logTail
        self.problems = problems
    }
}

/// Builds a plain-text report. It contains versions, statuses, a sanitized launch plan and a
/// bounded log tail. It never includes Steam data, cookies, saves or a full environment dump.
public struct DiagnosticsReportBuilder: Sendable {
    public var redactor: Redactor

    public init(redactor: Redactor = Redactor()) {
        self.redactor = redactor
    }

    public func build(_ input: DiagnosticsInput) -> String {
        var out: [String] = []
        out.append("# Stockade diagnostics")
        out.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("")
        out.append("## Host")
        out.append("macOS: \(input.versions.macOS)")
        out.append("hardware: \(input.versions.hardwareModel)")
        out.append("launcher: \(input.versions.launcher)")
        out.append("")
        out.append("## Runtime")
        if let runtime = input.configuration.activeRuntime {
            out.append("name: \(runtime.displayName)")
            out.append("version: \(runtime.versionOutput)")
            out.append("adapter: \(runtime.adapter.rawValue)")
            out.append("architectures: \(runtime.architectures.map(\.rawValue).joined(separator: ", "))")
            out.append("detected backends: \(runtime.detectedBackends.map(\.displayName).joined(separator: ", "))")
            out.append("wine: \(redactor.redact(runtime.wineExecutable.path))")
            out.append("sha256: \(runtime.executableSHA256)")
        } else {
            out.append("none selected")
        }
        out.append("")
        out.append("## Prefix and game")
        if let prefix = input.configuration.activePrefix {
            out.append("prefix: \(redactor.redact(prefix.url.path))")
        }
        out.append("prefix status: \(input.prefixStatus?.rawValue ?? "unknown")")
        if let profile = input.configuration.activeProfile {
            out.append("game: \(profile.name) (Steam app \(profile.steamAppID))")
            out.append("backend: \(profile.backend.displayName)")
            out.append("launch arguments: \(profile.launchArguments.isEmpty ? "none" : profile.launchArguments.map(redactor.redact).joined(separator: " "))")
        }
        out.append("steam client arguments: \((input.configuration.steamClientArguments ?? []).joined(separator: " ").nilIfEmpty ?? "none")")
        out.append("install status: \(input.installStatus?.summary ?? "unknown")")
        out.append("verbose wine logging: \(input.configuration.verboseWineLogging)")
        if !input.problems.isEmpty {
            out.append("")
            out.append("## Detected problems")
            out.append(contentsOf: input.problems.map { "- \(redactor.redact($0))" })
        }
        if let plan = input.launchPlan {
            out.append("")
            out.append("## Launch plan (sanitized)")
            out.append(plan.sanitizedDescription(redactor: redactor))
        }
        if let session = input.lastSession {
            out.append("")
            out.append("## Last session")
            out.append("requested: \(ISO8601DateFormatter().string(from: session.requestedAt))")
            out.append("phase: \(session.phase.rawValue) — \(session.phase.headline)")
            if let reason = session.failureReason { out.append("failure: \(redactor.redact(reason))") }
            if let status = session.steamRequestExitStatus { out.append("steam request exit status: \(status)") }
            out.append("observed game processes: \(session.observedGameProcesses.count)")
        }
        out.append("")
        out.append("## Log tail (\(input.logTail.count) lines)")
        out.append(contentsOf: input.logTail.map(redactor.redact))
        return out.joined(separator: "\n") + "\n"
    }
}

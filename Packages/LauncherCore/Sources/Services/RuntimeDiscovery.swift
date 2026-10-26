import CryptoKit
import Foundation

public struct RuntimeValidationReport: Sendable, Equatable {
    public var descriptor: RuntimeDescriptor
    public var warnings: [String]
}

/// Validates a user-selected Wine runtime and records exactly what it is.
public struct RuntimeDiscovery: Sendable {
    public var supervisor: ProcessSupervisor
    public var versionTimeout: Duration
    public var rosettaInstalled: @Sendable () -> Bool

    public init(
        supervisor: ProcessSupervisor = ProcessSupervisor(),
        versionTimeout: Duration = .seconds(30),
        rosettaInstalled: @escaping @Sendable () -> Bool = {
            FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        }
    ) {
        self.supervisor = supervisor
        self.versionTimeout = versionTimeout
        self.rosettaInstalled = rosettaInstalled
    }

    public static let wineserverNames = ["wineserver", "wineserver64"]

    public func validate(
        wineExecutable selected: URL,
        displayName: String? = nil,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> RuntimeValidationReport {
        let fm = FileManager.default
        if PathSafety.isOnUnmountedVolume(selected) {
            throw LauncherError.volumeUnavailable(path: selected.path)
        }
        let wine = PathSafety.canonical(selected)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: wine.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw LauncherError.runtimeNotFound(path: selected.path)
        }
        guard fm.isExecutableFile(atPath: wine.path) else {
            throw LauncherError.runtimeNotExecutable(path: wine.path)
        }

        let binDirectory = wine.deletingLastPathComponent()
        let candidates = Self.wineserverNames.map { binDirectory.appendingPathComponent($0) }
        guard let wineserver = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw LauncherError.runtimeCompanionMissing(name: "wineserver", searched: candidates.map(\.path))
        }

        var warnings: [String] = []
        let architectures = MachO.architectures(of: wine)
        switch architectures {
        case [.x86_64]:
            if !rosettaInstalled() {
                warnings.append("This runtime is x86-64 only and Rosetta 2 is not installed. Install it with `softwareupdate --install-rosetta`.")
            }
        case [.script]:
            warnings.append("The selected wine is a wrapper script; its CPU architecture could not be determined.")
        case [.unknown]:
            warnings.append("The selected file is not a recognized Mach-O executable.")
        default:
            break
        }

        let provisional = RuntimeDescriptor(
            displayName: displayName ?? binDirectory.deletingLastPathComponent().lastPathComponent,
            wineExecutable: wine,
            wineserverExecutable: wineserver,
            versionOutput: "",
            architectures: architectures,
            detectedBackends: [],
            executableSHA256: ""
        )
        let scratch = fm.temporaryDirectory.appendingPathComponent("stockade-version-\(UUID().uuidString)")
        let plan = try StandardWineAdapter().plan(
            .queryVersion,
            context: LaunchContext(runtime: provisional, prefix: scratch, hostEnvironment: hostEnvironment)
        )
        let (exit, tail) = try await supervisor.run(plan, timeout: versionTimeout, keepLines: 20)
        let version = tail.filter { $0.stream == .stdout }.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard exit.succeeded, !version.isEmpty else {
            let detail = tail.map(\.text).suffix(3).joined(separator: " ")
            throw LauncherError.runtimeVersionFailed(detail: detail.isEmpty ? "exit status \(exit.status)" : detail)
        }

        var descriptor = provisional
        descriptor.versionOutput = version
        descriptor.detectedBackends = Self.detectBackends(runtimeRoot: binDirectory.deletingLastPathComponent())
        descriptor.executableSHA256 = (try? Self.sha256(of: wine)) ?? ""
        if descriptor.displayName.isEmpty { descriptor.displayName = version }
        return RuntimeValidationReport(descriptor: descriptor, warnings: warnings)
    }

    /// Reports graphics translation files the runtime appears to ship. Detection is not verification.
    static func detectBackends(runtimeRoot: URL) -> [GraphicsBackend] {
        let fm = FileManager.default
        var backends: [GraphicsBackend] = [.wined3d]
        let libWine = runtimeRoot.appendingPathComponent("lib/wine")
        let dxmtMarkers = ["x86_64-windows/winemetal.dll", "x86_64-unix/winemetal.so"]
        if dxmtMarkers.contains(where: { fm.fileExists(atPath: libWine.appendingPathComponent($0).path) }) {
            backends.append(.dxmt)
        }
        let d3dMetalMarkers = ["lib/external/D3DMetal.framework", "lib/D3DMetal.framework"]
        if d3dMetalMarkers.contains(where: { fm.fileExists(atPath: runtimeRoot.appendingPathComponent($0).path) }) {
            backends.append(.d3dmetal)
        }
        return backends
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum MachO {
    static let cpuTypeX86_64: UInt32 = 0x0100_0007
    static let cpuTypeARM64: UInt32 = 0x0100_000C

    static func architectures(of url: URL) -> [CPUArchitecture] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [.unknown] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return [.unknown] }
        let bytes = [UInt8](header)
        if bytes[0] == 0x23, bytes[1] == 0x21 { return [.script] }   // "#!"

        func be32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func le32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        func map(_ cpu: UInt32) -> CPUArchitecture {
            switch cpu {
            case cpuTypeX86_64: return .x86_64
            case cpuTypeARM64: return .arm64
            default: return .unknown
            }
        }

        switch be32(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let is64 = be32(0) == 0xCAFE_BABF
            let count = Int(be32(4))
            let stride = is64 ? 32 : 20
            let archs = (0..<min(count, 16)).map { map(be32(8 + $0 * stride)) }
            return archs.isEmpty ? [.unknown] : Array(Set(archs)).sorted { $0.rawValue < $1.rawValue }
        default:
            break
        }
        if le32(0) == 0xFEED_FACF || le32(0) == 0xFEED_FACE {
            return [map(le32(4))]
        }
        return [.unknown]
    }
}

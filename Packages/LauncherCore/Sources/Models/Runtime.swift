import Foundation

public enum CPUArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64
    case script
    case unknown
}

/// Graphics translation available in a runtime. Detection only reports what the runtime
/// appears to ship; the launcher never switches backends it has not verified.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    case runtimeDefault
    case wined3d
    case dxmt
    case d3dmetal

    public var displayName: String {
        switch self {
        case .runtimeDefault: return "Runtime default"
        case .wined3d: return "WineD3D"
        case .dxmt: return "DXMT (Direct3D 10/11 → Metal)"
        case .d3dmetal: return "D3DMetal"
        }
    }
}

public enum RuntimeAdapterKind: String, Codable, Sendable, CaseIterable {
    /// A Wine build invoked as `wine <program>` with `wineserver` beside it.
    case standardWine
}

public struct RuntimeDescriptor: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var displayName: String
    public var adapter: RuntimeAdapterKind
    public var wineExecutable: URL
    public var wineserverExecutable: URL
    public var versionOutput: String
    public var architectures: [CPUArchitecture]
    public var detectedBackends: [GraphicsBackend]
    public var executableSHA256: String
    public var validatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        adapter: RuntimeAdapterKind = .standardWine,
        wineExecutable: URL,
        wineserverExecutable: URL,
        versionOutput: String,
        architectures: [CPUArchitecture],
        detectedBackends: [GraphicsBackend],
        executableSHA256: String,
        validatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.adapter = adapter
        self.wineExecutable = wineExecutable
        self.wineserverExecutable = wineserverExecutable
        self.versionOutput = versionOutput
        self.architectures = architectures
        self.detectedBackends = detectedBackends
        self.executableSHA256 = executableSHA256
        self.validatedAt = validatedAt
    }

    /// Only an x86-64-only binary needs Rosetta. ARM64 and universal runtimes do not.
    public var needsRosetta: Bool {
        architectures == [.x86_64]
    }
}

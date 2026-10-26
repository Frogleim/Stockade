import Foundation

public enum PrefixStatus: String, Codable, Sendable {
    case missing
    case uninitialized
    case initializing
    case interrupted
    case initialized
}

public struct PrefixDescriptor: Codable, Sendable, Identifiable, Equatable, Hashable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var url: URL
    public var runtimeID: UUID
    public var schemaVersion: Int
    public var createdAt: Date
    public var lastSuccessfulLaunch: Date?

    public init(
        id: UUID = UUID(),
        url: URL,
        runtimeID: UUID,
        schemaVersion: Int = PrefixDescriptor.currentSchemaVersion,
        createdAt: Date = Date(),
        lastSuccessfulLaunch: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.runtimeID = runtimeID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.lastSuccessfulLaunch = lastSuccessfulLaunch
    }
}

/// Written inside the prefix only after `wineboot --init` succeeds.
public struct PrefixMarker: Codable, Sendable, Equatable {
    public var runtimeID: UUID
    public var runtimeVersion: String
    public var completedAt: Date

    public init(runtimeID: UUID, runtimeVersion: String, completedAt: Date = Date()) {
        self.runtimeID = runtimeID
        self.runtimeVersion = runtimeVersion
        self.completedAt = completedAt
    }
}

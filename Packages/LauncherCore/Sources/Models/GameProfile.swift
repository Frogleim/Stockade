import Foundation

public struct GameProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    /// Farthest Frontier on the official Steam store (https://store.steampowered.com/app/1044720/).
    public static let farthestFrontierAppID = 1044720

    public var id: UUID
    public var name: String
    public var steamAppID: Int
    public var prefixID: UUID
    /// Arguments passed to the game after `-applaunch <id>`. Only add arguments that were verified.
    public var launchArguments: [String]
    public var backend: GraphicsBackend
    /// Substrings matched against process arguments to recognize the running game.
    /// Verify against the real process name during the Phase 0 baseline.
    public var processMatchHints: [String]
    /// A save directory the person verified by creating a save and watching it change.
    public var saveDirectory: URL?

    public init(
        id: UUID = UUID(),
        name: String = "Farthest Frontier",
        steamAppID: Int = GameProfile.farthestFrontierAppID,
        prefixID: UUID,
        launchArguments: [String] = [],
        backend: GraphicsBackend = .runtimeDefault,
        processMatchHints: [String] = ["Farthest Frontier.exe", "FarthestFrontier.exe"],
        saveDirectory: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.steamAppID = steamAppID
        self.prefixID = prefixID
        self.launchArguments = launchArguments
        self.backend = backend
        self.processMatchHints = processMatchHints
        self.saveDirectory = saveDirectory
    }
}

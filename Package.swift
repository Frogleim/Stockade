// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stockade",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Stockade", targets: ["Stockade"]),
        .executable(name: "stockade-cli", targets: ["stockade-cli"]),
    ],
    dependencies: [
        .package(path: "Packages/LauncherCore"),
    ],
    targets: [
        .executableTarget(
            name: "Stockade",
            dependencies: [.product(name: "LauncherCore", package: "LauncherCore")],
            path: "Stockade"
        ),
        .executableTarget(
            name: "stockade-cli",
            dependencies: [.product(name: "LauncherCore", package: "LauncherCore")],
            path: "Tools/stockade-cli"
        ),
    ]
)

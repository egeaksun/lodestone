// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lodestone",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lodestone", targets: ["Lodestone"]),
        // Installed as `lodestone`. The product can't be named that: it would collide with the app
        // executable on a case-insensitive file system.
        .executable(name: "lodestone-cli", targets: ["LodestoneCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure logic: geometry, models, formatting. No AppKit, fully unit tested.
        .target(name: "LodestoneCore"),
        // Engines shared by the app and the CLI: logging, IPC, media and document processing.
        .target(name: "LodestoneKit", dependencies: ["LodestoneCore"]),
        .executableTarget(name: "Lodestone", dependencies: ["LodestoneCore", "LodestoneKit"]),
        .executableTarget(name: "LodestoneCLI", dependencies: [
            "LodestoneCore", "LodestoneKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "LodestoneCoreTests", dependencies: ["LodestoneCore"]),
        .testTarget(name: "LodestoneKitTests", dependencies: ["LodestoneKit"]),
    ]
)

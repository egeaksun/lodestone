// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lodestone",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lodestone", targets: ["Lodestone"]),
    ],
    targets: [
        .target(name: "LodestoneCore"),
        .executableTarget(name: "Lodestone", dependencies: ["LodestoneCore"]),
        .testTarget(name: "LodestoneCoreTests", dependencies: ["LodestoneCore"]),
    ]
)

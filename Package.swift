// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Velora",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Velora", targets: ["Velora"]),
               .executable(name: "VeloraCheck", targets: ["VeloraCheck"]),
               .executable(name: "VeloraTracksCheck", targets: ["VeloraTracksCheck"])],
    targets: [
        .target(name: "VeloraCore"),
        .executableTarget(name: "Velora", dependencies: ["VeloraCore"]),
        .executableTarget(name: "VeloraCheck", dependencies: ["VeloraCore"]),
        .executableTarget(name: "VeloraTracksCheck", dependencies: ["VeloraCore"]),
        .testTarget(name: "VeloraCoreTests", dependencies: ["VeloraCore"])
    ],
    swiftLanguageModes: [.v5]
)

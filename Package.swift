// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoughScore",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "RoughScore", targets: ["RoughScore"])],
    targets: [
        .target(name: "RoughScoreCore"),
        .executableTarget(name: "RoughScore", dependencies: ["RoughScoreCore"]),
        .testTarget(name: "RoughScoreTests", dependencies: ["RoughScoreCore", "RoughScore"])
    ]
)

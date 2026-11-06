// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClickyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClickyCore", targets: ["ClickyCore"]),
        .library(name: "ClickySpeech", targets: ["ClickySpeech"]),
        .executable(name: "ClickyBrainTools", targets: ["ClickyBrainTools"]),
    ],
    dependencies: [
        // Runs Parakeet speech models on the Mac (Apache-2.0, FluidInference).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.2"),
    ],
    targets: [
        .target(name: "ClickyCore"),
        .target(
            name: "ClickySpeech",
            dependencies: [
                "ClickyCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // The helper the CLI starts over MCP (stdio) to serve the two read-only brain tools. Built into the app bundle.
        .executableTarget(name: "ClickyBrainTools", dependencies: ["ClickyCore"]),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore"]),
        .testTarget(name: "ClickySpeechTests", dependencies: ["ClickySpeech", "ClickyCore"]),
    ]
)

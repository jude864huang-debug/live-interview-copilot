// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Live Interview Copilot",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "LiveInterviewCopilotKit",
            targets: ["LiveInterviewCopilotKit"]
        ),
        .executable(
            name: "LiveInterviewCopilot",
            targets: ["LiveInterviewCopilotAppExecutable"]
        ),
        .executable(
            name: "Benchmark",
            targets: ["Benchmark"]
        ),
    ],
    dependencies: [
        // FluidAudio has made source-breaking API changes in patch releases.
        // Pin exactly so SwiftPM and Xcode smoke builds resolve the same SDK.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        // Newer WhisperKit releases reference macOS 26 SDK-only Core ML cases
        // when compiled by Swift 6.2+, so keep the last macOS 15-compatible release.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.15.0"),
        // This is a transitive dependency of swift-transformers/Jinja. Version
        // 1.3 adds Swift Span overloads that are unavailable in the local SDK.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "LiveInterviewCopilotKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "Sources/LiveInterviewCopilot",
            exclude: ["Info.plist", "LiveInterviewCopilot.entitlements", "Assets", "Resources"]
        ),
        .executableTarget(
            name: "LiveInterviewCopilotAppExecutable",
            dependencies: ["LiveInterviewCopilotKit"],
            path: "Sources/LiveInterviewCopilotApp"
        ),
        .executableTarget(
            name: "Benchmark",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Benchmark"
        ),
        .testTarget(
            name: "LiveInterviewCopilotTests",
            dependencies: ["LiveInterviewCopilotKit"],
            path: "Tests/LiveInterviewCopilotTests"
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVIS",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "JARVIS",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/JARVIS",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

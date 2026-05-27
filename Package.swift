// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyMic",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            "2.6.0"..<"3.0.0"
        ),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            from: "0.11.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "KeyMic",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/KeyMic",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

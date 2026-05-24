// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeyMic",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            "2.6.0"..<"3.0.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "KeyMic",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/KeyMic",
            resources: [
                .process("Resources")
            ]
        )
    ]
)

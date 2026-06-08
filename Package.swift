// swift-tools-version: 5.9
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
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx"
        ),
        .executableTarget(
            name: "KeyMic",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "CSherpaOnnx"
            ],
            path: "Sources/KeyMic",
            resources: [
                .process("Resources")
            ]
        )
    ]
)

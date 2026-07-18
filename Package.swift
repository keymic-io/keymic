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
        ),
        .package(
            url: "https://github.com/TelemetryDeck/SwiftSDK",
            "2.14.0"..<"3.0.0"
        ),
        .package(
            url: "https://github.com/getsentry/sentry-cocoa",
            from: "9.0.0"
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
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                "CSherpaOnnx"
            ],
            path: "Sources/KeyMic",
            resources: [
                .process("Resources")
            ]
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyMic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KeyMic",
            path: "Sources/KeyMic"
        )
    ]
)

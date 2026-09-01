// swift-tools-version: 5.9
import PackageDescription

// OCAudioCore: shared audio infrastructure for speech providers — PCM16
// conversion, WAV container building, and the WebSocket scaffolding that
// streaming transcription sessions subclass. Foundation + AVFoundation only;
// provider selection, credentials and app policy stay in the host app.
// Floor is macOS 10.15 for URLSessionWebSocketTask.
let package = Package(
    name: "OCAudioCore",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "OCAudioCore",
            targets: ["OCAudioCore"]
        )
    ],
    targets: [
        .target(
            name: "OCAudioCore",
            dependencies: [],
            path: "Sources/OCAudioCore"
        ),
        .testTarget(
            name: "OCAudioCoreTests",
            dependencies: ["OCAudioCore"],
            path: "Tests/OCAudioCoreTests"
        )
    ]
)

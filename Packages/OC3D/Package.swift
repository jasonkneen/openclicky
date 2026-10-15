// swift-tools-version: 5.9
import PackageDescription

// OC3D: provider-agnostic 3D asset generation.
//   OC3DCore — request/progress/result/error value types, the provider
//              protocol, and the download-URL safety policy. Foundation only.
//   OCTripo  — the Tripo AI transport implementing that protocol.
// Credentials, asset directories and job/UI state stay in the host app; the
// provider takes an apiKeyProvider closure and a destination directory.
let package = Package(
    name: "OC3D",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "OC3DCore", targets: ["OC3DCore"]),
        .library(name: "OCTripo", targets: ["OCTripo"])
    ],
    targets: [
        .target(
            name: "OC3DCore",
            dependencies: [],
            path: "Sources/OC3DCore"
        ),
        .target(
            name: "OCTripo",
            dependencies: ["OC3DCore"],
            path: "Sources/OCTripo"
        ),
        .testTarget(
            name: "OC3DCoreTests",
            dependencies: ["OC3DCore"],
            path: "Tests/OC3DCoreTests"
        ),
        .testTarget(
            name: "OCTripoTests",
            dependencies: ["OCTripo", "OC3DCore"],
            path: "Tests/OCTripoTests"
        )
    ]
)

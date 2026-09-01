// swift-tools-version: 5.9
import PackageDescription

// OCFoundation: brand-neutral persistence primitives (atomic Codable JSON
// files, Application Support resolution). Foundation-only; no product paths,
// no app identity, no UI. Floor is macOS 10.13 because of
// JSONEncoder.OutputFormatting.sortedKeys.
let package = Package(
    name: "OCFoundation",
    platforms: [
        .macOS(.v10_13)
    ],
    products: [
        .library(
            name: "OCFoundation",
            targets: ["OCFoundation"]
        )
    ],
    targets: [
        .target(
            name: "OCFoundation",
            dependencies: [],
            path: "Sources/OCFoundation"
        ),
        .testTarget(
            name: "OCFoundationTests",
            dependencies: ["OCFoundation"],
            path: "Tests/OCFoundationTests"
        )
    ]
)

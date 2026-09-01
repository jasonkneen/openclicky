// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OCCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OCCore",
            targets: ["OCCore"]
        )
    ],
    targets: [
        .target(
            name: "OCCore",
            dependencies: [],
            path: "Sources/OCCore"
        )
    ]
)

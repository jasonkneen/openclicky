// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OCMarkdown",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OCMarkdown",
            targets: ["OCMarkdown"]
        )
    ],
    dependencies: [
        .package(path: "../OCUI")
    ],
    targets: [
        .target(
            name: "OCMarkdown",
            dependencies: [
                .product(name: "OCUI", package: "OCUI")
            ],
            path: "Sources/OCMarkdown"
        )
    ]
)

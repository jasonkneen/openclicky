// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OCMemory",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OCMemory",
            targets: ["OCMemory"]
        )
    ],
    dependencies: [
        .package(path: "../OCCore"),
        .package(path: "../OCUI")
    ],
    targets: [
        .target(
            name: "OCMemory",
            dependencies: [
                .product(name: "OCCore", package: "OCCore"),
                .product(name: "OCUI", package: "OCUI")
            ],
            path: "Sources/OCMemory"
        )
    ]
)

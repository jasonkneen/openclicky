// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OCUI",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OCUI",
            targets: ["OCUI"]
        )
    ],
    dependencies: [
        .package(path: "../OCCore")
    ],
    targets: [
        .target(
            name: "OCUI",
            dependencies: [
                .product(name: "OCCore", package: "OCCore")
            ],
            path: "Sources/OCUI"
        )
    ]
)

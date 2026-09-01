// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OCBrowser",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OCBrowser",
            targets: ["OCBrowser"]
        )
    ],
    dependencies: [
        .package(path: "../OCCore"),
        .package(path: "../OCUI")
    ],
    targets: [
        .target(
            name: "OCBrowser",
            dependencies: [
                .product(name: "OCCore", package: "OCCore"),
                .product(name: "OCUI", package: "OCUI")
            ],
            path: "Sources/OCBrowser"
        )
    ]
)

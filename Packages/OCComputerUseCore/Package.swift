// swift-tools-version: 5.9
import PackageDescription

// OCComputerUseCore: pure data contracts for macOS computer-use — window /
// app / permission / status models, visual-guidance overlay models and the
// circle-select snapping geometry. Foundation + CoreGraphics only. No AppKit,
// Accessibility, ScreenCaptureKit or CGEvent; those implementations stay in
// the host app (a future OCMacComputerUse). Floor is macOS 10.15 for
// Identifiable.
let package = Package(
    name: "OCComputerUseCore",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "OCComputerUseCore",
            targets: ["OCComputerUseCore"]
        )
    ],
    targets: [
        .target(
            name: "OCComputerUseCore",
            dependencies: [],
            path: "Sources/OCComputerUseCore"
        ),
        .testTarget(
            name: "OCComputerUseCoreTests",
            dependencies: ["OCComputerUseCore"],
            path: "Tests/OCComputerUseCoreTests"
        )
    ]
)

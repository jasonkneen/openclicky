// swift-tools-version: 5.9
import PackageDescription

// OCAutomation: scheduled-prompt models and a self-contained 5-field cron
// evaluator. Foundation-only. Floor is macOS 10.15 because
// OpenClickyAutomation conforms to Identifiable.
let package = Package(
    name: "OCAutomation",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "OCAutomation",
            targets: ["OCAutomation"]
        )
    ],
    targets: [
        .target(
            name: "OCAutomation",
            dependencies: [],
            path: "Sources/OCAutomation"
        ),
        .testTarget(
            name: "OCAutomationTests",
            dependencies: ["OCAutomation"],
            path: "Tests/OCAutomationTests"
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageTracker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "UsageTrackerApp", targets: ["UsageTrackerApp"])
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .executableTarget(
            name: "UsageTrackerApp",
            dependencies: ["UsageCore"],
            path: "Sources/UsageTrackerApp"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests"
        )
    ]
)

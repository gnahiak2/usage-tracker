// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Command Line Tools ships Swift Testing's macro plugin in a subdirectory the driver does not search.
// Load it explicitly when present; a full Xcode toolchain already finds it.
let testingMacros = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingMacros)
    ? [.swiftLanguageMode(.v5), .unsafeFlags(["-load-plugin-library", testingMacros])]
    : [.swiftLanguageMode(.v5)]

let package = Package(
    name: "UsageTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageTracker", targets: ["UsageTracker"]),
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore",
            resources: [.copy("Resources/cli.sb")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "UsageTracker",
            dependencies: ["UsageCore"],
            path: "Sources/UsageTracker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            swiftSettings: testSwiftSettings
        ),
    ]
)

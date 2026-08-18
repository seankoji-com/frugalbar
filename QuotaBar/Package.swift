// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBarApp"]),
    ],
    dependencies: [],
    targets: [
        // --- Core domain (no UI) ---
        .target(
            name: "QuotaBarCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        // --- SwiftUI popover + MenuBar ---
        .target(
            name: "QuotaBarUI",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        // --- App entry point (NSApplication + MenuBarExtra) ---
        .executableTarget(
            name: "QuotaBarApp",
            dependencies: ["QuotaBarCore", "QuotaBarUI"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        // --- Tests ---
        .testTarget(
            name: "QuotaBarCoreTests",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "QuotaBarUITests",
            dependencies: ["QuotaBarUI"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)

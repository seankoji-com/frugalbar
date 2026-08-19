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
        .target(
            name: "QuotaBarCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuotaBarUI",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "QuotaBarApp",
            dependencies: ["QuotaBarCore", "QuotaBarUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuotaBarCoreTests",
            dependencies: ["QuotaBarCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuotaBarUITests",
            dependencies: ["QuotaBarUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

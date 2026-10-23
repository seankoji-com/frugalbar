// swift-tools-version: 6.0
import PackageDescription
import Foundation

let appInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist").path

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
            swiftSettings: [.swiftLanguageMode(.v6)],
            // Preserve the installed bare frugalbar's WebKit namespace across
            // executable renames, including its existing Claude website data.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", appInfoPlist,
            ])]
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

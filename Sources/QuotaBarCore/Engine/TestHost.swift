import Foundation

/// Whether this process is a test runner.
///
/// Two safety nets depend on the answer: tests must not reach the network
/// (`QuotaHTTP.makeDefaultSession()`) and must not read or write the real
/// user's preference file (`CredentialStore.preferences`).
///
/// Getting it wrong fails open, so the detection is deliberately broad. The
/// environment checks alone were not enough: under `swift test` with
/// swift-testing, `XCTestCase` is not loaded and **no** `XCTest*` or
/// `SWIFT_TESTING_*` variable is set, so every guard built on them silently
/// passed through to the real session. The process name is the only signal
/// that is actually present.
enum TestHost {
    static var isActive: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil {
            return true
        }
        let name = ProcessInfo.processInfo.processName
        return name == "swiftpm-testing-helper"
            || name == "xctest"
            || name.hasSuffix(".xctest")
            || name.hasSuffix("PackageTests")
    }
}

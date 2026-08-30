import Testing
import Foundation
@testable import QuotaBarCore

@Suite("CLIArguments")
struct CLIArgumentsTests {

    @Test("--help is recognised and exits 0")
    func helpRecognised() {
        #expect(CLIArguments.handleIfPresent(["frugalbar", "--help"]) == 0)
    }

    @Test("--version is recognised and exits 0")
    func versionRecognised() {
        #expect(CLIArguments.handleIfPresent(["frugalbar", "--version"]) == 0)
    }

    @Test("an unrecognised argument list returns nil so the app starts normally")
    func noFlagsReturnsNil() {
        #expect(CLIArguments.handleIfPresent(["frugalbar"]) == nil)
        #expect(CLIArguments.handleIfPresent(["frugalbar", "--unknown"]) == nil)
    }

    @Test("--doctor exits 0 when every non-optional check passes")
    func doctorExitsZeroOnSuccess() {
        // The real machine running this test is, by construction, at or
        // above the floor (otherwise the test binary couldn't have launched).
        // Calls runDoctor directly with an isolated label rather than going
        // through handleIfPresent(["frugalbar", "--doctor"]): the one-line
        // dispatch in handleIfPresent isn't worth re-testing here, and a
        // shared production Keychain label would race the other tests below
        // under `swift test --parallel`. helpRecognised/versionRecognised/
        // noFlagsReturnsNil already cover handleIfPresent's argument parsing.
        #expect(CLIArguments.runDoctor(keychainProbeLabel: "com.quotabar.test.\(UUID().uuidString)"))
    }

    @Test("macOSFloorMet is true at and above the floor, false below it")
    func macOSFloorBoundary() {
        let floor = CLIArguments.requiredMacOSFloor
        #expect(CLIArguments.macOSFloorMet(currentVersion: floor))
        #expect(CLIArguments.macOSFloorMet(
            currentVersion: OperatingSystemVersion(majorVersion: floor.majorVersion + 1, minorVersion: 0, patchVersion: 0)
        ))
        #expect(!CLIArguments.macOSFloorMet(
            currentVersion: OperatingSystemVersion(majorVersion: floor.majorVersion - 1, minorVersion: 0, patchVersion: 0)
        ))
    }

    @Test("runDoctor reports failure and returns false when the OS floor isn't met")
    func runDoctorFailsBelowFloor() {
        let floor = CLIArguments.requiredMacOSFloor
        let belowFloor = OperatingSystemVersion(majorVersion: floor.majorVersion - 1, minorVersion: 0, patchVersion: 0)
        #expect(CLIArguments.runDoctor(
            currentVersion: belowFloor,
            keychainProbeLabel: "com.quotabar.test.\(UUID().uuidString)"
        ) == false)
    }

    @Test("keychainRoundTripSucceeds uses a randomised label and reports true")
    func keychainRoundTrip() {
        #expect(CLIArguments.keychainRoundTripSucceeds(label: "com.quotabar.test.\(UUID().uuidString)"))
    }
}

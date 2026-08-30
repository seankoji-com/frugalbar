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
        // above the floor (otherwise the test binary couldn't have launched)
        // and the Keychain round-trip uses a throwaway randomised label, so
        // a real invocation here should report success.
        #expect(CLIArguments.handleIfPresent(["frugalbar", "--doctor"]) == 0)
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
        #expect(CLIArguments.runDoctor(currentVersion: belowFloor) == false)
    }

    @Test("keychainRoundTripSucceeds uses a throwaway label and reports true")
    func keychainRoundTrip() {
        #expect(CLIArguments.keychainRoundTripSucceeds())
    }
}

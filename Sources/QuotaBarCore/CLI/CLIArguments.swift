import Foundation

/// Handles `--help`, `--version`, and `--doctor` before any AppKit/SwiftUI
/// machinery spins up, so a CLI invocation gets a fast, plain-text answer
/// instead of a menu bar icon flashing into existence and a popover it never
/// wanted.
///
/// Lives in `QuotaBarCore`, not the `.executableTarget` that calls it: no
/// test target depends on an executable target, so a copy sitting in
/// `QuotaBarApp` could carry a "stays trivially testable" claim indefinitely
/// without a single test enforcing it.
public enum CLIArguments {

    /// POSIX `EX_USAGE` — an invocation with a typo'd or unknown flag exits
    /// with this instead of silently launching the GUI the user never asked
    /// for.
    static let usageExitCode: Int32 = 64

    /// The executable's own name as invoked — derived from `argv[0]`, not
    /// hardcoded, so a symlink or renamed copy reflects its actual name in
    /// help text and usage errors.
    static var executableName: String {
        (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? AppInfo.name.lowercased()
    }

    static var helpText: String {
        """
        \(AppInfo.name) — track AI usage & dev limits in the macOS menu bar.

        Usage: \(executableName) [options]

        Options:
          --help       Show this help text and exit.
          --version    Print the installed version and exit.
          --doctor     Run startup diagnostics and exit.
        """
    }

    /// Returns the process exit code to use when a recognised flag was found
    /// and its output already printed — `nil` when no flag was recognised and
    /// the invocation is a bare launch, in which case the caller should
    /// proceed to start the app normally. Any non-empty argument list that
    /// matches no recognised flag is a usage error, reported on stderr and
    /// returning a non-zero code, so a typo can never quietly launch the GUI.
    /// The caller is responsible for calling `exit(code)` immediately
    /// afterward — this type never exits on its own, so it stays testable.
    @discardableResult
    public static func handleIfPresent(_ arguments: [String] = CommandLine.arguments) -> Int32? {
        // LaunchServices launches a bare executable with a leading `-psn_…`
        // (process serial number) argument, e.g. when opened from Finder/Dock.
        // That is a bare launch, not a typo: strip such args before the
        // unknown-flag branch so the GUI still starts. (Today the release is a
        // CLI binary run from a terminal/LaunchAgent, so this is defensive —
        // but it is exactly the classic footgun otherwise.)
        let flags = Array(arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        if flags.contains("--help") {
            print(helpText)
            return 0
        }
        if flags.contains("--version") {
            print("\(AppInfo.name) \(AppInfo.version)")
            return 0
        }
        if flags.contains("--doctor") {
            return DoctorReport.run().exitCode
        }
        if !flags.isEmpty {
            stderr("\(executableName): unrecognized option: \(flags.joined(separator: " "))")
            stderr("Try '\(executableName) --help' for usage.")
            return usageExitCode
        }
        return nil
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// The macOS floor this build actually requires — the one place `--doctor`
    /// states it, kept as a value so the printed label cannot drift away from
    /// the version actually tested. Must track `Package.swift`'s `.macOS(.v15)`.
    static let requiredMacOSFloor = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    /// Startup diagnostic pass: the macOS floor this build actually requires
    /// (`Package.swift`'s `.macOS(.v15)`), a Keychain read/write round-trip,
    /// and presence of the Gemini OAuth client env vars. Prints one line per
    /// check and returns whether every non-optional check passed, so a caller
    /// — `frugalbar --doctor`, a `brew test`, a launchd health check — has a
    /// process exit code to act on instead of only printed text.
    @discardableResult
    static func runDoctor(
        currentVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        keychainProbeLabel: String = "com.quotabar.doctor.probe"
    ) -> Bool {
        DoctorReport.run(
            currentVersion: currentVersion,
            keychainProbeLabel: keychainProbeLabel
        ).allOK
    }

    /// Triples the floor against a running OS. Compares the full
    /// major.minor.patch set, not just major/minor, so the check stays
    /// correct if the floor ever gains a patch component.
    static func macOSFloorMet(currentVersion: OperatingSystemVersion) -> Bool {
        macOSFloorMet(currentVersion, requiredMacOSFloor)
    }

    /// Lexicographic comparison of two version triples; `true` when `v` is at
    /// (or above) `floor`.
    private static func macOSFloorMet(_ v: OperatingSystemVersion, _ floor: OperatingSystemVersion) -> Bool {
        if v.majorVersion != floor.majorVersion { return v.majorVersion > floor.majorVersion }
        if v.minorVersion != floor.minorVersion { return v.minorVersion > floor.minorVersion }
        return v.patchVersion >= floor.patchVersion
    }

    static func osVersionString(_ v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Defaults to one fixed, distinctive label — not a fresh UUID per run —
    /// so a *real* `--doctor` invocation never reads or clobbers a real
    /// credential slot (no vendor account name collides with it) while also
    /// never accumulating orphans: a process killed between `set` and the
    /// `defer`-`delete` below leaves at most this one stray item, and the
    /// *next* successful `--doctor` run overwrites and then deletes that
    /// same slot rather than planting a new UUID-named one next to it.
    /// Tests must never rely on that default — pass an isolated label so
    /// concurrent tests can't race the same Keychain slot under
    /// `swift test --parallel`. `.failure` carries the underlying error
    /// rather than collapsing to a bare `false` — `--doctor` needs to say
    /// *why* a round-trip failed, and a locked keychain
    /// (`errSecInteractionNotAllowed`) points at a different fix than a
    /// genuinely broken build. The probe never prompts for authentication:
    /// a doctor run must be non-interactive end to end.
    static func keychainRoundTripResult(label: String = "com.quotabar.doctor.probe") -> Result<Void, Error> {
        let probe = "frugalbar-doctor-probe"
        do {
            try KeychainManager.shared.set(key: probe, label: label, allowsAuthenticationPrompt: false)
            defer { try? KeychainManager.shared.delete(label: label) }
            guard try KeychainManager.shared.get(label: label, allowsAuthenticationPrompt: false) == probe else {
                return .failure(KeychainError.invalidData)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

/// Owns the doctor pass: runs each check, holds the results in one shape
/// (so pass/fail and exit-code policy live together rather than across
/// `handleIfPresent`'s `Int32?`, `runDoctor`'s `Bool` and a redundant Bool
/// collapse), and prints the pretty report.
struct DoctorReport {

    /// One diagnostic check and whether it passed. `optional` mirrors the
    /// report semantics: absent is a valid, healthy state for an optional
    /// check, so it never flips the exit code.
    struct Check {
        let label: String
        let ok: Bool
        let optional: Bool
    }

    private(set) var osOK = false
    private(set) var keychainOK = false
    private(set) var envChecks: [Check] = []

    /// Every non-optional check passed — the only thing the exit code should
    /// depend on.
    var allOK: Bool { osOK && keychainOK }

    /// The process exit code: 0 when healthy, 1 when a required check failed.
    var exitCode: Int32 { allOK ? 0 : 1 }

    /// Runs the full diagnostic pass, printing the header and one report line
    /// per check, and returns the populated report so callers can read both
    /// the per-check results and the aggregate exit policy.
    @discardableResult
    static func run(
        currentVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        keychainProbeLabel: String = "com.quotabar.doctor.probe"
    ) -> DoctorReport {
        var report = DoctorReport()
        print("\(AppInfo.name) \(AppInfo.version) doctor")

        // In practice dyld refuses to launch this binary at all below its
        // deployment target, so this check can only ever observe [ok] when
        // run for real — `currentVersion` exists so a test can still drive
        // the [FAIL] branch without a machine actually running an old OS.
        report.osOK = CLIArguments.macOSFloorMet(currentVersion: currentVersion)
        report.report("macOS \(CLIArguments.osVersionString(currentVersion)) meets the macOS \(CLIArguments.floorText) minimum", ok: report.osOK)

        switch CLIArguments.keychainRoundTripResult(label: keychainProbeLabel) {
        case .failure(let error):
            report.keychainOK = false
            report.report("Keychain read/write round-trip", ok: false)
            // Printed on its own line rather than folded into the report
            // label: the OSStatus text distinguishes a locked keychain
            // (errSecInteractionNotAllowed / errSecAuthFailed) from a
            // genuinely broken build, which `ok: false` alone cannot.
            print("       \(error.localizedDescription)")
        case .success:
            report.keychainOK = true
            report.report("Keychain read/write round-trip", ok: true)
        }

        // Gemini OAuth is opt-in, and the env vars are only one of two ways to
        // supply it (Settings → Keys → Gemini writes the same client to the
        // Keychain). So an unset var reports as skipped, never as a failure: a
        // doctor that prints [FAIL] on a correctly configured machine trains
        // people to ignore it. Optional checks never affect the exit code.
        //
        // Presence is read through GeminiOAuthSession's constants so a rename
        // can't silently desync this check from the provider that reads them —
        // but the *printed* label is plain prose that never reproduces a
        // secret-named env identifier. Doctor output must never carry (or even
        // look like it carries) a credential (AGENTS.md); CodeQL flags exactly
        // this kind of name-in-log as cleartext secrets.
        let env = ProcessInfo.processInfo.environment
        let geminiOAuthEnvConfigured =
            !(env[GeminiOAuthSession.clientIDEnvVar] ?? "").isEmpty
            && !(env[GeminiOAuthSession.clientSecretEnvVar] ?? "").isEmpty
        let envLabel = "Gemini OAuth client env configured"
        report.envChecks.append(Check(label: envLabel, ok: geminiOAuthEnvConfigured, optional: true))
        report.report(envLabel, ok: geminiOAuthEnvConfigured, optional: true)
        return report
    }

    /// `optional: true` means "absent is a valid, healthy state" — it reports
    /// `[--]` rather than `[FAIL]`, so the only FAIL lines are ones that
    /// actually describe a broken install.
    private func report(_ label: String, ok: Bool, optional: Bool = false) {
        let marker: String
        if ok {
            marker = "[ok]  "
        } else {
            marker = optional ? "[--]  " : "[FAIL]"
        }
        print("\(marker) \(label)")
    }
}

/// Convenience for the doctor's own floor label — "macOS 15.0 minimum" keeps
/// the number accurate to `requiredMacOSFloor` while spelling out macOS and
/// dropping the developer-jargon "floor".
extension CLIArguments {
    static var floorText: String {
        "\(requiredMacOSFloor.majorVersion).\(requiredMacOSFloor.minorVersion)"
    }
}

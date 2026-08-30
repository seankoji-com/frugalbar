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

    public static let helpText = """
        \(AppInfo.name) — track AI usage & dev limits in the macOS menu bar.

        Usage: frugalbar [options]

        Options:
          --help       Show this help text and exit.
          --version    Print the installed version and exit.
          --doctor     Run startup diagnostics and exit.
        """

    /// Returns the process exit code to use when a recognised flag was found
    /// and its output already printed — `nil` when no flag was recognised, in
    /// which case the caller should proceed to start the app normally. The
    /// caller is responsible for calling `exit(code)` immediately afterward —
    /// this type never exits on its own, so it stays testable.
    @discardableResult
    public static func handleIfPresent(_ arguments: [String] = CommandLine.arguments) -> Int32? {
        let flags = Set(arguments.dropFirst())
        if flags.contains("--help") {
            print(helpText)
            return 0
        }
        if flags.contains("--version") {
            print(AppInfo.version)
            return 0
        }
        if flags.contains("--doctor") {
            return runDoctor() ? 0 : 1
        }
        return nil
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
        print("\(AppInfo.name) doctor")
        var allOK = true

        // In practice dyld refuses to launch this binary at all below its
        // deployment target, so this check can only ever observe [ok] when
        // run for real — `currentVersion` exists so a test can still drive
        // the [FAIL] branch without a machine actually running an old OS.
        let osOK = macOSFloorMet(currentVersion: currentVersion)
        report("macOS \(osVersionString(currentVersion)) meets the \(floorText) floor", ok: osOK)
        if !osOK { allOK = false }

        let kcResult = keychainRoundTripResult(label: keychainProbeLabel)
        let kcOK: Bool
        if case .failure(let error) = kcResult {
            kcOK = false
            report("Keychain read/write round-trip", ok: false)
            // Printed on its own line rather than folded into the report
            // label: the OSStatus text distinguishes a locked keychain
            // (errSecInteractionNotAllowed / errSecAuthFailed) from a
            // genuinely broken build, which `ok: false` alone cannot.
            print("       \(error.localizedDescription)")
        } else {
            kcOK = true
            report("Keychain read/write round-trip", ok: true)
        }
        if !kcOK { allOK = false }

        // Gemini OAuth is opt-in, and the env vars are only one of two ways to
        // supply it (Settings → Keys → Gemini writes the same client to the
        // Keychain). So an unset var reports as skipped, never as a failure: a
        // doctor that prints [FAIL] on a correctly configured machine trains
        // people to ignore it. Optional checks never affect the exit code.
        let env = ProcessInfo.processInfo.environment
        for name in ["FRUGALBAR_GEMINI_CLIENT_ID", "FRUGALBAR_GEMINI_CLIENT_SECRET"] {
            report(
                "\(name) is set (optional — Gemini OAuth via env)",
                ok: !(env[name] ?? "").isEmpty,
                optional: true
            )
        }
        return allOK
    }

    private static var floorText: String {
        "\(requiredMacOSFloor.majorVersion).\(requiredMacOSFloor.minorVersion)"
    }

    static func macOSFloorMet(currentVersion: OperatingSystemVersion) -> Bool {
        currentVersion.majorVersion > requiredMacOSFloor.majorVersion
            || (currentVersion.majorVersion == requiredMacOSFloor.majorVersion
                && currentVersion.minorVersion >= requiredMacOSFloor.minorVersion)
    }

    private static func osVersionString(_ v: OperatingSystemVersion) -> String {
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
    /// genuinely broken build.
    static func keychainRoundTripResult(label: String = "com.quotabar.doctor.probe") -> Result<Void, Error> {
        let probe = "frugalbar-doctor-probe"
        do {
            try KeychainManager.shared.set(key: probe, label: label)
            defer { try? KeychainManager.shared.delete(label: label) }
            guard try KeychainManager.shared.get(label: label) == probe else {
                return .failure(KeychainError.invalidData)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static func keychainRoundTripSucceeds(label: String = "com.quotabar.doctor.probe") -> Bool {
        if case .success = keychainRoundTripResult(label: label) { return true }
        return false
    }

    /// `optional: true` means "absent is a valid, healthy state" — it reports
    /// `[--]` rather than `[FAIL]`, so the only FAIL lines are ones that
    /// actually describe a broken install.
    private static func report(_ label: String, ok: Bool, optional: Bool = false) {
        let marker: String
        if ok {
            marker = "[ok]  "
        } else {
            marker = optional ? "[--]  " : "[FAIL]"
        }
        print("\(marker) \(label)")
    }
}

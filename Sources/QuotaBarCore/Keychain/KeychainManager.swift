import Foundation
import Security
import LocalAuthentication

// MARK: - Keychain wrapper (macOS Security framework)

public enum KeychainError: Error, Sendable, LocalizedError, Equatable {
    case unknown(OSStatus)
    case itemNotFound
    case invalidData
    case vaultUnavailable(VaultUnavailableReason)

    public var errorDescription: String? {
        switch self {
        case .unknown(let s):
            switch s {
            case errSecInteractionNotAllowed:
                "Keychain access not allowed (your keychain may be locked)"
            case errSecAuthFailed:
                "Keychain authentication failed"
            case errSecMissingEntitlement:
                "Keychain access requires a signed, entitled app"
            case errSecDuplicateItem:
                "A matching keychain item already exists"
            default:
                // Raw OSStatus is acceptable for statuses we do not recognise:
                // the number is all we have, and showing it is better than a
                // guess at what it means.
                "Keychain error \(s)"
            }
        case .itemNotFound:   "No matching keychain item found"
        case .invalidData:    "Invalid keychain data"
        case .vaultUnavailable(let reason): reason.userDescription
        }
    }
}

public final class KeychainManager: Sendable {

    public static let shared = KeychainManager(vault: .shared)
    public let vault: KeychainVault

    public init(vault: KeychainVault) {
        self.vault = vault
    }

    // MARK: Public API

    public func set(key: String, label: String, allowsAuthenticationPrompt: Bool = true) throws {
        try vault.write(key, namespace: .keys, account: label, allowsPrompt: allowsAuthenticationPrompt)
    }

    /// Background write (e.g. Gemini OAuth renewal): stores in memory immediately
    /// and attempts a non-blocking, non-interactive persist without blocking
    /// provider deadlines or prompting. `alsoExpecting` maps other labels to
    /// the value (nil = absent) they must still hold when the write lands.
    @discardableResult
    public func setDeferred(
        key: String,
        label: String,
        expectedPreviousValue: String? = nil,
        alsoExpecting: [String: String?] = [:]
    ) -> DeferredWriteOutcome {
        vault.writeDeferred(
            key,
            namespace: .keys,
            account: label,
            expectedPreviousValue: expectedPreviousValue,
            alsoExpecting: alsoExpecting.map { (namespace: .keys, account: $0.key, value: $0.value) }
        )
    }

    public func get(label: String, allowsAuthenticationPrompt: Bool = true) throws -> String {
        guard let value = try vault.read(
            namespace: .keys,
            account: label,
            allowsPrompt: allowsAuthenticationPrompt
        ) else {
            throw KeychainError.itemNotFound
        }
        return value
    }

    /// Cache-only read for UI surfaces (Settings). Never touches Keychain or prompts.
    public func cachedValue(label: String) -> String? {
        vault.cachedValue(namespace: .keys, account: label)
    }

    public func delete(label: String, allowsAuthenticationPrompt: Bool = true) throws {
        try vault.delete(namespace: .keys, account: label, allowsPrompt: allowsAuthenticationPrompt)
    }
}

// MARK: - Credential store (reads from keychain + CLI config files)

public enum CredentialStore {

    /// Whether to consult local CLI config files and the `gh` binary when the
    /// Keychain has no entry.
    ///
    /// Off by default. Silent credential discovery is incompatible with the
    /// App Sandbox (which forbids `Process` and reads outside the container),
    /// and harvesting tokens the user never explicitly offered is a poor
    /// default for a product that asks to be trusted with credentials.
    /// Settings exposes this as an explicit opt-in.
    public static let cliDiscoveryDefaultsKey = "QuotaBarEnableCLIDiscovery"

    /// Whether to deliver a local notification when a provider's quota
    /// recovers from critical/exhausted back to having headroom.
    ///
    /// Off by default — a banner some users never asked for is a poor
    /// default. Delivery is FrugalBar's own when the executable runs from a
    /// `.app` (macOS asks once for permission); the bare binary has no
    /// notification identity, so it falls back to an
    /// `osascript`/`display notification` call instead of
    /// `UNUserNotificationCenter`. Settings exposes this as an explicit
    /// opt-in.
    public static let notificationsEnabledDefaultsKey = "QuotaBarEnableNotifications"

    /// Providers whose window resets the user asked to be told about, stored
    /// as vendor raw values. Empty by default: opt-in per provider, delivered
    /// through the same path as recovery notifications.
    public static let resetAlertVendorsDefaultsKey = "QuotaBarResetAlertVendors"

    /// Whether to poll OpenRouter's public model catalog and the vendor news
    /// feeds for model releases and price changes.
    ///
    /// On by default, unlike every other opt-in here: the requests carry no
    /// credential and read only public data (OpenRouter's key-less catalog,
    /// public RSS), once every six hours. Quota-derived events (resets,
    /// restores, reset credits) are recorded regardless; this gates only the
    /// outbound polling.
    public static let eventTrackingEnabledDefaultsKey = "QuotaBarEventTracking"

    /// Which AI-event kinds post a notification, stored as sorted raw values.
    /// `.usageReset` is listed here for completeness but its banners stay
    /// governed per vendor by `resetAlertVendors`.
    /// Retired opt-in list, read once for migration (see
    /// `eventNotificationDisabledKindsDefaultsKey`).
    public static let eventNotificationKindsDefaultsKey = "QuotaBarEventNotificationKinds"

    /// Whether the History window is viewing synthetic sample fixture data
    /// rather than the live historical database.
    public static let sampleModeDefaultsKey = "QuotaBarHistorySampleMode"

    /// Where FrugalBar's preferences live.
    ///
    /// Before the executable embedded a bundle ID, `.standard` keyed off the
    /// process name: release `frugalbar` and SwiftPM `QuotaBar` kept separate
    /// files. Pinning the suite preserves those migrated preferences and keeps
    /// storage explicit in bare executables, wrappers and test hosts.
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` while
    /// being documented as thread-safe: it is a shared store by design, and
    /// this reference is assigned once and never reassigned.
    nonisolated(unsafe) public static let preferences: UserDefaults =
        UserDefaults(suiteName: preferencesSuiteName(isTestHost: TestHost.isActive)) ?? .standard

    static let sharedSuiteName = "com.quotabar.app"

    /// The suite to read and write. One expression, so there is no second path
    /// that could quietly fall back to `.standard` and reintroduce the
    /// process-name split. Tests get their own suite: they must never touch the
    /// real user's preference file.
    static func preferencesSuiteName(isTestHost: Bool) -> String {
        isTestHost ? "\(sharedSuiteName).tests" : sharedSuiteName
    }

    /// Process names this app has shipped under, newest first. Only read once,
    /// to carry a pre-existing choice into `preferences`.
    static let legacyPreferenceDomains = ["frugalbar", "QuotaBar"]

    /// Carries a pre-existing discovery choice into the shared store.
    ///
    /// Idempotent: once `preferences` holds a value it is never overwritten, so
    /// this cannot undo a later change made in Settings.
    public static func migrateLegacyPreferences() {
        guard preferences.object(forKey: cliDiscoveryDefaultsKey) == nil else { return }
        let legacy = legacyPreferenceDomains.compactMap {
            UserDefaults.standard.persistentDomain(forName: $0)?[cliDiscoveryDefaultsKey] as? Bool
        }
        guard let value = migratedDiscoverySetting(fromLegacy: legacy) else { return }
        preferences.set(value, forKey: cliDiscoveryDefaultsKey)
    }

    /// Resolves conflicting legacy domains. Prefers the one that had discovery
    /// on — that is the binary the user actually had working — but adopts
    /// `false` when every domain said no, so a deliberate opt-out is never
    /// silently reversed by the move to a shared store.
    static func migratedDiscoverySetting(fromLegacy values: [Bool]) -> Bool? {
        values.isEmpty ? nil : values.contains(true)
    }

    /// Test-only task-local override for `isCLIDiscoveryEnabled` so parallel
    /// tests can exercise CLI discovery without mutating shared `UserDefaults`.
    @TaskLocal static var cliDiscoveryOverride: Bool? = nil

    public static var isCLIDiscoveryEnabled: Bool {
        cliDiscoveryOverride ?? preferences.bool(forKey: cliDiscoveryDefaultsKey)
    }

    public static var isNotificationsEnabled: Bool {
        preferences.bool(forKey: notificationsEnabledDefaultsKey)
    }

    public static var resetAlertVendors: Set<VendorIdentifier> {
        get { resetAlertVendors(fromStored: preferences.stringArray(forKey: resetAlertVendorsDefaultsKey)) }
        set { preferences.set(newValue.map(\.rawValue).sorted(), forKey: resetAlertVendorsDefaultsKey) }
    }

    /// Decodes the stored list. Unknown raw values (a provider removed in a
    /// later release) are dropped rather than failing the whole set.
    static func resetAlertVendors(fromStored raw: [String]?) -> Set<VendorIdentifier> {
        Set((raw ?? []).compactMap(VendorIdentifier.init(rawValue:)))
    }

    public static var isEventTrackingEnabled: Bool {
        // `bool(forKey:)` reads an absent key as false; this default is true.
        get { preferences.object(forKey: eventTrackingEnabledDefaultsKey) as? Bool ?? true }
        set { preferences.set(newValue, forKey: eventTrackingEnabledDefaultsKey) }
    }

    /// The kinds that notify when the user has never chosen: every kind
    /// FrugalBar surfaces.
    public static let defaultEventNotificationKinds: Set<AIEventKind> = Set(AIEventKind.surfaced)

    /// The kinds the user switched *off*. Storing the opt-outs rather than the
    /// opt-ins is what lets a kind added in a later version notify by default:
    /// a stored opt-in list from an older version could not name it, so it
    /// would have stayed silent for anyone who had ever touched a toggle.
    public static let eventNotificationDisabledKindsDefaultsKey = "QuotaBarEventNotificationDisabledKinds"

    public static var eventNotificationKinds: Set<AIEventKind> {
        get {
            eventNotificationKinds(
                disabled: preferences.stringArray(forKey: eventNotificationDisabledKindsDefaultsKey),
                legacyEnabled: preferences.stringArray(forKey: eventNotificationKindsDefaultsKey))
        }
        set {
            let disabled = defaultEventNotificationKinds.subtracting(newValue)
            preferences.set(disabled.map(\.rawValue).sorted(), forKey: eventNotificationDisabledKindsDefaultsKey)
        }
    }

    /// The kinds the older opt-in list let the user choose between. A kind
    /// missing from a stored opt-in list was only a deliberate "off" if it
    /// was on this list.
    static let legacyChoosableEventKinds: Set<AIEventKind> = [
        .usageRestored, .resetCreditGranted, .newModel, .priceChange,
    ]

    /// - The opt-out list wins when present; unknown raw values are dropped.
    /// - Otherwise an opt-in list from an older version is honoured for the
    ///   kinds it could have named, and every newer kind is on.
    /// - With neither, every surfaced kind is on.
    static func eventNotificationKinds(disabled: [String]?, legacyEnabled: [String]?) -> Set<AIEventKind> {
        if let disabled {
            return defaultEventNotificationKinds.subtracting(disabled.compactMap(AIEventKind.init(rawValue:)))
        }
        if let legacyEnabled {
            let enabled = Set(legacyEnabled.compactMap(AIEventKind.init(rawValue:)))
            return defaultEventNotificationKinds.subtracting(legacyChoosableEventKinds.subtracting(enabled))
        }
        return defaultEventNotificationKinds
    }

    public static var isSampleModeEnabled: Bool {
        get { preferences.bool(forKey: sampleModeDefaultsKey) }
        set { preferences.set(newValue, forKey: sampleModeDefaultsKey) }
    }

    // MARK: Desktop widget

    /// Whether the desktop widget panel was open, so launch can re-show it.
    public static let desktopWidgetVisibleDefaultsKey = "QuotaBarDesktopWidgetVisible"
    /// `DesktopWidgetMode` raw value.
    public static let desktopWidgetModeDefaultsKey = "QuotaBarDesktopWidgetMode"
    /// The panel frame, as `NSStringFromRect`.
    public static let desktopWidgetFrameDefaultsKey = "QuotaBarDesktopWidgetFrame"
    /// JSON-encoded chart filters (vendors, window, range, metric).
    public static let desktopWidgetFiltersDefaultsKey = "QuotaBarDesktopWidgetFilters"

    public static var isDesktopWidgetVisible: Bool {
        get { preferences.bool(forKey: desktopWidgetVisibleDefaultsKey) }
        set { preferences.set(newValue, forKey: desktopWidgetVisibleDefaultsKey) }
    }

    /// Unknown or missing values read as `.desktop`, the default.
    public static var desktopWidgetMode: DesktopWidgetMode {
        get { DesktopWidgetMode(stored: preferences.string(forKey: desktopWidgetModeDefaultsKey)) }
        set { preferences.set(newValue.rawValue, forKey: desktopWidgetModeDefaultsKey) }
    }

    public static var desktopWidgetFrameString: String? {
        get { preferences.string(forKey: desktopWidgetFrameDefaultsKey) }
        set { preferences.set(newValue, forKey: desktopWidgetFrameDefaultsKey) }
    }

    public static var desktopWidgetFiltersData: Data? {
        get { preferences.data(forKey: desktopWidgetFiltersDefaultsKey) }
        set { preferences.set(newValue, forKey: desktopWidgetFiltersDefaultsKey) }
    }

    /// Returns the API key for a vendor: Keychain first, then — only when the
    /// user has opted in — known CLI config locations.
    public static func apiKey(
        for vendor: VendorIdentifier,
        readKeychain: (String) -> String? = {
            try? KeychainManager.shared.get(label: $0, allowsAuthenticationPrompt: false)
        }
    ) -> String? {
        if let kc = readKeychain(vendor.rawValue), !kc.isEmpty {
            return kc
        }
        guard isCLIDiscoveryEnabled else { return nil }
        return discoverFromCLI(vendor: vendor)
    }

    /// Locations Homebrew and the system install `gh` into. `/usr/bin/env` is
    /// deliberately not used: it resolves through an inherited `PATH`, which a
    /// GUI app does not have (launchd gives it `/usr/bin:/bin:/usr/sbin:/sbin`),
    /// and which is user-writable — so it decides *which* binary runs.
    private static let ghCandidatePaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ]

    static func runGhAuthToken() -> String? {
        guard let ghPath = ghCandidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ghPath)
        task.arguments = ["auth", "token"]
        let out = Pipe()
        task.standardOutput = out
        let err = Pipe()
        task.standardError = err
        task.standardInput = FileHandle.nullDevice

        // `run()` throws when the binary cannot be launched. The previous code
        // used `try?` and then read `terminationStatus` regardless — which
        // raises an uncatchable NSException on an unlaunched Process.
        do {
            try task.run()
        } catch {
            // gh is installed but cannot be launched — a genuinely broken
            // state, distinct from "no gh installed" (which returns silently
            // above) so an operator can pin the root cause rather than seeing
            // only "Not configured" from every GitHub provider.
            NSLog("frugalbar: gh auth token: failed to launch \(ghPath): \(error.localizedDescription)")
            return nil
        }

        // Scheduled before the blocking read below, not after: this task's
        // own stdout pipe is what `readDataToEndOfFile()` blocks on, so a
        // child that hangs without writing or closing it would never let
        // control reach a kill timer registered afterward — the exact hang
        // this timer exists to bound.
        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) { [task] in
            if task.isRunning { task.terminate() }
        }

        // Read before waiting: waiting first can deadlock if the child fills
        // the pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            // gh is installed but `gh auth token` failed (not logged in, or
            // broken). Surface it in the unified log with gh's own stderr so
            // an operator can tell a broken gh from a clean no-credential
            // state instead of seeing only "Not configured".
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("frugalbar: gh auth token exited with status \(task.terminationStatus)\(errText.isEmpty ? "" : ": \(errText)")")
            return nil
        }

        let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    /// Short-lived memoisation for `gh auth token`, an out-of-process call.
    ///
    /// Three call sites resolve to the exact same answer: the REST provider
    /// (`.githubRest`), the GraphQL provider (`.githubGraphql`), and the
    /// Copilot fallback (which itself delegates to `.githubRest` below). One
    /// polling cycle fans out to all three, and without sharing a result that
    /// used to spawn `gh` three times for a token that had not changed.
    ///
    /// A plain lock rather than an actor: every caller already reaches this
    /// by way of `credentialQueue`, a background `DispatchQueue`, so there is
    /// no main-thread-blocking concern to justify hopping through
    /// `async`/`await`. An actor-backed cache did the opposite of what it
    /// looked like it was protecting against — an `await` on a *synchronous*
    /// actor method still runs that method's body (here, `runGhAuthToken()`'s
    /// blocking `Process`/pipe work) on the cooperative thread pool, so
    /// resolving it from a plain function required parking a
    /// `credentialQueue` thread on a `DispatchSemaphore` waiting on an
    /// unstructured `Task` drawing its own thread from that same pool — the
    /// exact pool-starvation shape `apiKeyAsync`'s own comment above warns
    /// against. A lock keeps everything, cache and subprocess alike, on the
    /// caller's own `credentialQueue` thread.
    final class CredentialCache: @unchecked Sendable {
        static let shared = CredentialCache()

        /// Long enough to cover one polling cycle's fan-out across providers;
        /// short enough that a token rotated via `gh auth login` mid-session is
        /// picked up well within the same session.
        static let ghTokenTTL: TimeInterval = 30
        static let claudeBlobTTL: TimeInterval = 300
        static let claudeBlobFailureTTL: TimeInterval = 30
        /// The Muse blob carries no expiry of its own, so this is purely a
        /// "do not shell out on every poll" window, like Claude's.
        static let museBlobTTL: TimeInterval = 300
        static let museBlobFailureTTL: TimeInterval = 30

        private let lock = NSLock()
        private var ghTokenCache: (token: String?, expires: Date)?
        private var claudeBlobCache: (data: Data?, expires: Date)?
        private var museBlobCache: (data: Data?, expires: Date)?

        func ghToken(now: Date, resolve: () -> String?) -> String? {
            lock.lock()
            if let cached = ghTokenCache, cached.expires > now {
                let token = cached.token
                lock.unlock()
                return token
            }
            lock.unlock()
            // `resolve()` runs outside the lock: it can shell out to `gh` and
            // block for up to 5s, and holding the lock across that would
            // serialise every concurrent caller — REST, GraphQL, Copilot —
            // onto one subprocess instead of just sharing its answer. A
            // concurrent miss simply resolves twice and last-write-wins on
            // the cache slot, which a 30s TTL doesn't need to dedupe.
            let token = resolve()
            lock.lock()
            // Cache only non-nil tokens. A nil resolves to a transient `gh auth
            // token` failure (non-zero exit / spawn error / 5s watchdog killing
            // a hung child), and pinning that to nil for the full TTL would make
            // every provider report "Not configured" until the cache expires.
            // The next call re-runs resolve() and gets a fresh answer.
            if token != nil {
                ghTokenCache = (token, now.addingTimeInterval(Self.ghTokenTTL))
            }
            lock.unlock()
            return token
        }

        func peekClaudeBlob(now: Date) -> Data? {
            lock.withLock {
                guard let cached = claudeBlobCache, cached.expires > now else { return nil }
                return cached.data
            }
        }

        func peekMuseBlob(now: Date) -> Data? {
            lock.withLock {
                guard let cached = museBlobCache, cached.expires > now else { return nil }
                return cached.data
            }
        }

        func claudeBlob(now: Date, resolve: () -> Data?) -> Data? {
            lock.lock()
            if let cached = claudeBlobCache, cached.expires > now {
                let data = cached.data
                lock.unlock()
                return data
            }
            lock.unlock()
            let data = resolve()
            lock.lock()
            if let data {
                var ttl = Self.claudeBlobTTL
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let oauth = json["claudeAiOauth"] as? [String: Any],
                   let expiresAt = oauth["expiresAt"] as? Double {
                    let tokenExpiry = Date(timeIntervalSince1970: expiresAt / 1000)
                    let remaining = tokenExpiry.timeIntervalSince(now) - 30
                    if remaining > 0 {
                        ttl = min(ttl, remaining)
                    }
                }
                claudeBlobCache = (data, now.addingTimeInterval(ttl))
            } else {
                claudeBlobCache = (nil, now.addingTimeInterval(Self.claudeBlobFailureTTL))
            }
            lock.unlock()
            return data
        }

        /// The Muse Code CLI credential blob. Unlike Claude's there is no
        /// embedded token expiry to shorten the TTL for, so a plain
        /// read-or-refresh cache suffices; a miss is held for the much shorter
        /// failure window, so running `muse login` is picked up promptly
        /// instead of being ignored until the full TTL lapses.
        func museBlob(now: Date, resolve: () -> Data?) -> Data? {
            lock.lock()
            if let cached = museBlobCache, cached.expires > now {
                let data = cached.data
                lock.unlock()
                return data
            }
            lock.unlock()
            let data = resolve()
            lock.lock()
            if let data {
                museBlobCache = (data, now.addingTimeInterval(Self.museBlobTTL))
            } else {
                museBlobCache = (nil, now.addingTimeInterval(Self.museBlobFailureTTL))
            }
            lock.unlock()
            return data
        }
    }

    private static let securityCandidatePaths = [
        "/usr/bin/security",
    ]

    static func runSecurityClaudeCredentials() -> Data? {
        guard !TestHost.isActive else { return nil }
        guard let securityPath = securityCandidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: securityPath)
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        task.standardOutput = out
        let err = Pipe()
        task.standardError = err
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) { [task] in
            if task.isRunning { task.terminate() }
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            return nil
        }

        return data.isEmpty ? nil : data
    }

    /// Task-local switch controlling whether ambient CLI discovery may invoke
    /// `/usr/bin/security`. Set to `false` during passive refreshes
    /// (`forceRefresh(allowInteractiveUnlock: false)`) so workspace edits and
    /// connection-sheet dismissal never trigger SecurityAgent prompts.
    @TaskLocal static var allowsSecurityCLI: Bool = true

    /// Test-only hook invoked when a credential lookup reaches the
    /// `/usr/bin/security` subprocess path, allowing tests to verify across
    /// GCD queue hops whether subprocess invocation is suppressed.
    @TaskLocal static var securityCLISubprocessHook: (@Sendable (_ service: String) -> Data?)? = nil

    private static func discoverClaudeBlob(allowsSecurityCLI: Bool = true) -> Data? {
        let effectiveSecurityCLI = allowsSecurityCLI && Self.allowsSecurityCLI
        let fileURL = CLIConfigLocations.liveClaudeRoot(containing: ".credentials.json")
            .appendingPathComponent(".credentials.json")
        if let fileData = try? Data(contentsOf: fileURL), !fileData.isEmpty {
            return fileData
        }
        if effectiveSecurityCLI {
            if let hook = securityCLISubprocessHook {
                if let hooked = hook("Claude Code-credentials"), !hooked.isEmpty {
                    return hooked
                }
            } else if let secData = runSecurityClaudeCredentials(), !secData.isEmpty {
                return secData
            }
        }
        guard !TestHost.isActive else { return nil }
        return claudeCodeKeychainBlob()
    }

    static func cachedClaudeBlob(now: Date = Date(), allowsSecurityCLI: Bool = true) -> Data? {
        let effectiveSecurityCLI = allowsSecurityCLI && Self.allowsSecurityCLI
        if !effectiveSecurityCLI {
            if let cached = CredentialCache.shared.peekClaudeBlob(now: now) {
                return cached
            }
            return discoverClaudeBlob(allowsSecurityCLI: false)
        }
        return CredentialCache.shared.claudeBlob(now: now) { discoverClaudeBlob(allowsSecurityCLI: true) }
    }

    /// The Muse Code CLI credential blob from the macOS login Keychain
    /// (service `ai.meta.dev.credentials`, account `meta`). Read with
    /// `/usr/bin/security` first, not `SecItemCopyMatching`: reading another
    /// app's Keychain item directly prompts the user every time from an
    /// unbundled process, exactly as it does for Claude's blob above.
    static func runSecurityMuseCredential() -> Data? {
        guard !TestHost.isActive else { return nil }
        guard let securityPath = securityCandidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: securityPath)
        task.arguments = ["find-generic-password", "-s", "ai.meta.dev.credentials", "-a", "meta", "-w"]
        let out = Pipe()
        task.standardOutput = out
        let err = Pipe()
        task.standardError = err
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) { [task] in
            if task.isRunning { task.terminate() }
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            return nil
        }

        return data.isEmpty ? nil : data
    }

    private static func discoverMuseBlob(allowsSecurityCLI: Bool = true) -> Data? {
        let effectiveSecurityCLI = allowsSecurityCLI && Self.allowsSecurityCLI
        if effectiveSecurityCLI {
            if let hook = securityCLISubprocessHook {
                if let hooked = hook("ai.meta.dev.credentials"), !hooked.isEmpty {
                    return hooked
                }
            } else if let secData = runSecurityMuseCredential(), !secData.isEmpty {
                return secData
            }
        }
        guard !TestHost.isActive else { return nil }
        return museKeychainBlob()
    }

    static func cachedMuseBlob(now: Date = Date(), allowsSecurityCLI: Bool = true) -> Data? {
        let effectiveSecurityCLI = allowsSecurityCLI && Self.allowsSecurityCLI
        if !effectiveSecurityCLI {
            if let cached = CredentialCache.shared.peekMuseBlob(now: now) {
                return cached
            }
            return discoverMuseBlob(allowsSecurityCLI: false)
        }
        return CredentialCache.shared.museBlob(now: now) { discoverMuseBlob(allowsSecurityCLI: true) }
    }

    /// The Muse blob the CLI writes to the macOS login Keychain, which lives
    /// under a different service name than our own items and so cannot be
    /// served by `KeychainManager`. Always non-interactive so a restrictive ACL
    /// never triggers a SecurityAgent prompt.
    static func museKeychainBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:                    kSecClassGenericPassword,
            kSecAttrService as String:              "ai.meta.dev.credentials",
            kSecAttrAccount as String:              "meta",
            kSecReturnData as String:               true,
            kSecMatchLimit as String:               kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: SystemKeychainBackend.nonPromptingAuthContext(),
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Synchronous bridge into `CredentialCache` for `discoverFromCLI`'s
    /// non-async call sites. A direct call, not a `Task`/semaphore bridge:
    /// `CredentialCache.ghToken` is itself synchronous now, so there is
    /// nothing to bridge into.
    static func cachedGhAuthToken(now: Date = Date()) -> String? {
        CredentialCache.shared.ghToken(now: now) { runGhAuthToken() }
    }

    private static func discoverFromCLI(vendor: VendorIdentifier) -> String? {
        switch vendor {
        case .githubRest, .githubGraphql:
            return cachedGhAuthToken()

        case .opencode:
            // ~/.local/share/opencode/auth.json
            let url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode/auth.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let go = json["opencode-go"] as? [String: Any],
                  let key = go["key"] as? String
            else { return nil }
            return key

        case .openrouter:
            // OPENROUTER_API_KEY env or auth.json
            if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !env.isEmpty {
                return env
            }
            let url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode/auth.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let or = json["openrouter"] as? [String: Any],
                  let key = or["key"] as? String
            else { return nil }
            return key

        case .deepseek:
            // DEEPSEEK_API_KEY env or auth.json (the OpenCode provider entry).
            if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !env.isEmpty {
                return env
            }
            let url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode/auth.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ds = json["deepseek"] as? [String: Any],
                  let key = ds["key"] as? String
            else { return nil }
            return key

        case .gemini, .antigravityClaude, .antigravityArgon:
            // Deliberately nothing. The Gemini provider reads Antigravity
            // subscription quota from the Cloud Code API, which takes a Google
            // OAuth bearer token — see the Connect Google account button in
            // Settings. Handing it a GEMINI_API_KEY (an AI Studio key for a
            // different product) would only ever produce a 401 that looks like
            // the user typed their key wrong.
            return nil

        case .openai:
            let url = CLIConfigLocations.liveCodexRoot(containing: "auth.json")
                .appendingPathComponent("auth.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = json["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String,
                  !token.isEmpty
            else { return nil }
            return token

        case .claude:
            // Claude CLI OAuth access token. A subscription tier by itself is
            // not a credential and must never render a made-up usage value.
            //
            // On macOS the CLI keeps this blob in the login Keychain, not on
            // disk; .credentials.json under the Claude config root (see
            // CLIConfigLocations) is the Linux (and older
            // install) location. Reading another app's Keychain item directly via
            // SecItemCopyMatching prompts the user every time from an unbundled
            // process; using /usr/bin/security and caching the blob in memory
            // resolves it cleanly without repetitive prompts.
            return claudeOAuthToken(from: cachedClaudeBlob())

        case .copilot:
            // 1. Check ~/.local/share/opencode/auth.json.
            //
            // `refresh` is the durable GitHub OAuth token from the device flow;
            // `access` is the short-lived Copilot API token minted from it, and
            // api.github.com does not accept it. Reading `access` here is what
            // made Copilot report "Credential rejected" indefinitely.
            let authUrl = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode/auth.json")
            if let token = copilotOAuthToken(from: try? Data(contentsOf: authUrl)) {
                return token
            }
            // 2. Check ~/.config/github-copilot/hosts.json
            let hostsUrl = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config/github-copilot/hosts.json")
            if let data = try? Data(contentsOf: hostsUrl),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (_, val) in json {
                    if let hostDict = val as? [String: Any],
                       let oauthToken = hostDict["oauth_token"] as? String, !oauthToken.isEmpty {
                        return oauthToken
                    }
                }
            }
            // 3. Fallback to gh auth token
            return Self.apiKey(for: .githubRest)

        case .grok:
            // The Grok CLI's cached OIDC access token. Short-lived — the CLI
            // refreshes it roughly every six hours, and FrugalBar deliberately
            // does not, so an expired one surfaces as "Credential rejected"
            // rather than being renewed behind the CLI's back.
            return GrokQuotaProvider.discoverCLIToken()

        case .opendesign:
            // Deliberately nothing. OpenDesign's usage is read through its
            // in-app web sign-in; no CLI holds a credential that reads it.
            return nil

        case .kiro:
            // Deliberately nothing. Kiro's credential is a bearer token paired
            // with a CodeWhisperer profile ARN, and one without the other is
            // useless — so the provider reads both together straight from the
            // CLI's state database rather than routing half of it through here.
            return nil

        case .devpass:
            // Deliberately nothing. DevPass ships no CLI: the key is a gateway
            // API key the user creates on the dashboard and pastes into
            // Settings, so there is no local file to discover it from.
            return nil

        case .commandcode:
            // The Command Code CLI writes a flat {"apiKey":"user_..."} to
            // ~/.commandcode/auth.json on `cmd login`. It is long-lived — there
            // is no token to refresh — and the same key authenticates both the
            // CLI and the API. The env var is honoured first, matching the
            // CLI's own precedence.
            for name in ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"] {
                if let value = ProcessInfo.processInfo.environment[name]?.trimmed, !value.isEmpty {
                    return value
                }
            }
            let authURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".commandcode/auth.json")
            guard let data = try? Data(contentsOf: authURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = (json["apiKey"] as? String)?.trimmed, !key.isEmpty
            else { return nil }
            return key

        case .clinepass:
            // Env vars, then the Cline CLI/SDK's providers.json, then the
            // legacy secrets.json — see `discoverCLICredential` for the exact
            // keys and their provenance.
            return ClinePassQuotaProvider.discoverCLICredential()

        case .muse:
            // The Muse Code CLI's OAuth session token, from the blob the CLI
            // keeps in the macOS login Keychain. The blob's minted api_key is
            // deliberately not used: the usage endpoint rejects it with 401.
            return MuseQuotaProvider.discoverCLICredential()
        }
    }
}

/// Where the desktop widget panel sits. Lives beside its preference key so
/// Settings and the panel read one definition.
public enum DesktopWidgetMode: String, Sendable, CaseIterable {
    /// On the wallpaper, below the desktop icons — out of the way of windows.
    case desktop
    /// Above ordinary windows.
    case floating

    /// Missing or unrecognised stored values fall back to `.desktop`.
    public init(stored raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .desktop
    }
}


extension CredentialStore {
    /// Async accessor for use from provider `fetchSnapshot()`.
    ///
    /// `apiKey(for:)` is synchronous and does blocking work — a Keychain call,
    /// file reads, and potentially a subprocess. Calling it directly from an
    /// async context parks a cooperative-pool thread, and with seven providers
    /// fetching concurrently that can starve the pool. This hops to a
    /// dedicated background queue instead.
    static func apiKeyAsync(for vendor: VendorIdentifier) async -> String? {
        let allowSecurityCLI = Self.allowsSecurityCLI
        let hook = Self.securityCLISubprocessHook
        let discovery = Self.cliDiscoveryOverride
        return await withCheckedContinuation { continuation in
            credentialQueue.async {
                let result = Self.$allowsSecurityCLI.withValue(allowSecurityCLI) {
                    Self.$securityCLISubprocessHook.withValue(hook) {
                        Self.$cliDiscoveryOverride.withValue(discovery) {
                            apiKey(for: vendor)
                        }
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Async accessor for a credential stored under an explicit Keychain label.
    ///
    /// Used by providers that keep one credential per instance (OpenCode Go
    /// workspaces) rather than one per vendor. `cliVendorFallback` is offered
    /// only when the caller has a CLI source to fall back to — and only when
    /// the user opted into CLI discovery — so a workspace that never had one
    /// cannot silently read another workspace's CLI credential.
    static func apiKeyAsync(label: String, cliVendorFallback: VendorIdentifier? = nil) async -> String? {
        let allowSecurityCLI = Self.allowsSecurityCLI
        let hook = Self.securityCLISubprocessHook
        return await withCheckedContinuation { continuation in
            credentialQueue.async {
                let result: String? = Self.$allowsSecurityCLI.withValue(allowSecurityCLI) {
                    Self.$securityCLISubprocessHook.withValue(hook) {
                        if let stored = try? KeychainManager.shared.get(label: label, allowsAuthenticationPrompt: false), !stored.isEmpty {
                            return stored
                        }
                        guard isCLIDiscoveryEnabled, let vendor = cliVendorFallback else {
                            return nil
                        }
                        return discoverFromCLI(vendor: vendor)
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// The credential blob the Claude Code CLI writes to the macOS login
    /// Keychain. It lives under a different service name than our own items,
    /// so `KeychainManager` — scoped to `com.quotabar.keys` — cannot serve it.
    /// Always non-interactive so a restrictive ACL never prompts.
    static func claudeCodeKeychainBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:                    kSecClassGenericPassword,
            kSecAttrService as String:              "Claude Code-credentials",
            kSecReturnData as String:               true,
            kSecMatchLimit as String:               kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: SystemKeychainBackend.nonPromptingAuthContext(),
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Extracts a still-valid OAuth access token from a Claude Code credential
    /// blob. An expired token is reported as absent: sending it would render a
    /// "credential rejected" the user cannot act on, when the honest state is
    /// "sign in to Claude again".
    static func claudeOAuthToken(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        // expiresAt is milliseconds since the epoch.
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: expiresAt / 1000) <= Date() {
            return nil
        }
        return token
    }

    /// Where a provider's credential is actually coming from right now.
    ///
    /// Settings needs this to answer the only question its key fields raise:
    /// do I have to fill this in? Two of the five are normally satisfied by CLI
    /// discovery, and a form that shows five identical empty boxes cannot say
    /// so. Carries no secret — only its provenance.
    public enum CredentialSource: Sendable, Equatable {
        /// Typed into this app and stored in our own Keychain item.
        case keychain
        /// Read from a CLI tool's own credential store. The string names it.
        case discovered(String)
        case absent
    }

    /// Human name for the place `discoverFromCLI` reads each vendor from.
    public static func discoverySourceName(for vendor: VendorIdentifier) -> String {
        switch vendor {
        case .claude:        "Claude Code login"
        case .openai:        "~/.codex/auth.json"
        case .gemini, .antigravityClaude, .antigravityArgon: "Google OAuth session"
        case .opencode:      "OpenCode auth.json"
        case .copilot:       "OpenCode auth.json"
        case .openrouter:    "OpenCode auth.json"
        case .deepseek:      "OpenCode auth.json"
        case .grok:          "grok CLI auth.json"
        case .kiro:          "kiro-cli state database"
        case .devpass:       "DevPass dashboard key"
        case .commandcode:   "~/.commandcode/auth.json"
        case .clinepass:     "~/.cline/data/settings/providers.json"
        case .muse:          "Muse CLI login Keychain"
        case .opendesign:    "open-design.ai web session"
        case .githubRest:    "gh auth token"
        case .githubGraphql: "gh auth token"
        }
    }

    /// Resolves provenance off the main thread — `discoverFromCLI` can shell
    /// out to `gh`, which has no business running during a view update.
    ///
    /// Strictly non-interactive: reads FrugalBar's vault from cache only and
    /// skips `/usr/bin/security` for third-party Keychain items so Settings
    /// provenance checks can never trigger a Keychain prompt.
    public static func credentialSourceAsync(for vendor: VendorIdentifier) async -> CredentialSource {
        await withCheckedContinuation { continuation in
            credentialQueue.async {
                if let stored = KeychainManager.shared.cachedValue(label: vendor.rawValue),
                   !stored.isEmpty {
                    continuation.resume(returning: .keychain)
                    return
                }
                guard isCLIDiscoveryEnabled else {
                    continuation.resume(returning: .absent)
                    return
                }
                if (vendor == .claude || vendor == .openai), let config = CLIProxyClient.discoverConfig() {
                    let host = config.url.host ?? "proxy"
                    continuation.resume(returning: .discovered("CLI Proxy (\(host))"))
                    return
                }
                let found: String?
                switch vendor {
                case .claude:
                    found = claudeOAuthToken(from: cachedClaudeBlob(allowsSecurityCLI: false))
                case .muse:
                    found = cachedMuseBlob(allowsSecurityCLI: false).flatMap {
                        MuseQuotaProvider.accessToken(from: $0)
                    }
                default:
                    found = discoverFromCLI(vendor: vendor)
                }
                guard let found, !found.isEmpty else {
                    continuation.resume(returning: .absent)
                    return
                }
                continuation.resume(returning: .discovered(discoverySourceName(for: vendor)))
            }
        }
    }

    /// The subscription tier the Claude Code credential blob reports, e.g.
    /// "Max (5x)" or "Pro".
    ///
    /// Anthropic's usage endpoint carries usage but not the plan, so this is
    /// the only place the tier is actually published. Returns nil rather than a
    /// guess: an earlier revision hardcoded a per-vendor tier table and labelled
    /// every Claude user "Max x20", Pro subscribers included.
    static func claudePlanName(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return nil }

        // rateLimitTier first: it is the more specific of the two. A
        // subscriptionType of "max" does not say whether that is the 5x plan or
        // the 20x one, and those are materially different allowances.
        if let tier = oauth["rateLimitTier"] as? String,
           let name = claudePlanName(fromRateLimitTier: tier) {
            return name
        }
        if let type = oauth["subscriptionType"] as? String, !type.isEmpty {
            return type.capitalized
        }
        return nil
    }

    /// Tiers Anthropic names in `rateLimitTier`. Anything unrecognised falls
    /// through to `subscriptionType` rather than being reformatted on a guess.
    static let claudeTierNames: Set<String> = ["free", "pro", "max", "team", "enterprise"]

    /// "default_claude_max_5x" -> "Max (5x)"; "default_claude_pro" -> "Pro".
    ///
    /// Parsed by locating a known tier word rather than by stripping a fixed
    /// "default_claude_" prefix, so a renamed prefix degrades to nil instead of
    /// producing nonsense.
    static func claudePlanName(fromRateLimitTier tier: String) -> String? {
        let parts = tier.lowercased().split(separator: "_").map(String.init)
        guard let index = parts.firstIndex(where: { claudeTierNames.contains($0) }) else { return nil }
        let base = parts[index].capitalized
        let multiplier = parts[(index + 1)...].first {
            $0.count >= 2 && $0.hasSuffix("x") && $0.dropLast().allSatisfy(\.isNumber)
        }
        guard let multiplier else { return base }
        return "\(base) (\(multiplier))"
    }

    /// Logged at most once per process so a user who simply has CLI discovery
    /// off (the default) doesn't get a `frugalbar:` line every two-minute poll,
    /// drowning the actionable lines. A process-lifetime flag, not a per-poll
    /// one: the configuration is static, so past the first poll the same line
    /// would add nothing — the point is to distinguish "discovery disabled"
    /// from "plan genuinely absent" in any single captured log, and one line
    /// does that.
    nonisolated(unsafe) private static var claudePlanDiscoveryDisabledLogged = false

    /// Reads the tier off disk or the Keychain, on the credential queue.
    public static func claudePlanNameAsync() async -> String? {
        guard isCLIDiscoveryEnabled else {
            if !Self.claudePlanDiscoveryDisabledLogged {
                Self.claudePlanDiscoveryDisabledLogged = true
                NSLog("frugalbar: Claude plan-name lookup skipped (CLI credential discovery disabled)")
            }
            return nil
        }
        let allowSecurityCLI = Self.allowsSecurityCLI
        let hook = Self.securityCLISubprocessHook
        return await withCheckedContinuation { continuation in
            credentialQueue.async {
                let name = Self.$allowsSecurityCLI.withValue(allowSecurityCLI) {
                    Self.$securityCLISubprocessHook.withValue(hook) {
                        claudePlanName(from: cachedClaudeBlob())
                    }
                }
                continuation.resume(returning: name)
            }
        }
    }

    /// Extracts the durable GitHub OAuth token from OpenCode's `auth.json`.
    ///
    /// The `github-copilot` entry holds two tokens and they are not
    /// interchangeable: `refresh` is the GitHub OAuth token from the device
    /// flow, and `access` is the short-lived Copilot API token minted from it.
    /// `api.github.com` accepts only the former. Reading `access` is what made
    /// the Copilot row report "Credential rejected" indefinitely.
    static func copilotOAuthToken(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let copilot = json["github-copilot"] as? [String: Any],
              let token = copilot["refresh"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// A still-valid Antigravity access token cached by the `antigravity-usage`
    /// CLI, or nil.
    ///
    /// The Cloud Code API takes a Google OAuth bearer token, and until now the
    /// only way to get one was the Connect Google account button — so a machine
    /// with a perfectly good Antigravity session sitting on disk still reported
    /// "Not configured".
    ///
    /// An expired token is reported as absent rather than refreshed. FrugalBar
    /// now presents the same OAuth client as `antigravity-usage`, so it *could*
    /// redeem that refresh token — but silently renewing a session another tool
    /// owns invites two writers racing over one credential file. Signing in via
    /// Settings mints a session this app owns and renews. Same convention as the
    /// expired-Claude-token path above: expired reads as absent.
    static func antigravityAccessTokenAsync(now: Date = Date()) async -> String? {
        guard isCLIDiscoveryEnabled else { return nil }
        return await withCheckedContinuation { continuation in
            credentialQueue.async {
                continuation.resume(returning: antigravityAccessToken(now: now))
            }
        }
    }

    static func antigravityAccessToken(now: Date = Date()) -> String? {
        antigravityAccessToken(fromTokens: antigravityActiveTokens(), now: now)
    }

    /// The active antigravity-usage session: its live access token and the
    /// Google account its tokens.json records, read from one file so the two
    /// always describe the same session. The email is used only to tell this
    /// Mac's account apart from a proxy's; it is never displayed from here.
    static func antigravitySessionAsync(now: Date = Date()) async -> (accessToken: String, email: String?)? {
        guard isCLIDiscoveryEnabled else { return nil }
        return await withCheckedContinuation { continuation in
            credentialQueue.async {
                continuation.resume(returning: antigravitySession(fromTokens: antigravityActiveTokens(), now: now))
            }
        }
    }

    static func antigravitySession(fromTokens data: Data?, now: Date) -> (accessToken: String, email: String?)? {
        guard let token = antigravityAccessToken(fromTokens: data, now: now) else { return nil }
        let tokens = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (token, tokens?["email"] as? String)
    }

    private static func antigravityActiveTokens() -> Data? {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/antigravity-usage")
        guard let configData = try? Data(contentsOf: root.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let account = config["activeAccount"] as? String, !account.isEmpty
        else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent("accounts/\(account)/tokens.json"))
    }

    /// Parsing half of the above, separated so it can be exercised without
    /// planting files in the tester's real home directory.
    static func antigravityAccessToken(fromTokens data: Data?, now: Date) -> String? {
        guard let data,
              let tokens = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = tokens["accessToken"] as? String, !token.isEmpty
        else { return nil }
        // expiresAt is milliseconds since the epoch.
        guard let expiresAt = tokens["expiresAt"] as? Double,
              Date(timeIntervalSince1970: expiresAt / 1000) > now
        else { return nil }
        return token
    }

    /// The ChatGPT usage endpoint needs the account selected by the Codex
    /// login. This is read only when local credential discovery is enabled.
    static func openAIAccountIDAsync() async -> String? {
        guard isCLIDiscoveryEnabled else { return nil }
        return await withCheckedContinuation { continuation in
            credentialQueue.async {
                let url = CLIConfigLocations.liveCodexRoot(containing: "auth.json")
                    .appendingPathComponent("auth.json")
                let accountID = (try? Data(contentsOf: url))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { $0["tokens"] as? [String: Any] }
                    .flatMap { $0["account_id"] as? String }
                continuation.resume(returning: accountID?.isEmpty == false ? accountID : nil)
            }
        }
    }

    private static let credentialQueue = DispatchQueue(
        label: "com.quotabar.credentials",
        qos: .userInitiated,
        attributes: .concurrent
    )
}

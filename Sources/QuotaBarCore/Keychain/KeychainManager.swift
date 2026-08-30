import Foundation
import Security

// MARK: - Keychain wrapper (macOS Security framework)

public enum KeychainError: Error, Sendable, LocalizedError {
    case unknown(OSStatus)
    case itemNotFound
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unknown(let s): "Keychain error \(s)"
        case .itemNotFound:   "No matching keychain item found"
        case .invalidData:    "Invalid keychain data"
        }
    }
}

public final class KeychainManager: Sendable {

    public static let shared = KeychainManager()
    private let service = "com.quotabar.keys"

    private init() {}

    // MARK: Public API

    public func set(key: String, label: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.invalidData }

        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        label,
            // Never sync a credential to iCloud.
            //
            // NOTE: kSecUseDataProtectionKeychain is deliberately *not* set.
            // It requires a code-signed bundle with an application-identifier
            // entitlement; from `swift run` SecItemAdd returns -34018
            // (errSecMissingEntitlement) and no credential can be stored at
            // all. Add it together with proper .app signing, not before.
            kSecAttrSynchronizable as String: false,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String:          data,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var addQuery = query
        for (k, v) in attributes { addQuery[k] = v }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unknown(updateStatus)
            }
        default:
            throw KeychainError.unknown(addStatus)
        }
    }

    public func get(label: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        label,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.itemNotFound }
            throw KeychainError.unknown(status)
        }

        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return string
    }

    public func delete(label: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
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
    /// Off by default — an unbundled executable has no `Bundle` identity to
    /// request notification authorization under, so delivery goes through an
    /// `osascript`/`display notification` AppleScript call instead of
    /// `UNUserNotificationCenter`, and a banner some users never asked for is
    /// a poor default for that mechanism. Settings exposes this as an
    /// explicit opt-in.
    public static let notificationsEnabledDefaultsKey = "QuotaBarEnableNotifications"

    /// Where FrugalBar's preferences live.
    ///
    /// `UserDefaults.standard` in an *unbundled* executable keys off the
    /// process name, not `CFBundleIdentifier` — `Info.plist` applies only
    /// inside a real `.app`. The released binary installs as `frugalbar` while
    /// the SwiftPM product builds as `QuotaBar`, so the two kept separate
    /// preference files: opting into credential discovery under one name left
    /// the other reporting every provider as "Not configured", with no visible
    /// cause. Pinning the suite makes both names — and a bundled `.app`, whose
    /// standard domain already *is* this string — share one store.
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

    public static var isCLIDiscoveryEnabled: Bool {
        preferences.bool(forKey: cliDiscoveryDefaultsKey)
    }

    public static var isNotificationsEnabled: Bool {
        preferences.bool(forKey: notificationsEnabledDefaultsKey)
    }

    /// Returns the API key for a vendor: Keychain first, then — only when the
    /// user has opted in — known CLI config locations.
    public static func apiKey(for vendor: VendorIdentifier) -> String? {
        if let kc = try? KeychainManager.shared.get(label: vendor.rawValue), !kc.isEmpty {
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
        task.standardError = Pipe()   // don't inherit stderr into the app's log
        task.standardInput = FileHandle.nullDevice

        // `run()` throws when the binary cannot be launched. The previous code
        // used `try?` and then read `terminationStatus` regardless — which
        // raises an uncatchable NSException on an unlaunched Process.
        do {
            try task.run()
        } catch {
            return nil
        }

        // Read before waiting: waiting first can deadlock if the child fills
        // the pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        
        // Kill the process if it hasn't exited within 5 seconds.
        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) { [task] in
            if task.isRunning { task.terminate() }
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }

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
    actor CredentialCache {
        static let shared = CredentialCache()

        /// Long enough to cover one polling cycle's fan-out across providers;
        /// short enough that a token rotated via `gh auth login` mid-session is
        /// picked up well within the same session.
        static let ghTokenTTL: TimeInterval = 30

        private var ghTokenCache: (token: String?, expires: Date)?

        func ghToken(now: Date, resolve: () -> String?) -> String? {
            if let cached = ghTokenCache, cached.expires > now {
                return cached.token
            }
            let token = resolve()
            ghTokenCache = (token, now.addingTimeInterval(Self.ghTokenTTL))
            return token
        }
    }

    /// Synchronous bridge into `CredentialCache` for `discoverFromCLI`'s
    /// non-async call sites.
    ///
    /// Blocking here is safe: every caller reaches `discoverFromCLI` by way of
    /// `credentialQueue`, a plain concurrent `DispatchQueue`, never from the
    /// cooperative thread pool that the `Task` below draws its own thread from.
    static func cachedGhAuthToken(now: Date = Date()) -> String? {
        // A plain `var` capture across the `Task` boundary is flagged under
        // strict concurrency even though the semaphore fully serialises the
        // write (inside the task) before the read (after `wait()`); boxing it
        // in an `@unchecked Sendable` class documents that hand-proved
        // ordering to the compiler instead of suppressing the check.
        final class ResultBox: @unchecked Sendable {
            var value: String?
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = await CredentialCache.shared.ghToken(now: now) { runGhAuthToken() }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
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

        case .gemini:
            // Deliberately nothing. The Gemini provider reads Antigravity
            // subscription quota from the Cloud Code API, which takes a Google
            // OAuth bearer token — see the Connect Google account button in
            // Settings. Handing it a GEMINI_API_KEY (an AI Studio key for a
            // different product) would only ever produce a 401 that looks like
            // the user typed their key wrong.
            return nil

        case .openai:
            let url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".codex/auth.json")
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
            // disk; ~/.claude/.credentials.json is the Linux (and older
            // install) location. Reading another app's Keychain item prompts
            // the user for consent the first time, which is the right gate for
            // a credential they did not type into us.
            let fileURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/.credentials.json")
            return claudeOAuthToken(from: claudeCodeKeychainBlob())
                ?? claudeOAuthToken(from: try? Data(contentsOf: fileURL))

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
        }
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
        await withCheckedContinuation { continuation in
            credentialQueue.async {
                continuation.resume(returning: apiKey(for: vendor))
            }
        }
    }

    /// The credential blob the Claude Code CLI writes to the macOS login
    /// Keychain. It lives under a different service name than our own items,
    /// so `KeychainManager` — scoped to `com.quotabar.keys` — cannot serve it.
    private static func claudeCodeKeychainBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
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
        case .gemini:        "Google OAuth session"
        case .opencode:      "OpenCode auth.json"
        case .copilot:       "OpenCode auth.json"
        case .openrouter:    "OpenCode auth.json"
        case .githubRest:    "gh auth token"
        case .githubGraphql: "gh auth token"
        }
    }

    /// Resolves provenance off the main thread — `discoverFromCLI` can shell
    /// out to `gh`, which has no business running during a view update.
    public static func credentialSourceAsync(for vendor: VendorIdentifier) async -> CredentialSource {
        await withCheckedContinuation { continuation in
            credentialQueue.async {
                if let stored = try? KeychainManager.shared.get(label: vendor.rawValue),
                   !stored.isEmpty {
                    continuation.resume(returning: .keychain)
                    return
                }
                guard isCLIDiscoveryEnabled,
                      let found = discoverFromCLI(vendor: vendor), !found.isEmpty
                else {
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
    /// Anthropic's rate-limit headers carry usage but not the plan, so this is
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

    /// Reads the tier off disk or the Keychain, on the credential queue.
    public static func claudePlanNameAsync() async -> String? {
        guard isCLIDiscoveryEnabled else { return nil }
        return await withCheckedContinuation { continuation in
            credentialQueue.async {
                let fileURL = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(".claude/.credentials.json")
                let name = claudePlanName(from: claudeCodeKeychainBlob())
                    ?? claudePlanName(from: try? Data(contentsOf: fileURL))
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
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/antigravity-usage")
        guard let configData = try? Data(contentsOf: root.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let account = config["activeAccount"] as? String, !account.isEmpty
        else { return nil }
        let tokenData = try? Data(contentsOf: root
            .appendingPathComponent("accounts/\(account)/tokens.json"))
        return antigravityAccessToken(fromTokens: tokenData, now: now)
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
                let url = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(".codex/auth.json")
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

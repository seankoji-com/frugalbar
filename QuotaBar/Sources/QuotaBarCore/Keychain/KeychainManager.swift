import Foundation
import Security

// MARK: - Keychain wrapper (macOS Security framework)

public enum KeychainError: Error, Sendable, LocalizedError {
    case duplicateEntry
    case unknown(OSStatus)
    case itemNotFound
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .duplicateEntry: "Keychain entry already exists"
        case .unknown(let s): "Keychain error \(s)"
        case .itemNotFound:   "No matching keychain item found"
        case .invalidData:    "Invalid keychain data"
        }
    }
}

public actor KeychainManager {

    public static let shared = KeychainManager()
    private let service = "com.quotabar.keys"

    private init() {}

    // MARK: Public API

    public func set(key: String, label: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.invalidData }

        // Delete existing first
        try? delete(label: label)

        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        label,
            kSecValueData as String:          data,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }

    public func get(label: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        label,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
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
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }
}

// MARK: - Credential store (reads from keychain + CLI config files)

public enum CredentialStore {

    /// Returns the API key for a given vendor label, checking Keychain and known file paths.
    public static func apiKey(for vendor: VendorIdentifier) -> String? {
        // Try keychain first
        if let kc = try? KeychainManager.shared.get(label: vendor.rawValue), !kc.isEmpty {
            return kc
        }
        // Fallback: discover from known CLI configs
        return discoverFromCLI(vendor: vendor)
    }

    private static func discoverFromCLI(vendor: VendorIdentifier) -> String? {
        switch vendor {
        case .githubRest, .githubGraphql:
            // gh auth token
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["gh", "auth", "token"]
            let out = Pipe()
            task.standardOutput = out
            try? task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return token?.isEmpty == false ? token : nil

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
            if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
                return env
            }
            let url = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode/auth.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let g = json["google"] as? [String: Any],
                  let key = g["key"] as? String
            else { return nil }
            return key

        case .claude:
            // ~/.claude.json — holds OAuth session but no raw API key in typical cases.
            // In practice Claude Desktop manages its own OAuth.
            return nil

        case .copilot:
            // gh auth token is used for Copilot as well
            return Self.apiKey(for: .githubRest)
        }
    }
}

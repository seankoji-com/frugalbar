import Testing
import Foundation
@testable import QuotaBarCore

@Suite("CLIProxyClient tests", .serialized)
struct CLIProxyClientTests {

    @Test("base64url replaces + and / and strips =")
    func base64urlEncoding() {
        #expect(CLIProxyClient.base64url(string: "cliproxy-nas.careynas.net-8317") == "Y2xpcHJveHktbmFzLmNhcmV5bmFzLm5ldC04MzE3")
        // Check padding stripping and URL-safe characters (_ for /, - for +)
        #expect(CLIProxyClient.base64url(string: "hello?world>>") == "aGVsbG8_d29ybGQ-Pg")
        #expect(!CLIProxyClient.base64url(string: "any test string ===").contains("="))
        #expect(!CLIProxyClient.base64url(string: "???///+++").contains("+"))
        #expect(!CLIProxyClient.base64url(string: "???///+++").contains("/"))
    }

    @Test("parseResetDate parses ISO 8601 with fractional seconds and standard format")
    func parseResetDate() {
        let withFractional = CLIProxyClient.parseResetDate("2026-09-15T06:59:59.000000+00:00")
        #expect(withFractional != nil)
        #expect(withFractional?.timeIntervalSince1970 == 1789455599)

        let standardZ = CLIProxyClient.parseResetDate("2026-09-15T06:59:59Z")
        #expect(standardZ != nil)
        #expect(standardZ?.timeIntervalSince1970 == 1789455599)

        #expect(CLIProxyClient.parseResetDate(nil) == nil)
        #expect(CLIProxyClient.parseResetDate("") == nil)
        #expect(CLIProxyClient.parseResetDate("not a date") == nil)
    }

    @Test("managementURL builds clean /v0/management paths from various base URLs")
    func managementURLBuilding() throws {
        let base1 = try #require(URL(string: "http://nas.careynas.net:8317"))
        #expect(CLIProxyClient.managementURL(path: "auth-files", base: base1) == "http://nas.careynas.net:8317/v0/management/auth-files")
        #expect(CLIProxyClient.managementURL(path: "/api-call", base: base1) == "http://nas.careynas.net:8317/v0/management/api-call")

        let base2 = try #require(URL(string: "http://nas.careynas.net:8317/"))
        #expect(CLIProxyClient.managementURL(path: "auth-files", base: base2) == "http://nas.careynas.net:8317/v0/management/auth-files")

        let base3 = try #require(URL(string: "http://nas.careynas.net:8317/v1"))
        #expect(CLIProxyClient.managementURL(path: "auth-files", base: base3) == "http://nas.careynas.net:8317/v0/management/auth-files")
    }

    @Test("discoverConfig reads from environment variables when present")
    func discoverConfigFromEnvironment() {
        let env = [
            "CLIPROXY_URL": "http://env-proxy.local:8317",
            "CLIPROXY_API_KEY": "env-secret-key"
        ]
        let config = CLIProxyClient.discoverConfig(environment: env, isCLIDiscoveryEnabled: true, isTestHost: false)
        #expect(config != nil)
        #expect(config?.url.absoluteString == "http://env-proxy.local:8317")
        #expect(config?.managementKey == "env-secret-key")
        #expect(config?.label == "Environment")
    }

    @Test("discoverConfig respects isCLIDiscoveryEnabled flag")
    func discoverConfigRespectsCLIDiscoveryFlag() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let settingsContent = #"""
        {
          "usageLimitSources": {
            "cliproxy-test": {
              "kind": "cliproxy",
              "label": "Test Proxy",
              "url": "http://hub.test:8317",
              "managementKey": "unredacted-key",
              "enabled": true
            }
          }
        }
        """#
        try settingsContent.write(to: settingsURL, atomically: true, encoding: .utf8)

        // When discovery is disabled, returns nil
        let disabled = CLIProxyClient.discoverConfig(
            settingsURL: settingsURL,
            secretsDir: tempDir,
            environment: [:],
            isCLIDiscoveryEnabled: false,
            isTestHost: false
        )
        #expect(disabled == nil)

        // When discovery is enabled, returns config
        let enabled = CLIProxyClient.discoverConfig(
            settingsURL: settingsURL,
            secretsDir: tempDir,
            environment: [:],
            isCLIDiscoveryEnabled: true,
            isTestHost: false
        )
        #expect(enabled != nil)
        #expect(enabled?.url.absoluteString == "http://hub.test:8317")
        #expect(enabled?.managementKey == "unredacted-key")
        #expect(enabled?.label == "Test Proxy")
    }

    @Test("discoverConfig resolves redacted secret from secrets directory")
    func discoverConfigResolvesRedactedSecret() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secretsDir = tempDir.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceId = "cliproxy-hub"
        let secretFileName = "usage-limit-source-\(CLIProxyClient.base64url(string: sourceId)).bin"
        let secretFileURL = secretsDir.appendingPathComponent(secretFileName)
        try "secret-from-bin-file\n".write(to: secretFileURL, atomically: true, encoding: .utf8)

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let settingsContent = """
        {
          "usageLimitSources": {
            "\(sourceId)": {
              "kind": "cliproxy",
              "label": "Hub",
              "url": "http://hub.test:8317",
              "managementKey": "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}",
              "enabled": true
            }
          }
        }
        """
        try settingsContent.write(to: settingsURL, atomically: true, encoding: .utf8)

        let config = CLIProxyClient.discoverConfig(
            settingsURL: settingsURL,
            secretsDir: secretsDir,
            environment: [:],
            isCLIDiscoveryEnabled: true,
            isTestHost: false
        )
        #expect(config != nil)
        #expect(config?.managementKey == "secret-from-bin-file")
    }

    @Test("discoverConfig returns nil under isTestHost without explicit settingsURL")
    func discoverConfigSkipsAmbientInTestHost() {
        let config = CLIProxyClient.discoverConfig(
            settingsURL: nil,
            secretsDir: nil,
            environment: [:],
            isCLIDiscoveryEnabled: true,
            isTestHost: true
        )
        #expect(config == nil)
    }

    @Test("decodeAuthFiles handles both wrapper object and direct array")
    func decodeAuthFilesShapes() throws {
        let directArray = #"""
        [{"id":"1","auth_index":"idx1","provider":"claude","email":"test@example.com","disabled":false}]
        """#
        let files1 = try CLIProxyClient.decodeAuthFiles(from: Data(directArray.utf8))
        #expect(files1.count == 1)
        #expect(files1[0].authIndex == "idx1")
        #expect(files1[0].provider == "claude")

        let wrapped = #"""
        {"files":[{"id":"2","auth_index":"idx2","provider":"codex","disabled":true}]}
        """#
        let files2 = try CLIProxyClient.decodeAuthFiles(from: Data(wrapped.utf8))
        #expect(files2.count == 1)
        #expect(files2[0].authIndex == "idx2")
        #expect(files2[0].disabled == true)
    }

    @Test("decodeClaudeUsage decodes API-call wrapper body string and raw JSON")
    func decodeClaudeUsageShapes() throws {
        let wrapped = #"""
        {
          "status_code": 200,
          "body": "{\"five_hour\":{\"utilization\":0.85,\"resets_at\":\"2026-09-15T06:59:59Z\"},\"seven_day\":{\"utilization\":0.40,\"resets_at\":\"2026-09-19T00:00:00Z\"}}"
        }
        """#
        let usage1 = try CLIProxyClient.decodeClaudeUsage(from: Data(wrapped.utf8))
        #expect(usage1.fiveHour?.utilization == 0.85)
        #expect(usage1.sevenDay?.utilization == 0.40)
        #expect(usage1.fiveHour?.resetsAt == "2026-09-15T06:59:59Z")

        let raw = #"""
        {
          "five_hour": {"utilization": 0.50, "resets_at": "2026-09-15T06:59:59Z"}
        }
        """#
        let usage2 = try CLIProxyClient.decodeClaudeUsage(from: Data(raw.utf8))
        #expect(usage2.fiveHour?.utilization == 0.50)
        #expect(usage2.sevenDay == nil)
    }

    @Test("decodeClaudeUsage rejects error status in wrapper")
    func decodeClaudeUsageErrorStatus() {
        let rejected = #"""
        {"status_code": 401, "body": "unauthorized"}
        """#
        #expect(throws: ProviderError.self) {
            try CLIProxyClient.decodeClaudeUsage(from: Data(rejected.utf8))
        }
    }

    @Test("decodeCodexUsage decodes API-call wrapper body string and raw JSON")
    func decodeCodexUsageShapes() throws {
        let wrapped = #"""
        {
          "status_code": 200,
          "body": "{\"plan_type\":\"pro\",\"rate_limit\":{\"primary_window\":{\"used_percent\":45.0,\"reset_at\":1789455599,\"limit_window_seconds\":18000},\"secondary_window\":{\"used_percent\":80.0,\"reset_at\":1789800000,\"limit_window_seconds\":604800}}}"
        }
        """#
        let usage1 = try CLIProxyClient.decodeCodexUsage(from: Data(wrapped.utf8))
        #expect(usage1.plan_type == "pro")
        #expect(usage1.rate_limit?.primary_window?.used_percent == 45.0)
        #expect(usage1.rate_limit?.primary_window?.limit_window_seconds == 18000)
        #expect(usage1.rate_limit?.secondary_window?.used_percent == 80.0)

        let raw = #"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12.5,
              "reset_at": 1789455599,
              "limit_window_seconds": 18000
            }
          }
        }
        """#
        let usage2 = try CLIProxyClient.decodeCodexUsage(from: Data(raw.utf8))
        #expect(usage2.plan_type == "plus")
        #expect(usage2.rate_limit?.primary_window?.used_percent == 12.5)
        #expect(usage2.rate_limit?.secondary_window == nil)
    }

    @Test("decodeCodexUsage rejects error status in wrapper")
    func decodeCodexUsageErrorStatus() {
        let rejected = #"""
        {"status_code": 403, "body": "forbidden"}
        """#
        #expect(throws: ProviderError.self) {
            try CLIProxyClient.decodeCodexUsage(from: Data(rejected.utf8))
        }
    }
}

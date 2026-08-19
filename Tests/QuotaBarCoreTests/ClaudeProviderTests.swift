import Testing
import Foundation
@testable import QuotaBarCore

@Suite("ClaudeProvider — Quota and Telemetry Parsing", .serialized)
struct ClaudeProviderTests {

    @Test("Claude without key returns notConfigured without network calls")
    func claudeNoKeyReturnsNotConfigured() async throws {
        let provider = ClaudeQuotaProvider(apiKey: "")
        let snapshot = try await provider.fetchSnapshot()
        #expect(snapshot.status == .unavailable(.notConfigured))
        #expect(snapshot.vendorId == .claude)
    }

    @Test("Claude with key detects tier correctly")
    func claudeTierDetection() async throws {
        let proProvider = ClaudeQuotaProvider(apiKey: "sk-ant-api03-pro-key")
        let proSnapshot = try await proProvider.fetchSnapshot()
        #expect(proSnapshot.planName?.contains("Claude Pro") == true)

        let teamProvider = ClaudeQuotaProvider(apiKey: "sk-ant-api03-team-key")
        let teamSnapshot = try await teamProvider.fetchSnapshot()
        #expect(teamSnapshot.planName?.contains("Claude Team") == true)
    }

    @Test("Claude parses live organization and usage payload with stubbed HTTP")
    func claudeLiveTelemetryParsing() async throws {
        let orgJSON = """
        [
            {"uuid": "org-12345", "name": "Anthropic Org"}
        ]
        """.data(using: .utf8)!

        let usageJSON = """
        {
            "five_hour": {
                "utilization": 0.42,
                "resets_at": "2026-08-19T20:00:00Z"
            },
            "seven_day": {
                "utilization": 0.88,
                "resets_at": "2026-08-23T09:00:00Z"
            }
        }
        """.data(using: .utf8)!

        let snapshot = try await withSharedStubbedHTTP({ request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/organizations/") && urlStr.contains("/usage") {
                return SharedURLProtocolStub.StubResponse(status: 200, headers: [:], body: usageJSON)
            } else if urlStr.contains("/organizations") {
                return SharedURLProtocolStub.StubResponse(status: 200, headers: [:], body: orgJSON)
            }
            return SharedURLProtocolStub.StubResponse(status: 404, headers: [:], body: Data())
        }) {
            let provider = ClaudeQuotaProvider(apiKey: "sk-ant-sid01-test-session-cookie")
            return try await provider.fetchSnapshot()
        }

        #expect(snapshot.vendorId == .claude)
        #expect(snapshot.row1?.primaryFraction == 0.42)
        #expect(snapshot.row2?.primaryFraction == 0.88)
        #expect(snapshot.status == .critical)
    }
}

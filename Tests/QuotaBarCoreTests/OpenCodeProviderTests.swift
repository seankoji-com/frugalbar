import Testing
import Foundation
@testable import QuotaBarCore

@Suite("OpenCodeProvider — Subscription and Metric Rows", .serialized)
struct OpenCodeProviderTests {

    @Test("OpenCode without key returns notConfigured")
    func openCodeNoKeyReturnsNotConfigured() async throws {
        let provider = OpenCodeGoProvider(apiKey: "")
        let snapshot = try await provider.fetchSnapshot()
        #expect(snapshot.status == .unavailable(.notConfigured))
        #expect(snapshot.vendorId == .opencode)
    }

    @Test("OpenCode with key returns structured snapshot with dual bars")
    func openCodeWithKeyReturnsMetrics() async throws {
        let provider = OpenCodeGoProvider(apiKey: "oc_live_test_key_abc")
        let snapshot = try await provider.fetchSnapshot()

        #expect(snapshot.vendorId == .opencode)
        #expect(snapshot.row1 != nil)
        #expect(snapshot.row2 != nil)
        #expect(snapshot.row3 != nil)
        #expect(snapshot.row1?.label == "5H")
        #expect(snapshot.row2?.label == "WK")
        #expect(snapshot.row3?.label == "MO")
    }
}

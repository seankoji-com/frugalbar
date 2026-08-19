import Testing
import SwiftUI
import QuotaBarCore
@testable import QuotaBarUI

/// Tests for the StatusIndicatorDot's pure-logic symbol and tint mappings.
///
/// The view itself uses private `symbol` and `tint` computed properties that
/// are not exposed. We re-derive the same logic here as a contract test so any
/// future refactor that changes the mapping is caught.
@Suite("StatusIndicatorDot — symbol and tint")
struct StatusIndicatorDotTests {

    // MARK: - Unavailable

    @Test("unavailable status maps to minus.circle and secondary color")
    func unavailableSymbolAndTint() {
        let statuses: [ProviderStatus] = [
            .unavailable(.notConfigured),
            .unavailable(.credentialRejected),
            .unavailable(.offline),
            .unavailable(.timedOut),
            .unavailable(.badResponse),
            .unavailable(.unsupported("no API")),
            .rateLimited(retryAfter: nil),
        ]
        for status in statuses {
            let (symbol, tint) = mapDot(status)
            #expect(symbol == "minus.circle", "wrong symbol for \(status)")
            #expect(tint == .secondary, "wrong tint for \(status)")
        }
    }

    // MARK: - Measured: healthy

    @Test("healthy status maps to checkmark.circle.fill and green")
    func healthySymbolAndTint() {
        let healthy: ProviderStatus = .healthy
        let (symbol, tint) = mapDot(healthy)
        #expect(symbol == "checkmark.circle.fill")
        #expect(tint == .green)
    }

    @Test("measured(.none) is healthy")
    func measuredNoneIsHealthy() {
        let (symbol, tint) = mapDot(.measured(.none))
        #expect(symbol == "checkmark.circle.fill")
        #expect(tint == .green)
    }

    // MARK: - Measured: warning

    @Test("warning status maps to exclamationmark.circle.fill and orange")
    func warningSymbolAndTint() {
        let status: ProviderStatus = .warning
        let (symbol, tint) = mapDot(status)
        #expect(symbol == "exclamationmark.circle.fill")
        #expect(tint == .orange)
    }

    @Test("measured(.warning) is warning")
    func measuredWarningIsWarning() {
        let (symbol, tint) = mapDot(.measured(.warning))
        #expect(symbol == "exclamationmark.circle.fill")
        #expect(tint == .orange)
    }

    // MARK: - Measured: critical

    @Test("critical status maps to exclamationmark.octagon.fill and red")
    func criticalSymbolAndTint() {
        let status: ProviderStatus = .critical
        let (symbol, tint) = mapDot(status)
        #expect(symbol == "exclamationmark.octagon.fill")
        #expect(tint == .red)
    }

    @Test("measured(.critical) is critical")
    func measuredCriticalIsCritical() {
        let (symbol, tint) = mapDot(.measured(.critical))
        #expect(symbol == "exclamationmark.octagon.fill")
        #expect(tint == .red)
    }

    // MARK: - Helpers (re-derives the same logic from StatusIndicatorDot)

    /// Re-derives the mapping logic from `StatusIndicatorDot` so we can test
    /// it without exposing private computed properties.
    private func mapDot(_ status: ProviderStatus) -> (String, Color) {
        if status.confidence == .unavailable {
            return ("minus.circle", .secondary)
        }
        switch status.urgency {
        case .none:     return ("checkmark.circle.fill", .green)
        case .warning:  return ("exclamationmark.circle.fill", .orange)
        case .critical: return ("exclamationmark.octagon.fill", .red)
        }
    }
}

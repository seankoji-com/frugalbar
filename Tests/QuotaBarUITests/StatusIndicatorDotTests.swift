import Testing
import SwiftUI
import QuotaBarCore
@testable import QuotaBarUI

/// Tests for the StatusIndicatorDot's pure-logic symbol and tint mappings.
///
/// These call `StatusIndicatorDot.symbol(for:)` / `.tint(for:)` directly —
/// the same production statics the view's body renders — so a future
/// refactor that changes the mapping is caught here rather than only in a
/// re-derived copy that could silently drift from the real logic.
@Suite("StatusIndicatorDot — symbol and tint")
struct StatusIndicatorDotTests {

    // MARK: - Unavailable

    @Test("unavailable status maps to minus.circle and outline color")
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
            #expect(StatusIndicatorDot.symbol(for: status) == "minus.circle", "wrong symbol for \(status)")
            #expect(StatusIndicatorDot.tint(for: status) == Theme.outline, "wrong tint for \(status)")
        }
    }

    // MARK: - Measured: healthy

    @Test("healthy status maps to checkmark.circle.fill and Theme.secondary")
    func healthySymbolAndTint() {
        let healthy: ProviderStatus = .healthy
        #expect(StatusIndicatorDot.symbol(for: healthy) == "checkmark.circle.fill")
        #expect(StatusIndicatorDot.tint(for: healthy) == Theme.secondary)
    }

    @Test("measured(.none) is healthy")
    func measuredNoneIsHealthy() {
        let status: ProviderStatus = .measured(.none)
        #expect(StatusIndicatorDot.symbol(for: status) == "checkmark.circle.fill")
        #expect(StatusIndicatorDot.tint(for: status) == Theme.secondary)
    }

    // MARK: - Measured: warning

    @Test("warning status maps to exclamationmark.circle.fill and Theme.tertiary")
    func warningSymbolAndTint() {
        let status: ProviderStatus = .warning
        #expect(StatusIndicatorDot.symbol(for: status) == "exclamationmark.circle.fill")
        #expect(StatusIndicatorDot.tint(for: status) == Theme.tertiary)
    }

    @Test("measured(.warning) is warning")
    func measuredWarningIsWarning() {
        let status: ProviderStatus = .measured(.warning)
        #expect(StatusIndicatorDot.symbol(for: status) == "exclamationmark.circle.fill")
        #expect(StatusIndicatorDot.tint(for: status) == Theme.tertiary)
    }

    // MARK: - Measured: critical

    @Test("critical status maps to exclamationmark.octagon.fill and Theme.error")
    func criticalSymbolAndTint() {
        let status: ProviderStatus = .critical
        #expect(StatusIndicatorDot.symbol(for: status) == "exclamationmark.octagon.fill")
        #expect(StatusIndicatorDot.tint(for: status) == Theme.error)
    }

    @Test("measured(.critical) is critical")
    func measuredCriticalIsCritical() {
        let status: ProviderStatus = .measured(.critical)
        #expect(StatusIndicatorDot.symbol(for: status) == "exclamationmark.octagon.fill")
        #expect(StatusIndicatorDot.tint(for: status) == Theme.error)
    }
}

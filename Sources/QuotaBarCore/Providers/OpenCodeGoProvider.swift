import Foundation

/// OpenCode Go subscription usage.
///
/// `GET /zen/go/v1/usage`, authenticated with the `opencode-go` API key from
/// the Keychain or the CLI config (`~/.local/share/opencode/auth.json`).
///
/// The previous implementation read `~/.local/share/opencode/usage.json` — a
/// file OpenCode does not write. It could only ever report "No usage API",
/// which then let the advice engine treat an exhausted subscription as
/// unmeasured headroom.
public final class OpenCodeGoProvider: QuotaProvider, Sendable {

    public let vendorId: VendorIdentifier = .opencode
    public var displayName: String { vendorId.displayName }
    public let category: MetricCategory = .aiSubscriptions

    private let apiKey: String?

    public init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    /// One window as OpenCode reports it:
    /// `{"status":"ok","percent":0,"resetsAt":"2026-08-22T14:39:10.189Z"}`.
    struct Window: Decodable, Sendable {
        let status: String?
        let percent: Double?
        let resetsAt: String?

        /// `percent` is 0…100 — the monthly window reads 100 when spent.
        var fraction: Double? {
            guard let percent, percent.isFinite else { return nil }
            return min(max(percent / 100, 0), 1)
        }

        /// OpenCode says outright when a window is blocking, which is a better
        /// signal than inferring it from a rounded percentage.
        var isBlocked: Bool { status == "rate-limited" }

        var reset: Date? { resetsAt.flatMap(OpenCodeGoProvider.parseDate) }
    }

    struct Response: Decodable, Sendable {
        struct Usage: Decodable, Sendable {
            let rolling: Window?
            let weekly: Window?
            let monthly: Window?
        }
        let usage: Usage?
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        guard let key = await credential(injected: apiKey, for: .opencode) else {
            return unavailable(.notConfigured)
        }

        let (data, http) = try await QuotaHTTP.get(
            url: "https://opencode.ai/zen/go/v1/usage",
            headers: ["Accept": "application/json"],
            auth: .bearer(key)
        )
        if let reason = QuotaHTTP.failureReason(for: http.statusCode) { return unavailable(reason) }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let usage = response.usage
        else { return unavailable(.badResponse) }

        let windows = [usage.rolling, usage.weekly, usage.monthly]
        // A structurally valid response carrying no window is "OpenCode
        // published nothing", not a malformed payload.
        let measured = windows.compactMap { $0?.fraction }
        guard let worst = measured.max() else {
            return unavailable(.unsupported("OpenCode reported no usage window"))
        }

        // A blocked window cannot be used at all, whatever its percentage
        // rounds to. Otherwise the fullest window sets the pressure.
        let urgency: Urgency = windows.contains(where: { $0?.isBlocked == true }) || worst >= 0.95
            ? .critical
            : worst >= 0.80 ? .warning : .none

        let now = Date()
        return QuotaSnapshot(
            id: vendorId.rawValue,
            vendorId: vendorId,
            displayName: displayName,
            category: category,
            metric: .subscription(tierName: "Go", renewalDate: nil),
            status: .measured(urgency),
            resetsAt: usage.rolling?.reset ?? usage.weekly?.reset ?? usage.monthly?.reset,
            lastUpdated: now,
            auxiliaryInfo: "Live OpenCode Go subscription quota",
            // The endpoint sends a reset time but no window length. "weekly"
            // and "monthly" name their own; the rolling window is five hours —
            // stated by the operator and corroborated by its reset time landing
            // ~5h out on a fresh window.
            row1: Self.row(usage.rolling, "5H", length: QuotaWindow.fiveHours, now: now),
            row2: Self.row(usage.weekly, "WK", length: QuotaWindow.week, now: now),
            row3: Self.row(usage.monthly, "MO", length: nil, monthly: true, now: now),
            badgeText: worst >= 1.0 ? "Exhausted" : "\(Int(((1 - worst) * 100).rounded()))% left",
            planName: "OpenCode Go",
            keyMasked: nil,
            cliSource: "macOS Keychain / auth.json"
        )
    }

    private static func row(
        _ window: Window?,
        _ label: String,
        length: TimeInterval?,
        monthly: Bool = false,
        now: Date
    ) -> DualBarMetrics? {
        // A window with neither a percentage nor a blocked flag has nothing
        // to draw — that stays an omitted row. A blocked window still gets a
        // row even with no percentage, so it renders as a placeholder rather
        // than disappearing (see DualBarProgressView.isBlockedWithoutReading).
        guard let window, window.fraction != nil || window.isBlocked else { return nil }
        let fraction = window.fraction
        let reset = window.reset
        let windowLength = length ?? (monthly ? reset.flatMap(DualBarMetrics.monthWindowLength(endingAt:)) : nil)
        let usedText: String = fraction.map { "\(Int(($0 * 100).rounded()))% used\(window.isBlocked ? " • blocked" : "")" }
            ?? "Blocked • no reading reported"
        return DualBarMetrics(
            primaryFraction: fraction,
            expectedPaceFraction: windowLength.flatMap {
                DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now)
            },
            label: label,
            // Only read by the view when `isBlocked` is true, so the
            // non-blocked case is left `nil` rather than a colour that can
            // never render.
            blockedColor: window.isBlocked ? "#ffb4ab" : nil,
            isBlocked: window.isBlocked,
            usedText: usedText,
            resetText: reset.map { "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))" },
            resetsAt: reset, windowLength: windowLength
        )
    }

    /// `resetsAt` carries fractional seconds, which the plain ISO8601 parser
    /// rejects outright.
    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

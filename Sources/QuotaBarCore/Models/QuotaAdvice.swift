import Foundation

/// Intelligent advice and routing recommendation.
public struct QuotaAdvice: Sendable, Equatable {
    public let headline: String
    public let message: String
    public let suggestedAction: String?
    public let urgency: Urgency
    public let iconName: String
    public let iconColorHex: String
    public let vendorId: VendorIdentifier?

    public init(
        headline: String,
        message: String,
        suggestedAction: String? = nil,
        urgency: Urgency = .none,
        iconName: String = "sparkles",
        iconColorHex: String = "#53e16f",
        vendorId: VendorIdentifier? = nil
    ) {
        self.headline = headline
        self.message = message
        self.suggestedAction = suggestedAction
        self.urgency = urgency
        self.iconName = iconName
        self.iconColorHex = iconColorHex
        self.vendorId = vendorId
    }

    // MARK: - Candidates

    /// One subscription we actually have a reading for.
    ///
    /// The engine is built from these rather than from named vendors. The
    /// previous version hard-coded Claude and Gemini, so OpenAI and Copilot
    /// could be at 100% without changing a word of the advice, and every
    /// `?? 0.0` default let an *unreadable* provider stand in as an empty one.
    private struct Candidate {
        let vendorId: VendorIdentifier
        let name: String
        /// 0…1 consumed in the fullest window — the binding constraint.
        let used: Double
        /// The window that is fullest, for naming the constraint.
        let bar: DualBarMetrics?
        let isCritical: Bool

        /// The provider's own verdict counts, but it never rewrites `used`:
        /// the percentage we print is always the one the vendor published.
        var isConstrained: Bool { used >= 0.80 || isCritical }
        var hasHeadroom: Bool { used < 0.70 && !isCritical }

        /// Allowance still worth spending, in a window that is nearly over.
        ///
        /// A paid-for subscription window does not roll over, so unspent
        /// allowance in its final stretch is about to be lost — and burning it
        /// is free, where OpenRouter credit is not. The "nearly over" test is
        /// the window's own measured pace, so it scales itself: the last ~75
        /// minutes of a 5-hour window, the last ~1.7 days of a weekly one.
        var isExpiringUnspent: Bool {
            guard used < Self.worthSpending, let pace = bar?.expectedPaceFraction else { return false }
            return pace >= Self.windowNearlyOver
        }

        /// Below this much consumed there is a slice worth routing work to.
        static let worthSpending = 0.95
        static let windowNearlyOver = 0.75
    }

    private static func candidates(from snapshots: [QuotaSnapshot]) -> [Candidate] {
        snapshots.compactMap { snapshot -> Candidate? in
            guard snapshot.category == .aiSubscriptions,
                  snapshot.status.confidence == .measured
            else { return nil }
            let worstBar = snapshot.bars.max { $0.primaryFraction < $1.primaryFraction }
            // No bar and no denominator means no reading to reason about. A
            // provider we cannot measure must not be presented as an option.
            guard let used = worstBar?.primaryFraction ?? snapshot.consumptionFraction else { return nil }
            return Candidate(
                vendorId: snapshot.vendorId,
                name: snapshot.shortVendorName,
                used: used,
                bar: worstBar,
                isCritical: snapshot.status.urgency == .critical
            )
        }
    }

    /// "Claude 5H at 80% (resets in 42m)" — or "… exhausted" once it is spent.
    private static func constraintText(_ candidate: Candidate) -> String {
        let percent = Int((candidate.used * 100).rounded())
        let label = candidate.bar.map { " \($0.label)" } ?? ""
        let reset = cleanResetString(candidate.bar?.resetText).map { " (resets in \($0))" } ?? ""
        if candidate.used >= 0.995 {
            return "\(candidate.name)\(label) exhausted\(reset)"
        }
        return "\(candidate.name)\(label) at \(percent)%\(reset)"
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) & \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")) & \(items.last!)"
        }
    }

    // MARK: - Evaluation

    /// Evaluates current snapshots and produces dynamic, actionable advice.
    public static func evaluate(from snapshots: [QuotaSnapshot], now: Date = Date()) -> QuotaAdvice {
        guard !snapshots.isEmpty else {
            return QuotaAdvice(
                headline: "Connecting to Providers",
                message: "Fetching initial quota readings and rate limits…",
                suggestedAction: "Refreshing…",
                urgency: .none,
                iconName: "antenna.radiowaves.left.and.right",
                iconColorHex: "#adc6ff"
            )
        }

        // 0. SCENARIO: nothing was readable at all.
        //
        // This used to fall through to "All Quotas Healthy" — the summary
        // asserted headroom for providers it had never once read.
        guard snapshots.contains(where: { $0.status.confidence == .measured }) else {
            return QuotaAdvice(
                headline: "No Quota Readings",
                message: "None of the \(snapshots.count) configured providers returned a usage reading. Check credentials in Settings.",
                suggestedAction: "Open Settings",
                urgency: .none,
                iconName: "questionmark.circle.fill",
                iconColorHex: "#adc6ff"
            )
        }

        let candidates = Self.candidates(from: snapshots)
        let constrained = candidates.filter(\.isConstrained).sorted { $0.used > $1.used }
        let headroom = candidates.filter(\.hasHeadroom).sorted { $0.used < $1.used }
        let openrouterSnap = snapshots.first { $0.vendorId == .openrouter }
        let githubRestSnap = snapshots.first { $0.vendorId == .githubRest }

        // 1. SCENARIO: something is nearly spent. Route around it — or, if
        //    nothing has headroom left, off the subscriptions entirely.
        if !constrained.isEmpty {
            let constraints = list(constrained.map(constraintText))

            if let best = headroom.first {
                let remaining = Int(((1.0 - best.used) * 100).rounded())
                return QuotaAdvice(
                    headline: "Use \(best.name)",
                    message: "\(best.name) has \(remaining)% remaining. \(constraints).",
                    suggestedAction: "Use \(best.name)",
                    urgency: .critical,
                    iconName: "arrow.triangle.swap",
                    iconColorHex: "#9C52FD",
                    vendorId: best.vendorId
                )
            }

            // Nothing has real headroom — but a window in its final stretch
            // still holds allowance that is already paid for and about to
            // expire. Spend that before reaching for metered credit.
            if let expiring = constrained
                .filter(\.isExpiringUnspent)
                .max(by: { ($0.bar?.expectedPaceFraction ?? 0) < ($1.bar?.expectedPaceFraction ?? 0) }) {
                let remaining = Int(((1.0 - expiring.used) * 100).rounded())
                let label = expiring.bar.map { " \($0.label)" } ?? ""
                let reset = cleanResetString(expiring.bar?.resetText)
                    .map { " and the window resets in \($0)" } ?? ""
                let others = constrained.filter { $0.vendorId != expiring.vendorId }
                let rest = others.isEmpty ? "" : " \(list(others.map(constraintText)))."
                return QuotaAdvice(
                    headline: "Spend Remaining \(expiring.name)",
                    message: "\(expiring.name)\(label) has \(remaining)% left\(reset) — use it before it resets, rather than spending OpenRouter credit.\(rest)",
                    suggestedAction: "Use \(expiring.name)",
                    urgency: .warning,
                    iconName: "hourglass.bottomhalf.filled",
                    iconColorHex: "#ffb874",
                    vendorId: expiring.vendorId
                )
            }

            let balance = openrouterSnap?.badgeText ?? "check your OpenRouter balance"
            let names = list(constrained.map(\.name))
            let anchor = constrained.first { cleanResetString($0.bar?.resetText) != nil }
            let until = anchor.flatMap { candidate -> String? in
                cleanResetString(candidate.bar?.resetText).map { " until \(candidate.name) resets in \($0)" }
            } ?? ""
            return QuotaAdvice(
                headline: "Primary Quotas Exhausted",
                message: "\(names) \(constrained.count == 1 ? "is" : "are") near capacity. Route urgent tasks to OpenRouter models (\(balance))\(until).",
                suggestedAction: "Use OpenRouter Models",
                urgency: .critical,
                iconName: "exclamationmark.triangle.fill",
                iconColorHex: "#ffb4ab",
                vendorId: .openrouter
            )
        }

        // 2. SCENARIO: GitHub REST rate limit elevated or critical.
        //
        // Checked only once no subscription is constrained: a throttled `gh`
        // is an annoyance, an exhausted coding quota stops the work.
        // A limit we could not read is not a limit at zero.
        let githubRestFraction = githubRestSnap.flatMap {
            $0.status.confidence == .measured
                ? $0.row1?.primaryFraction ?? $0.consumptionFraction
                : nil
        }
        let isGitHubCritical = githubRestSnap?.status.urgency == .critical || (githubRestFraction ?? 0) >= 0.90
        if let githubRestFraction, isGitHubCritical || githubRestFraction >= 0.70 {
            // The window length is read, never assumed: "(hourly)" was a
            // claim about GitHub's policy, printed whether or not we saw it.
            let resetDesc = githubRestSnap?.row1?.resetText.map { " (\($0))" } ?? ""
            let usedPct = Int((githubRestFraction * 100).rounded())
            return QuotaAdvice(
                headline: "GitHub REST Limit at \(usedPct)%",
                message: "GitHub REST rate limit is \(isGitHubCritical ? "nearly exhausted" : "elevated")\(resetDesc). Developer limits unsuppressed. Throttle automated polling or switch to GraphQL v4.",
                suggestedAction: "Throttle GitHub CLI",
                urgency: isGitHubCritical ? .critical : .warning,
                iconName: "network.badge.shield.half.filled",
                iconColorHex: isGitHubCritical ? "#ffb4ab" : "#ffb874",
                vendorId: .githubRest
            )
        }

        // 3. SCENARIO: an allowance is about to reset unused. Spend it first.
        if let best = headroom.first,
           let rawReset = best.bar?.resetText, !rawReset.isEmpty {
            let headroomPct = Int(((1.0 - best.used) * 100).rounded())
            let cleanReset = cleanResetString(rawReset) ?? rawReset
            let formattedReset = cleanReset.hasPrefix("in ") ? cleanReset : "in \(cleanReset)"
            return QuotaAdvice(
                headline: "\(best.name) Resets Soon (\(formattedReset))",
                message: "\(best.name) has \(headroomPct)% unused allowance resetting \(formattedReset). Switch to \(best.name) now to consume this window's allowance first.",
                suggestedAction: "Use \(best.name)",
                urgency: .none,
                iconName: "flame.fill",
                iconColorHex: "#adc6ff",
                vendorId: best.vendorId
            )
        }

        // 4. SCENARIO: all healthy & balanced.
        //
        // Names only the providers actually measured, and says plainly when
        // some could not be read. Claiming headroom on an unreadable provider
        // is the same fabrication as inventing its percentage.
        let measuredNames = list(candidates.map(\.name))
        let unreadable = snapshots
            .filter { $0.category == .aiSubscriptions && $0.status.confidence == .unavailable }
            .map(\.shortVendorName)
        let caveat = unreadable.isEmpty ? "" : " \(list(unreadable)) could not be read."
        return QuotaAdvice(
            headline: "All Quotas Healthy & Balanced",
            message: measuredNames.isEmpty
                ? "No subscription reported a usage window.\(caveat)"
                : "\(measuredNames) \(candidates.count == 1 ? "has" : "have") ample headroom. Optimal time for long coding and refactoring sessions.\(caveat)",
            suggestedAction: "Optimal Headroom",
            urgency: .none,
            iconName: "sparkles",
            iconColorHex: "#53e16f"
        )
    }

    private static func cleanResetString(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var text = raw
        let prefixes = ["Refreshes in ", "Resets in ", "Refreshes ", "Resets ", "refreshes in ", "resets in ", "refreshes ", "resets "]
        for p in prefixes {
            if text.hasPrefix(p) {
                text = String(text.dropFirst(p.count))
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

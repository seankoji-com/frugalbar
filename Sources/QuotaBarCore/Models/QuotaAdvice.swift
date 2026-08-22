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

        let claudeSnap = snapshots.first { $0.vendorId == .claude }
        let geminiSnap = snapshots.first { $0.vendorId == .gemini }
        let opencodeSnap = snapshots.first { $0.vendorId == .opencode }
        let openrouterSnap = snapshots.first { $0.vendorId == .openrouter }
        let githubRestSnap = snapshots.first { $0.vendorId == .githubRest }


        let claudeFraction = claudeSnap?.row1?.primaryFraction ?? claudeSnap?.consumptionFraction ?? 0.0
        let geminiFraction = geminiSnap?.row1?.primaryFraction ?? geminiSnap?.consumptionFraction
        let opencodeFraction = opencodeSnap?.row1?.primaryFraction ?? opencodeSnap?.consumptionFraction ?? 0.0
        let githubRestFraction = githubRestSnap?.row1?.primaryFraction ?? githubRestSnap?.consumptionFraction ?? 0.0

        let isClaudeCritical = claudeSnap?.status.urgency == .critical || claudeFraction >= 0.85
        let isGeminiCritical = geminiSnap?.status.urgency == .critical || (geminiFraction ?? 0) >= 0.85
        let isGitHubCritical = githubRestSnap?.status.urgency == .critical || githubRestFraction >= 0.90

        // 1. SCENARIO: All or most primary AI subscriptions are critical (Red)
        if isClaudeCritical && isGeminiCritical {
            let claudeReset = claudeSnap?.row1?.resetText ?? "3 hours"
            let openrouterBalance = openrouterSnap?.badgeText ?? "check your OpenRouter balance"
            return QuotaAdvice(
                headline: "Primary Quotas Exhausted",
                message: "Claude and Gemini are near capacity. Route urgent tasks to OpenRouter models (\(openrouterBalance)) until Claude resets in \(claudeReset).",
                suggestedAction: "Use OpenRouter Models",
                urgency: .critical,
                iconName: "exclamationmark.triangle.fill",
                iconColorHex: "#ffb4ab",
                vendorId: .openrouter
            )
        }

        // 2. SCENARIO: GitHub REST rate limit elevated or critical
        if isGitHubCritical || githubRestFraction >= 0.70 {
            let resetDesc = githubRestSnap?.row1?.resetText ?? "hourly"
            let usedPct = Int((githubRestFraction * 100).rounded())
            return QuotaAdvice(
                headline: "GitHub REST Limit at \(usedPct)%",
                message: "GitHub REST rate limit is \(isGitHubCritical ? "nearly exhausted" : "elevated") (\(resetDesc)). Developer limits unsuppressed. Throttle automated polling or switch to GraphQL v4.",
                suggestedAction: "Throttle GitHub CLI",
                urgency: isGitHubCritical ? .critical : .warning,
                iconName: "network.badge.shield.half.filled",
                iconColorHex: isGitHubCritical ? "#ffb4ab" : "#ffb874",
                vendorId: .githubRest
            )
        }


        // 3. SCENARIO: Claude weekly quota critical / Copilot exhausted / OpenCode exhausted, Gemini has ample capacity
        let claudeWeekly = claudeSnap?.row2?.primaryFraction ?? 0.0
        let copilotSnap = snapshots.first { $0.vendorId == .copilot }
        let isCopilotExhausted = copilotSnap?.status.urgency == .critical || (copilotSnap?.row1?.primaryFraction ?? 0.0) >= 0.95
        let isOpenCodeExhausted = opencodeSnap?.status.urgency == .critical || (opencodeSnap?.row3?.primaryFraction ?? 0.0) >= 0.95

        if let geminiFraction,
           (claudeWeekly >= 0.80 || isCopilotExhausted || isOpenCodeExhausted || (claudeFraction >= 0.70 && geminiFraction < 0.70)) && geminiFraction < 0.85 {
            let geminiRemaining = Int(((1.0 - geminiFraction) * 100).rounded())

            // Build dynamic list of constrained providers
            var constraints: [String] = []

            // Claude constraint
            if let weeklyBar = claudeSnap?.row2, weeklyBar.primaryFraction >= 0.80 {
                let pct = Int((weeklyBar.primaryFraction * 100).rounded())
                let reset = cleanResetString(weeklyBar.resetText)
                let resetStr = reset.map { " until \($0)" } ?? ""
                constraints.append("Claude weekly at \(pct)%\(resetStr)")
            } else if let fiveHBar = claudeSnap?.row1, fiveHBar.primaryFraction >= 0.70 {
                let pct = Int((fiveHBar.primaryFraction * 100).rounded())
                let reset = cleanResetString(fiveHBar.resetText)
                let resetStr = reset.map { " (resets in \($0))" } ?? ""
                constraints.append("Claude 5H at \(pct)%\(resetStr)")
            }

            // OpenCode constraint
            if let moBar = opencodeSnap?.row3, moBar.primaryFraction >= 0.85 {
                let isExh = moBar.primaryFraction >= 0.95 || opencodeSnap?.status.urgency == .critical
                let reset = cleanResetString(moBar.resetText)
                let resetStr = reset.map { " resets on \($0)" } ?? ""
                constraints.append(isExh ? "OpenCode Go\(resetStr.isEmpty ? " exhausted" : "\(resetStr)")" : "OpenCode Go monthly at \(Int((moBar.primaryFraction * 100).rounded()))%\(resetStr)")
            } else if let burstBar = opencodeSnap?.row1, burstBar.primaryFraction >= 0.75 {
                let reset = cleanResetString(burstBar.resetText)
                let resetStr = reset.map { " (resets in \($0))" } ?? ""
                constraints.append("OpenCode Go burst at \(Int((burstBar.primaryFraction * 100).rounded()))%\(resetStr)")
            }

            // Copilot constraint
            if let copilotBar = copilotSnap?.row1, copilotBar.primaryFraction >= 0.80 {
                let isExh = copilotBar.primaryFraction >= 0.95 || copilotSnap?.status.urgency == .critical
                let reset = cleanResetString(copilotBar.resetText)
                let resetStr = reset.map { " for \($0)" } ?? ""
                constraints.append(isExh ? "Copilot exhausted\(resetStr)" : "Copilot at \(Int((copilotBar.primaryFraction * 100).rounded()))%\(resetStr)")
            }

            let constraintText: String
            if constraints.isEmpty {
                constraintText = "Route requests here to preserve allowances on other providers."
            } else if constraints.count == 1 {
                constraintText = "\(constraints[0])."
            } else if constraints.count == 2 {
                constraintText = "\(constraints[0]) & \(constraints[1])."
            } else {
                let allButLast = constraints.dropLast().joined(separator: ", ")
                constraintText = "\(allButLast) & \(constraints.last!)."
            }

            let message = "Gemini has \(geminiRemaining)% remaining. \(constraintText)"

            return QuotaAdvice(
                headline: "Use Gemini",
                message: message,
                suggestedAction: "Use Gemini",
                urgency: .critical,
                iconName: "sparkles",
                iconColorHex: "#9C52FD",
                vendorId: .gemini
            )
        }

        // 4. SCENARIO: OpenCode running low
        if let geminiFraction, opencodeFraction >= 0.75 && geminiFraction < 0.70 {
            let usedPct = Int((opencodeFraction * 100).rounded())
            return QuotaAdvice(
                headline: "OpenCode Quota Low (\(usedPct)%)",
                message: "OpenCode Go burst quota is at \(usedPct)%. Switch to Gemini or Copilot for code assistance.",
                suggestedAction: "Switch to Gemini",
                urgency: .warning,
                iconName: "arrow.triangle.swap",
                iconColorHex: "#ffb874",
                vendorId: .gemini
            )
        }

        // 5. SCENARIO: Imminent reset with unused capacity (e.g. Gemini / Claude about to reset)
        if let gemini = geminiSnap, let geminiFraction, geminiFraction < 0.70, let rawReset = gemini.row1?.resetText, !rawReset.isEmpty {
            let headroomPct = Int(((1.0 - geminiFraction) * 100).rounded())
            let cleanReset = cleanResetString(rawReset) ?? rawReset
            let formattedReset = cleanReset.hasPrefix("in ") ? cleanReset : "in \(cleanReset)"
            return QuotaAdvice(
                headline: "Gemini Resets Soon (\(formattedReset))",
                message: "Gemini has \(headroomPct)% unused allowance resetting \(formattedReset). Switch to Gemini now to consume this window's allowance first.",
                suggestedAction: "Use Gemini",
                urgency: .none,
                iconName: "flame.fill",
                iconColorHex: "#adc6ff",
                vendorId: .gemini
            )
        }

        // 6. SCENARIO: All healthy & balanced
        return QuotaAdvice(
            headline: "All Quotas Healthy & Balanced",
            message: "Claude, Gemini, and OpenCode have ample headroom. Optimal time for long coding and refactoring sessions.",
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


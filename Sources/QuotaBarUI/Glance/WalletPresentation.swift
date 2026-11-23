import Foundation
import QuotaBarCore

/// The Wallet: every credit, balance and plan-wide reset ticket, one line each
/// (owner, 24 Nov 2026: "collapse the credit lines into single lines. they
/// don't need to be in groups").
///
/// A row names its provider in its own title ("ChatGPT API credit", "Claude
/// Console credit") and its account in its context, so no group header is
/// needed to attribute it. Every figure and meter caption is taken from that
/// credit's existing presentation (`APICreditEntryPresentation`,
/// `OpenAIUsageCreditPresentation`, `MonthlyPromoCreditPresentation`,
/// `MonthlyCreditBarPresentation`, `GeminiAPICreditPresentation`,
/// `MetricRowPresentation.ResetCredits`), so units, money formatting and what
/// a percentage measures stay as those rules define them. A model-scoped
/// ticket (Fable) is drawn beside its model's line in Providers, not here.
struct WalletPresentation: Equatable, Sendable {

    enum Tone: Equatable, Sendable { case normal, negative, exhausted, unknown }

    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let vendor: VendorIdentifier
        /// "ChatGPT API credit", "ChatGPT bonus credits", "OpenRouter credit".
        let title: String
        /// Muted, on the same line: account, "configured", what a percentage
        /// measures, when it resets. "Primary · 14% of the billing month gone · 27d".
        let context: String?
        /// The figure on the right: "$100.00/mo", "44,250 credits", "107d left".
        let figure: String?
        var tone: Tone = .normal
        var symbol: String? = nil
        let spoken: String
    }

    let rows: [Row]

    init(snapshots: [QuotaSnapshot], now: Date) {
        var rows: [Row] = []
        var geminiCreditDone = false
        for snapshot in snapshots where snapshot.category != .developerLimits {
            let p = MetricRowPresentation(snapshot: snapshot, now: now)
            let provider = Self.providerName(snapshot.vendorId)
            let stale = snapshot.staleReading != nil ? "last reading" : nil
            // A named account (multi-account Claude or Antigravity) is named;
            // a vendor's single account needs no name.
            let account: String? = snapshot.claudeAccount?.name ?? snapshot.antigravityAccount?.name
            func context(_ parts: String?...) -> String? {
                let text = ([account] + parts + [stale]).compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return text.isEmpty ? nil : text
            }

            if ProviderGridPresentation.isDirectBalance(snapshot) {
                // A balance vendor's whole reading is its balance. One never
                // configured has nothing to show.
                guard snapshot.status.unavailableReason != .notConfigured else { continue }
                if snapshot.apiCredits.isEmpty {
                    let unread = snapshot.status.confidence == .unavailable
                    rows.append(Row(
                        id: snapshot.id + "#balance", vendor: snapshot.vendorId, title: provider,
                        context: context(),
                        figure: unread ? (snapshot.status.unavailableReason?.headline ?? "No reading") : p.valueLabel,
                        tone: unread ? .unknown : (Self.isNegative(snapshot.metric) ? .negative : .normal),
                        spoken: p.accessibilityLabel))
                } else {
                    rows += snapshot.apiCredits.map { Self.entryRow($0, provider: provider, context: context()) }
                }
                continue
            }

            rows += snapshot.apiCredits.filter { !$0.extendsSubscription }
                .map { Self.entryRow($0, provider: provider, context: context()) }
            // The ChatGPT credit count that extends the plan: "bonus credits".
            if let usage = p.openAIUsageCredit,
               let entry = snapshot.apiCredits.first(where: { $0.id == "openai.api-credits" }) {
                let expiry = entry.creditGrant?.expiresAt.flatMap { ResetCountdownBadge.compact($0, now: now) }
                rows.append(Row(
                    id: snapshot.id + "#bonus", vendor: snapshot.vendorId, title: "\(provider) bonus",
                    context: context(usage.percentText, expiry.map { "expires \($0)" }),
                    figure: APICreditEntryPresentation(entry: entry).figure,
                    tone: usage.fraction >= QuotaSnapshot.exhaustionThreshold ? .exhausted : .normal,
                    spoken: usage.spoken))
            }
            for (index, e) in p.subscriptionCredits.enumerated() {
                let isBonus = snapshot.vendorId == .openai
                    && snapshot.apiCredits.contains { $0.id == "openai.api-credits" && $0.extendsSubscription }
                rows.append(Row(
                    id: "\(snapshot.id)#sub\(index)", vendor: snapshot.vendorId,
                    title: isBonus ? "\(provider) bonus" : Self.prefixed(e.title, with: provider),
                    context: context(e.detail), figure: e.figure, spoken: e.spoken))
            }
            if let promo = p.monthlyPromo {
                rows.append(Row(
                    id: snapshot.id + "#promo", vendor: snapshot.vendorId,
                    title: "\(provider) \(promo.title.lowercased().hasPrefix("api") ? "API" : promo.title.lowercased())",
                    context: context(promo.percentText.map { "\($0) used" },
                                     promo.dayCountdown.map { "resets \($0)" }),
                    figure: promo.amountText.map { "\($0)/mo" },
                    tone: promo.isExhausted ? .exhausted : .normal,
                    spoken: promo.spoken))
            }
            if let credit = p.monthlyCredit {
                rows.append(Row(
                    id: snapshot.id + "#console", vendor: snapshot.vendorId, title: "\(provider) Console",
                    // Time through the billing month, not spend (no spend is published).
                    context: context(credit.fraction.map { "\(Self.percent($0)) of month" }, credit.countdown),
                    figure: "\(credit.amountText)/mo", spoken: credit.spoken))
            }
            for (label, credits) in Self.planTicketGroups(p, snapshot: snapshot) {
                for index in 0..<credits.tickets {
                    rows.append(Row(
                        id: "\(snapshot.id)#ticket-\(label)-\(index)", vendor: snapshot.vendorId,
                        title: "\(provider) \(label) ticket", context: context(),
                        figure: credits.expiryPhrase(at: index, now: credits.now),
                        symbol: "ticket.fill",
                        spoken: index == 0 ? credits.spoken : credits.expirySpoken(at: index)))
                }
                if credits.overflow > 0 {
                    rows.append(Row(id: "\(snapshot.id)#ticket-\(label)-more", vendor: snapshot.vendorId,
                                    title: "\(provider) \(label) tickets", context: context(),
                                    figure: "+\(credits.overflow) more", symbol: "ticket.fill",
                                    spoken: "\(credits.overflow) more"))
                }
            }

            // The AI Studio key's credit belongs to the Gemini API key, not to
            // an Antigravity account: one row of its own, once.
            if !geminiCreditDone, let credit = p.geminiAPICredit {
                geminiCreditDone = true
                let b = credit.budget
                rows.append(Row(
                    id: "gemini-api-key", vendor: .gemini, title: "Gemini API",
                    context: ["configured", "\(b.percentText) of month", b.countdown]
                        .compactMap { $0 }.joined(separator: " · "),
                    figure: "\(b.amountText)/mo", spoken: credit.spoken))
            }
        }
        self.rows = rows
    }

    /// The name a credit row leads with. ChatGPT, not Codex: the credits
    /// belong to the ChatGPT account.
    static func providerName(_ vendor: VendorIdentifier) -> String {
        switch vendor {
        case .openai: "ChatGPT"
        case .claude: "Claude"
        default: vendor.displayName
        }
    }

    static func entryRow(_ entry: APICreditEntry, provider: String, context: String?) -> Row {
        let e = APICreditEntryPresentation(entry: entry)
        return Row(id: entry.vendorId.rawValue + "#" + entry.id, vendor: entry.vendorId,
                   title: prefixed(e.title, with: provider),
                   context: [context, e.detail].compactMap { $0 }.joined(separator: " · ").nilIfEmptyString,
                   figure: e.figure, tone: isNegative(entry.metric) ? .negative : .normal, spoken: e.spoken)
    }

    /// "Extra usage" → "Claude extra usage"; a title that already names its
    /// provider is left alone.
    static func prefixed(_ title: String, with provider: String) -> String {
        let lower = title.lowercased()
        if lower.hasPrefix(provider.lowercased()) || lower.hasPrefix("openai") { return title }
        return "\(provider) \(lower)"
    }

    /// Plan-wide tickets, plus any model ticket with no model line to sit
    /// beside (it is still drawn, never dropped). A model's tickets with a
    /// line (Fable) sit beside that line in the Providers row they reset.
    static func planTicketGroups(_ p: MetricRowPresentation,
                                 snapshot: QuotaSnapshot) -> [(String, MetricRowPresentation.ResetCredits)] {
        if !p.resetCreditGroups.isEmpty {
            let plan = p.resetCreditGroups.filter(\.scope.isPlan).map { ("plan reset", $0.credits) }
            let unmatched = p.unmatchedResetCredits(scopedLabels: snapshot.scopedBars.map(\.label))
                .map { ("\($0.scope.displayName) reset", $0.credits) }
            return plan + unmatched
        }
        return p.resetCredits.map { [("reset", $0)] } ?? []
    }

    static func isNegative(_ metric: MetricType) -> Bool {
        if case .currency(let balance, _, _, _) = metric { return balance < 0 }
        return false
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

private extension String {
    var nilIfEmptyString: String? { isEmpty ? nil : self }
}

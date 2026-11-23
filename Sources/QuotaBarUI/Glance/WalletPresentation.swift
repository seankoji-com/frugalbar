import Foundation
import QuotaBarCore

/// The Wallet: every credit, balance and plan-wide reset ticket, one line each,
/// with no group headers and no subtitle (owner, 24 Nov 2026).
///
/// A row's title names its provider, and its account where the provider has
/// named accounts ("Claude Console · Primary"). A credit with a period draws
/// the same bar the provider rows draw (`Meter.credit`: "% left", the even-use
/// tick, the countdown); a credit published only as time through a month
/// draws an informational `MO` meter (`Meter.elapsed`), never a quota colour;
/// a balance draws its recorded trend (`balanceSeriesID`). Every figure comes
/// from that credit's existing presentation (`APICreditEntryPresentation`,
/// `OpenAIUsageCreditPresentation`, `MonthlyPromoCreditPresentation`,
/// `MonthlyCreditBarPresentation`, `GeminiAPICreditPresentation`,
/// `MetricRowPresentation.ResetCredits`), so units, money formatting and what a
/// meter measures stay as those rules define them. A model-scoped ticket
/// (Fable) is drawn beside its model's line in Providers, not here.
struct WalletPresentation: Equatable, Sendable {

    enum Tone: Equatable, Sendable { case normal, negative, exhausted, unknown }

    enum Meter: Equatable, Sendable {
        /// A credit's used share as a window: drawn like a provider bar. The
        /// tick appears only when the metrics carry a period (reset and
        /// length); a credit that publishes only its expiry has none.
        case credit(DualBarMetrics)
        /// Time through a month or billing period, not spend.
        case elapsed(fraction: Double, countdown: String?)
    }

    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let vendor: VendorIdentifier
        /// "ChatGPT API", "Claude Console · Primary", "OpenRouter".
        let title: String
        /// "configured" for a figure the user typed; "last reading" when the
        /// vendor's newest poll failed. Drawn as a small tag, not a subtitle.
        var tag: String? = nil
        /// The figure on the right: "$100.00/mo", "60,085 credits", "107d remaining".
        let figure: String?
        var tone: Tone = .normal
        var symbol: String? = nil
        var meter: Meter? = nil
        /// The balance's recorded series (`BalanceSeries.id`), for its trend.
        var balanceSeriesID: String? = nil
        let spoken: String
    }

    let rows: [Row]

    init(snapshots: [QuotaSnapshot], now: Date) {
        var rows: [Row] = []
        var geminiCreditDone = false
        for snapshot in snapshots where snapshot.category != .developerLimits {
            let p = MetricRowPresentation(snapshot: snapshot, now: now)
            let provider = Self.providerName(snapshot.vendorId)
            let staleTag: String? = snapshot.staleReading != nil ? "last reading" : nil
            // A named account (multi-account Claude or Antigravity) is named
            // in the title; a vendor's single account needs no name.
            let account = snapshot.claudeAccount?.name ?? snapshot.antigravityAccount?.name
            func titled(_ title: String) -> String { account.map { "\(title) · \($0)" } ?? title }

            if ProviderGridPresentation.isDirectBalance(snapshot) {
                // A balance vendor's whole reading is its balance. One never
                // configured has nothing to show.
                guard snapshot.status.unavailableReason != .notConfigured else { continue }
                if snapshot.apiCredits.isEmpty {
                    let unread = snapshot.status.confidence == .unavailable
                    rows.append(Row(
                        id: snapshot.id + "#balance", vendor: snapshot.vendorId, title: titled(provider),
                        tag: staleTag,
                        figure: unread ? (snapshot.status.unavailableReason?.headline ?? "No reading") : p.valueLabel,
                        tone: unread ? .unknown : (Self.isNegative(snapshot.metric) ? .negative : .normal),
                        balanceSeriesID: BalanceSeries.of(snapshot)?.id,
                        spoken: p.accessibilityLabel))
                } else {
                    rows += snapshot.apiCredits.map { Self.entryRow($0, title: titled, tag: staleTag) }
                }
                continue
            }

            rows += snapshot.apiCredits.filter { !$0.extendsSubscription }
                .map { Self.entryRow($0, title: titled, tag: staleTag) }
            // The ChatGPT credit count that extends the plan: "bonus".
            if let usage = p.openAIUsageCredit,
               let entry = snapshot.apiCredits.first(where: { $0.id == "openai.api-credits" }) {
                rows.append(Row(
                    id: snapshot.id + "#bonus", vendor: snapshot.vendorId, title: titled("\(provider) bonus"),
                    tag: staleTag,
                    figure: APICreditEntryPresentation(entry: entry).figure,
                    tone: usage.fraction >= QuotaSnapshot.exhaustionThreshold ? .exhausted : .normal,
                    // A bar to the expiry; the even-use tick only when the
                    // grant date was confirmed too (`OpenAICreditGrant.periodLength`).
                    meter: usage.barMetrics.map { .credit($0) },
                    spoken: usage.spoken))
            }
            for (index, e) in p.subscriptionCredits.enumerated() {
                let isBonus = snapshot.vendorId == .openai
                    && snapshot.apiCredits.contains { $0.id == "openai.api-credits" && $0.extendsSubscription }
                rows.append(Row(
                    id: "\(snapshot.id)#sub\(index)", vendor: snapshot.vendorId,
                    title: titled(isBonus ? "\(provider) bonus" : Self.prefixed(e.title, with: provider)),
                    tag: staleTag, figure: e.figure, spoken: e.spoken))
            }
            if let promo = p.monthlyPromo {
                rows.append(Row(
                    id: snapshot.id + "#promo", vendor: snapshot.vendorId,
                    title: titled("\(provider) \(promo.title.lowercased().hasPrefix("api") ? "API" : promo.title.lowercased())"),
                    tag: staleTag,
                    figure: promo.amountText.map { "\($0)/mo" },
                    tone: promo.isExhausted ? .exhausted : .normal,
                    // The promo's own bar metrics: its period, so its tick.
                    meter: promo.fraction == nil ? nil : .credit(promo.barMetrics),
                    spoken: promo.spoken))
            }
            if let credit = p.monthlyCredit {
                rows.append(Row(
                    id: snapshot.id + "#console", vendor: snapshot.vendorId, title: titled("\(provider) Console"),
                    tag: credit.isStale ? "last reading" : staleTag,
                    figure: "\(credit.amountText)/mo",
                    // Time through the billing month, not spend (no spend is published).
                    meter: credit.fraction.map { .elapsed(fraction: $0, countdown: credit.countdown) },
                    spoken: credit.spoken))
            }
            for (label, credits) in Self.planTicketGroups(p, snapshot: snapshot) {
                for index in 0..<credits.tickets {
                    rows.append(Row(
                        id: "\(snapshot.id)#ticket-\(label)-\(index)", vendor: snapshot.vendorId,
                        title: titled("\(provider) \(label) ticket"),
                        figure: credits.expiryPhrase(at: index, now: credits.now),
                        symbol: "ticket.fill",
                        spoken: index == 0 ? credits.spoken : credits.expirySpoken(at: index)))
                }
                if credits.overflow > 0 {
                    rows.append(Row(id: "\(snapshot.id)#ticket-\(label)-more", vendor: snapshot.vendorId,
                                    title: titled("\(provider) \(label) tickets"),
                                    figure: "+\(credits.overflow) more", symbol: "ticket.fill",
                                    spoken: "\(credits.overflow) more"))
                }
            }

            // The AI Studio key's credit belongs to the Gemini API key, not to
            // an Antigravity account: one row of its own, once. Always tagged
            // configured: it is the user's figure, never a reading.
            if !geminiCreditDone, let credit = p.geminiAPICredit {
                geminiCreditDone = true
                let b = credit.budget
                rows.append(Row(
                    id: "gemini-api-key", vendor: .gemini, title: "Gemini API", tag: "configured",
                    figure: "\(b.amountText)/mo",
                    meter: .elapsed(fraction: b.fraction, countdown: b.countdown),
                    spoken: credit.spoken))
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

    static func entryRow(_ entry: APICreditEntry, title: (String) -> String, tag: String?) -> Row {
        let e = APICreditEntryPresentation(entry: entry)
        return Row(id: entry.vendorId.rawValue + "#" + entry.id, vendor: entry.vendorId,
                   title: title(prefixed(e.title, with: providerName(entry.vendorId))), tag: tag,
                   figure: e.figure, tone: isNegative(entry.metric) ? .negative : .normal,
                   balanceSeriesID: BalanceSeries.of(entry)?.id, spoken: e.spoken)
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
}

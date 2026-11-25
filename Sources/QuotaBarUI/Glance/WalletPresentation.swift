import Foundation
import QuotaBarCore

/// The Wallet: every credit, balance and plan-wide reset ticket, one line each,
/// with no group headers and no subtitle (owner, 24 Nov 2026).
///
/// A row's title names its provider, and its account where the provider has
/// named accounts ("Claude Console · Primary"). A credit with a period draws
/// the same bar the provider rows draw (`Meter.credit`: "% used", the even-use
/// tick, the countdown); a credit published only as time through a month
/// draws an informational `MO` meter (`Meter.elapsed`), never a quota colour;
/// a balance draws its recorded trend (`balanceSeriesID`). Every figure comes
/// from that credit's existing presentation (`APICreditEntryPresentation`,
/// `OpenAIUsageCreditPresentation`, `MonthlyPromoCreditPresentation`,
/// `MonthlyCreditBarPresentation`, `GeminiAPICreditPresentation`,
/// `MetricRowPresentation.ResetCredits`), so units, money formatting and what a
/// meter measures stay as those rules define them. A model-scoped ticket
/// (Fable) is drawn beside its model's line in Subscriptions, not here.
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
        /// What the figure is (owner, 25 Nov 2026): "left", "grant", "credit",
        /// "cap". Drawn as a small caption under the amount; a bare amount made
        /// a remaining count, a monthly grant and a spend cap look alike.
        var figureRole: String? = nil
        var tone: Tone = .normal
        var symbol: String? = nil
        var meter: Meter? = nil
        /// The balance's recorded series (`BalanceSeries.id`), for its trend.
        var balanceSeriesID: String? = nil
        let spoken: String
        /// The snapshot this line came from: selecting the line opens its
        /// inspector, as the Subscriptions rows do.
        var snapshotID: String = ""
    }

    let rows: [Row]

    init(snapshots: [QuotaSnapshot], now: Date) {
        var rows: [Row] = []
        var geminiCreditAccounts: Set<String> = []
        for snapshot in snapshots where snapshot.category != .developerLimits {
            // Every line this snapshot adds opens this snapshot's inspector.
            let firstRow = rows.count
            defer { for i in firstRow..<rows.count { rows[i].snapshotID = snapshot.id } }
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
                        // An overdrawn balance prints its signed figure alone:
                        // "-$0.01 left" would claim money remains.
                        figure: unread ? (snapshot.status.unavailableReason?.headline ?? "No reading") : p.valueLabel,
                        figureRole: unread ? nil
                            : Self.role(for: snapshot.metric, label: p.valueLabel, basis: snapshot.currencyBasis),
                        tone: unread ? .unknown : (Self.isNegative(snapshot.metric) ? .negative : .normal),
                        balanceSeriesID: BalanceSeries.of(snapshot)?.id,
                        spoken: p.accessibilityLabel))
                } else {
                    rows += snapshot.apiCredits.map {
                        Self.entryRow($0, title: titled, tag: staleTag, namesAccount: account != nil)
                    }
                }
                continue
            }

            rows += snapshot.apiCredits.filter { !$0.extendsSubscription }
                .map { Self.entryRow($0, title: titled, tag: staleTag, namesAccount: account != nil) }
            // The ChatGPT credit count that extends the plan: "bonus".
            if let usage = p.openAIUsageCredit,
               let entry = snapshot.apiCredits.first(where: { $0.id == "openai.api-credits" }) {
                let usageSpoken = staleTag != nil && !usage.spoken.localizedCaseInsensitiveContains("stale")
                    ? "\(usage.spoken), stale, the last poll failed"
                    : usage.spoken
                rows.append(Row(
                    id: snapshot.id + "#bonus", vendor: snapshot.vendorId, title: titled("\(provider) bonus"),
                    tag: staleTag,
                    figure: APICreditEntryPresentation(entry: entry).figure,
                    figureRole: "left",
                    tone: usage.fraction >= QuotaSnapshot.exhaustionThreshold ? .exhausted : .normal,
                    // A bar to the expiry; the even-use tick only when the
                    // grant date was confirmed too (`OpenAICreditGrant.periodLength`).
                    meter: usage.barMetrics.map { .credit($0) },
                    spoken: usageSpoken))
            }
            for (index, e) in p.subscriptionCredits.enumerated() {
                let isBonus = snapshot.vendorId == .openai
                    && snapshot.apiCredits.contains { $0.id == "openai.api-credits" && $0.extendsSubscription }
                rows.append(Row(
                    id: "\(snapshot.id)#sub\(index)", vendor: snapshot.vendorId,
                    title: titled(isBonus ? "\(provider) bonus" : Self.prefixed(e.title, with: provider)),
                    tag: staleTag, figure: e.figure, spoken: e.spoken(stale: staleTag != nil)))
            }
            if let promo = p.monthlyPromo {
                rows.append(Row(
                    id: snapshot.id + "#promo", vendor: snapshot.vendorId,
                    title: titled("\(provider) \(promo.title.lowercased().hasPrefix("api") ? "API" : promo.title.lowercased())"),
                    // The promo's own freshness: OpenAI's grant has its own
                    // billing read, so a quota outage does not stale it and a
                    // failed billing read does even when quota is fresh.
                    tag: promo.isStale ? "last reading" : nil,
                    figure: promo.amountText.map { "\($0)/mo" },
                    figureRole: promo.amountText == nil ? nil : "grant",
                    tone: promo.isExhausted ? .exhausted : .normal,
                    // The promo's own bar metrics: its period, so its tick.
                    meter: promo.fraction == nil ? nil : .credit(promo.barMetrics),
                    spoken: promo.spoken))
            }
            if let credit = p.monthlyCredit {
                rows.append(Row(
                    id: snapshot.id + "#console", vendor: snapshot.vendorId, title: titled("\(provider) Console"),
                    // Read by the Console billing session, not the quota
                    // poll: only its own failed read makes it stale.
                    tag: credit.isStale ? "last reading" : nil,
                    figure: "\(credit.amountText)/mo",
                    figureRole: "credit",
                    // Time through the billing month, not spend (no spend is published).
                    meter: credit.fraction.map { .elapsed(fraction: $0, countdown: credit.countdown) },
                    spoken: credit.spoken))
            }
            // Tickets ride the quota poll, so a failed poll carries them over:
            // their presence, count and expiry are the earlier poll's, and
            // they wear its LAST READING tag like the rest of that read.
            let staleSuffix = staleTag != nil ? ", last reading, the last poll failed" : ""
            for (label, credits) in Self.planTicketGroups(p, snapshot: snapshot, now: now) {
                for index in 0..<credits.tickets {
                    rows.append(Row(
                        id: "\(snapshot.id)#ticket-\(label)-\(index)", vendor: snapshot.vendorId,
                        title: titled("\(provider) \(label) ticket"),
                        tag: staleTag,
                        figure: credits.expiryPhrase(at: index, now: credits.now),
                        symbol: "ticket.fill",
                        spoken: (index == 0 ? credits.spoken : credits.expirySpoken(at: index)) + staleSuffix))
                }
                if credits.overflow > 0 {
                    rows.append(Row(id: "\(snapshot.id)#ticket-\(label)-more", vendor: snapshot.vendorId,
                                    title: titled("\(provider) \(label) tickets"), tag: staleTag,
                                    figure: "+\(credits.overflow) more", symbol: "ticket.fill",
                                    spoken: "\(credits.overflow) more" + staleSuffix))
                }
            }

            // Each Google account's AI Studio key bills to its own Cloud
            // Billing account, so each has its own line (owner, 24 Nov 2026),
            // named for the account: one line per account however many of its
            // routes carry the credit. Always tagged configured: it is the
            // user's figure, never a reading.
            let geminiKey = snapshot.antigravityAccount?.id ?? "gemini"
            if !geminiCreditAccounts.contains(geminiKey), let credit = p.geminiAPICredit {
                geminiCreditAccounts.insert(geminiKey)
                let b = credit.budget
                rows.append(Row(
                    id: "gemini-api-key:\(geminiKey)", vendor: .gemini,
                    title: snapshot.antigravityAccount.map { "Gemini API · \($0.name)" } ?? "Gemini API",
                    tag: "configured",
                    figure: "\(b.amountText)/mo",
                    figureRole: "cap",
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

    /// `namesAccount`: `title` already names the snapshot's account, so the
    /// entry's own title must not name it too. A named Claude account's
    /// entries carry `accountName`, and taking both printed
    /// "Claude · Primary Extra usage · Primary".
    static func entryRow(_ entry: APICreditEntry, title: (String) -> String, tag: String?,
                         namesAccount: Bool) -> Row {
        let e = APICreditEntryPresentation(entry: entry)
        var name = e.title
        if namesAccount, entry.accountName != nil {
            var unnamed = entry
            unnamed.accountName = nil
            name = APICreditEntryPresentation(entry: unnamed).title
        }
        return Row(id: entry.vendorId.rawValue + "#" + entry.id, vendor: entry.vendorId,
                   title: title(prefixed(name, with: providerName(entry.vendorId))), tag: tag,
                   figure: e.figure, figureRole: role(for: entry.metric, label: e.figure),
                   tone: isNegative(entry.metric) ? .negative : .normal,
                   balanceSeriesID: BalanceSeries.of(entry)?.id,
                   spoken: e.spoken(stale: tag == "last reading"))
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
    static func planTicketGroups(_ p: MetricRowPresentation, snapshot: QuotaSnapshot,
                                 now: Date) -> [(String, MetricRowPresentation.ResetCredits)] {
        if !p.resetCreditGroups.isEmpty {
            let plan = p.resetCreditGroups.filter(\.scope.isPlan).map { ("plan reset", $0.credits) }
            // A model's tickets sit beside that model's line in Subscriptions,
            // which is drawn only while the pool is usable. A spent or blocked
            // plan hides the line, so its tickets come here instead of
            // vanishing from both sections.
            let modelLinesShown = GlancePresentation.pool(for: snapshot, now: now, ambiguous: false)?.state == .usable
            let unmatched = p.unmatchedResetCredits(
                scopedLabels: modelLinesShown ? snapshot.scopedBars.map(\.label) : [])
                .map { ("\($0.scope.displayName) reset", $0.credits) }
            return plan + unmatched
        }
        return p.resetCredits.map { [("reset", $0)] } ?? []
    }

    /// "left" only for a figure that is a remaining balance and does not
    /// already say what it is. A lifetime-spend fallback prints "$12.00
    /// spent" and a capped key "$3.00 left of $10.00"; adding "left" under
    /// those turned past spend into usable money. An overdrawn balance gets
    /// none either.
    static func role(for metric: MetricType, label: String?, basis: CurrencyBasis? = nil) -> String? {
        guard let label, !label.isEmpty, basis != .lifetimeSpend, !isNegative(metric) else { return nil }
        let words = label.lowercased()
        if words.contains("spent") || words.contains("left") || words.contains("remaining") { return nil }
        switch metric {
        case .currency, .credits: return "left"
        default: return nil
        }
    }

    static func isNegative(_ metric: MetricType) -> Bool {
        if case .currency(let balance, _, _, _) = metric { return balance < 0 }
        return false
    }
}

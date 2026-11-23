import Foundation
import QuotaBarCore

/// The Wallet: every credit, balance and reset ticket, grouped under the
/// provider and account it belongs to (owner, 24 Nov 2026: "attribute the
/// values to providers properly").
///
/// Each line takes its words and figures from that credit's existing
/// presentation (`APICreditEntryPresentation`, `OpenAIUsageCreditPresentation`,
/// `MonthlyPromoCreditPresentation`, `MonthlyCreditBarPresentation`,
/// `GeminiAPICreditPresentation`, `MetricRowPresentation.ResetCredits`), so
/// units, money formatting and what a meter measures stay as those rules
/// define them. Only the grouping and the row anatomy are new: one title, one
/// figure, and at most one meter whose caption says what it measures.
struct WalletPresentation: Equatable, Sendable {

    enum Tone: Equatable, Sendable { case normal, negative, unknown }

    /// What a meter's fill measures. Time and spend are drawn in different
    /// colours and captioned in words, so neither reads as the other.
    enum MeterKind: Equatable, Sendable {
        /// Share of a credit used (a quota-like fill).
        case used(exhausted: Bool, aheadOfPace: Bool)
        /// Share of a month or billing period elapsed: time, not spend.
        case elapsed
    }

    struct Meter: Equatable, Sendable {
        let fraction: Double
        let kind: MeterKind
        /// "41% used", "87% of the month elapsed".
        let caption: String
        /// "26d", "Expires in 38 days".
        let trailing: String?
        /// Even-pace tick, where the credit's own presentation draws one.
        let tick: Double?
    }

    struct Line: Equatable, Sendable, Identifiable {
        let id: String
        let symbol: String?
        let title: String
        let detail: String?
        let figure: String?
        var tone: Tone = .normal
        var meter: Meter? = nil
        let spoken: String
    }

    struct Entry: Equatable, Sendable, Identifiable {
        let id: String
        let vendor: VendorIdentifier
        /// "Claude Code", "Codex", "Gemini API", "OpenRouter".
        let provider: String
        /// "Primary · Max (20x)", "Prolite", "AI Studio key". Nil when the
        /// provider has one account.
        let account: String?
        /// "configured" for a figure the user typed rather than a reading.
        let tag: String?
        /// The vendor's newest poll failed: these figures are carried over.
        let isStale: Bool
        let lines: [Line]
    }

    let entries: [Entry]

    init(snapshots: [QuotaSnapshot], now: Date) {
        var entries: [Entry] = []
        var geminiCreditDone = false
        for snapshot in snapshots where snapshot.category != .developerLimits {
            let p = MetricRowPresentation(snapshot: snapshot, now: now)
            let stale = snapshot.staleReading != nil

            if ProviderGridPresentation.isDirectBalance(snapshot) {
                // A balance vendor's whole reading is its balance. One that was
                // never configured has nothing to show and no line.
                guard snapshot.status.unavailableReason != .notConfigured else { continue }
                var lines: [Line] = []
                if snapshot.apiCredits.isEmpty {
                    let unread = snapshot.status.confidence == .unavailable
                    lines.append(Line(
                        id: snapshot.id + "#balance", symbol: nil, title: "Account credit", detail: nil,
                        figure: unread ? (snapshot.status.unavailableReason?.headline ?? "No reading") : p.valueLabel,
                        tone: unread ? .unknown : (Self.isNegative(snapshot.metric) ? .negative : .normal),
                        spoken: p.accessibilityLabel))
                } else {
                    lines += snapshot.apiCredits.map { Self.entryLine($0, ownerID: snapshot.id) }
                }
                entries.append(Entry(id: snapshot.id, vendor: snapshot.vendorId, provider: snapshot.vendorId.displayName,
                                     account: nil, tag: nil, isStale: stale, lines: lines))
                continue
            }

            var lines: [Line] = []
            lines += snapshot.apiCredits.filter { !$0.extendsSubscription }
                .map { Self.entryLine($0, ownerID: snapshot.id) }
            lines += p.subscriptionCredits.enumerated().map { index, e in
                Line(id: "\(snapshot.id)#sub\(index)", symbol: nil, title: e.title, detail: e.detail,
                     figure: e.figure, spoken: e.spoken)
            }
            if let usage = p.openAIUsageCredit {
                lines.append(Line(
                    id: snapshot.id + "#usage", symbol: nil, title: "Usage credits", detail: usage.totalText,
                    figure: nil,
                    meter: Meter(fraction: usage.fraction, kind: .used(exhausted: usage.fraction >= QuotaSnapshot.exhaustionThreshold,
                                                                     aheadOfPace: false),
                                 caption: usage.percentText, trailing: usage.expiryText, tick: nil),
                    spoken: usage.spoken))
            }
            if let promo = p.monthlyPromo {
                let ahead = (promo.fraction ?? 0) > (promo.paceMarker ?? 1)
                lines.append(Line(
                    id: snapshot.id + "#promo", symbol: nil, title: promo.title, detail: nil,
                    figure: promo.amountText,
                    meter: promo.fraction.map {
                        Meter(fraction: $0, kind: .used(exhausted: promo.isExhausted, aheadOfPace: ahead),
                              caption: "\(promo.percentText ?? "") used", trailing: promo.dayCountdown,
                              tick: promo.paceMarker)
                    },
                    spoken: promo.spoken))
            }
            if let credit = p.monthlyCredit {
                lines.append(Line(
                    id: snapshot.id + "#console", symbol: nil, title: "Console \(credit.title)", detail: nil,
                    figure: credit.amountText,
                    meter: credit.fraction.map {
                        Meter(fraction: $0, kind: .elapsed,
                              caption: "\(Self.percent($0)) of the billing month elapsed",
                              trailing: credit.countdown, tick: nil)
                    },
                    spoken: credit.spoken))
            }
            for (label, credits) in Self.ticketGroups(p) {
                for index in 0..<credits.tickets {
                    lines.append(Line(
                        id: "\(snapshot.id)#ticket-\(label)-\(index)", symbol: "ticket.fill",
                        title: "\(label) ticket", detail: nil,
                        figure: credits.expiryPhrase(at: index, now: credits.now),
                        spoken: index == 0 ? credits.spoken : credits.expirySpoken(at: index)))
                }
                if credits.overflow > 0 {
                    lines.append(Line(id: "\(snapshot.id)#ticket-\(label)-more", symbol: nil,
                                      title: "+\(credits.overflow) more \(label.lowercased()) tickets",
                                      detail: nil, figure: nil, spoken: ""))
                }
            }
            if !lines.isEmpty {
                let (service, name) = GlancePresentation.names(for: snapshot)
                let plan = snapshot.claudeAccount == nil ? snapshot.shortPlanName : (snapshot.planName ?? "")
                let account = [name == service ? nil : name, plan.isEmpty ? nil : plan].compactMap { $0 }
                    .joined(separator: " · ")
                entries.append(Entry(id: snapshot.id, vendor: snapshot.vendorId, provider: service,
                                     account: account.isEmpty ? nil : account, tag: nil, isStale: stale, lines: lines))
            }

            // The AI Studio key's credit belongs to the Gemini API key, not to
            // an Antigravity account: one entry of its own, once.
            if !geminiCreditDone, let credit = p.geminiAPICredit {
                geminiCreditDone = true
                let b = credit.budget
                entries.append(Entry(
                    id: "gemini-api-key", vendor: .gemini, provider: "Gemini API", account: "AI Studio key",
                    tag: "configured", isStale: false,
                    lines: [Line(id: "gemini-api-key#budget", symbol: nil, title: "API credit", detail: nil,
                                 figure: b.amountText,
                                 meter: Meter(fraction: b.fraction, kind: .elapsed,
                                              caption: "\(b.percentText) of the month elapsed",
                                              trailing: b.countdown, tick: nil),
                                 spoken: credit.spoken)]))
            }
        }
        self.entries = entries
    }

    static func entryLine(_ entry: APICreditEntry, ownerID: String) -> Line {
        let e = APICreditEntryPresentation(entry: entry)
        return Line(id: ownerID + "#" + entry.id, symbol: nil, title: e.title, detail: e.detail, figure: e.figure,
                    tone: isNegative(entry.metric) ? .negative : .normal, spoken: e.spoken)
    }

    static func ticketGroups(_ p: MetricRowPresentation) -> [(String, MetricRowPresentation.ResetCredits)] {
        if !p.resetCreditGroups.isEmpty {
            return p.resetCreditGroups.map { ("\($0.scope.displayName) reset", $0.credits) }
        }
        return p.resetCredits.map { [("Reset", $0)] } ?? []
    }

    static func isNegative(_ metric: MetricType) -> Bool {
        if case .currency(let balance, _, _, _) = metric { return balance < 0 }
        return false
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

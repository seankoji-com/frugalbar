import Foundation

/// A prepaid API credit balance a vendor published in the same payload as the
/// quota it meters.
///
/// Deliberately not a `QuotaSnapshot`. Every piece of quota maths in this app —
/// `consumptionFraction`, the urgency bands that drive the menu-bar icon,
/// exhaustion sorting, `displayBars`' collapse, the advice engine, the history
/// recorder and the widget's average — reads snapshots, so a balance carried in
/// this type cannot reach any of them. That is the structural half of "balances
/// stay out of quota maths": a balance has no window to draw and no fraction to
/// rank. A credit's own published limit can support a presentation-only bar.
///
/// It rides the snapshot of the fetch that already read it
/// (`QuotaSnapshot.apiCredits`), which is why there is exactly one network
/// request per vendor for it: no second provider asks the same endpoint again,
/// and no second cache key splits one reading into two.
///
/// Two of these can come back from one vendor when the vendor publishes two
/// pools (Anthropic's monthly extra-usage credit and its promo credit), so the
/// popover draws one entry each rather than merging them — they are different
/// money with different expiry rules.
public struct APICreditEntry: Sendable, Equatable, Identifiable {

    /// Keep subscription credits with their account without making them quotas.
    public var extendsSubscription: Bool {
        (vendorId == .openai && poolID == "openai.api-credits") || isMonthlyPromo
    }

    /// A recurring monthly credit drawn in the window anatomy: Claude's promo
    /// credit and OpenAI's API-organization monthly grant. Both have a
    /// published allowance, a remaining figure and a period end, so the row
    /// can draw a bar without either becoming a quota.
    public var isMonthlyPromo: Bool {
        (vendorId == .claude && poolID == "claude.promo-credit")
            || (vendorId == .openai && poolID == "openai.monthly-credit")
    }

    /// Stable id, built from the facts — the vendor and which of its pools —
    /// never a UUID or prose, so the same entry re-renders as the same row.
    public let id: String
    /// The vendor's pool type, kept apart from an account-qualified entry id.
    public let poolID: String
    public let accountID: String?
    public let accountName: String?
    public let vendorId: VendorIdentifier
    /// What the entry is called on its own row, e.g. "API credits".
    public let label: String
    /// The figure, in the vendor's own unit: `.credits` for a count the vendor
    /// publishes in credits, `.currency` for money. A `.currency` figure keeps
    /// the vendor's own published limit in `limit` — it is a real figure the
    /// vendor sent. It remains outside all snapshot quota calculations.
    public let metric: MetricType
    /// What the money *is*, in the same vocabulary a provider snapshot uses, so
    /// the figure is never printed under a label that describes something else
    /// (AGENTS.md: a balance printed under a "spent" label asserts a fact
    /// nobody measured). Nil for a non-money figure.
    public let currencyBasis: CurrencyBasis?
    /// The vendor's own supporting note, e.g. "$200.00 monthly limit" or
    /// "Expires 15 Nov 2026". Nil when the vendor published no such note —
    /// and never an inferred one.
    public let detail: String?
    /// Which response the figure came from, for provenance. Never a credential.
    public let source: String?
    /// Published end of the recurring monthly promo period. Never taken from
    /// the separate Console API-credit entitlement or its next grant date.
    public let monthlyPeriodEnd: Date?
    /// Published start of the same period, when the vendor stated it. The
    /// monthly row uses this exact length for its even-use marker instead of
    /// inferring a calendar month from the end date.
    public let monthlyPeriodStart: Date?
    /// User-confirmed allowance for this account's non-recurring credit pool.
    public let creditGrant: OpenAICreditGrant?

    public init(
        id: String,
        vendorId: VendorIdentifier,
        label: String,
        metric: MetricType,
        currencyBasis: CurrencyBasis? = nil,
        detail: String? = nil,
        source: String? = nil,
        monthlyPeriodEnd: Date? = nil,
        monthlyPeriodStart: Date? = nil,
        creditGrant: OpenAICreditGrant? = nil,
        poolID: String? = nil,
        accountID: String? = nil,
        accountName: String? = nil
    ) {
        self.id = id
        self.poolID = poolID ?? id
        self.accountID = accountID
        self.accountName = accountName
        self.vendorId = vendorId
        self.label = label
        self.metric = metric
        self.currencyBasis = currencyBasis
        self.detail = detail
        self.source = source
        self.monthlyPeriodEnd = monthlyPeriodEnd
        self.monthlyPeriodStart = monthlyPeriodStart
        self.creditGrant = creditGrant
    }
}

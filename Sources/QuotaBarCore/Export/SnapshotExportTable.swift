import Foundation

/// The export adapter's window table (spec rev 7, "Export adapter").
///
/// The only thing that names a window. It keys on the vendor, the row's
/// position and the snapshot's structured fields (its `metric` for DevPass's
/// two branches), and never on a label or any display text: renaming a column
/// token on the Mac must not move a window's identity on the phone.
public enum SnapshotExportTable {

    public enum Position: String, Sendable, CaseIterable {
        case row1, row2, row3
    }

    /// The window id every billing-cycle row exports, wherever it sits.
    public static let billingCycleWindowID = "cycle"

    /// The window ids a vendor's rows map to, in row order; nil is "—", a
    /// position that vendor never fills. DevPass has one entry per branch,
    /// chosen by `metric`.
    public static func windowIDs(
        for vendor: VendorIdentifier, metric: MetricType
    ) -> [Position: String] {
        switch vendor {
        case .claude:        [.row1: "5h", .row2: "weekly"]
        case .openai:        [.row1: "w1", .row2: "w2", .row3: "w3"]
        case .gemini:        [.row1: "w1", .row2: "w2", .row3: "w3"]
        case .opencode:      [.row1: "5h", .row2: "weekly", .row3: "monthly"]
        case .copilot:       [.row1: "premium", .row2: "chat"]
        case .openrouter, .deepseek: [:]
        case .grok:          [.row1: "plan", .row2: "on_demand"]
        case .kiro:          [.row1: "monthly", .row2: "bonus", .row3: "overage"]
        case .devpass:
            switch metric {
            case .percentage: [.row1: "monthly"]
            case .currency:   [.row1: "spend"]
            default:          [:]
            }
        case .commandcode:   [.row1: "5h", .row2: "weekly", .row3: "credits"]
        case .clinepass:     [.row1: "5h", .row2: "weekly", .row3: "monthly"]
        case .muse:          [.row1: "5h", .row2: "weekly"]
        case .githubRest:    [.row1: "rest", .row2: "graphql"]
        case .githubGraphql: [.row1: "graphql"]
        }
    }

    /// Rows marked **P**: with no reset of their own they take the snapshot's
    /// `resetsAt`, as `resetSource = provider`. GitHub keeps the REST reset
    /// on the provider; the consolidated GraphQL row has none.
    public static func takesProviderReset(_ vendor: VendorIdentifier, _ position: Position) -> Bool {
        switch (vendor, position) {
        case (.githubRest, .row1), (.githubGraphql, .row1): true
        default: false
        }
    }

    /// The one window discovery excludes from tightest selection by name:
    /// Gemini's third group is a separate model pool, not its allowance.
    public static func isNeverEligible(_ vendor: VendorIdentifier, windowID: String) -> Bool {
        vendor == .gemini && windowID == "w3"
    }

    /// Windows whose figure is the vendor's reported usage. DevPass's spend
    /// row draws its fraction from `usage` and Kiro's overage row from
    /// `currentOveragesWithPrecision`, each defaulting it to 0 when the
    /// vendor sent none, and each leaves `quantityUsed` nil in that case;
    /// such a window exports `unavailable {noReading}` rather than 0 used.
    public static func figureIsReportedUsage(_ vendor: VendorIdentifier, windowID: String) -> Bool {
        switch (vendor, windowID) {
        case (.devpass, "spend"), (.kiro, "overage"): true
        default: false
        }
    }

    /// Windows the snapshot's `metric` is built from, so an unreported usage
    /// there leaves `primary` without a value too. DevPass's currency metric
    /// is its spend; Kiro's percentage is the plan row, never the overage.
    public static func primaryIsBuiltFrom(_ vendor: VendorIdentifier, windowID: String) -> Bool {
        vendor == .devpass && windowID == "spend"
    }

    /// Every branch the table distinguishes, for the uniqueness and coverage
    /// tests: each vendor once, DevPass once per metric branch.
    public static var branches: [(vendor: VendorIdentifier, metric: MetricType)] {
        VendorIdentifier.allCases.flatMap { vendor -> [(VendorIdentifier, MetricType)] in
            guard vendor == .devpass else { return [(vendor, .subscription(tierName: nil, renewalDate: nil))] }
            return [
                (vendor, .percentage(usedFraction: 0, displayDetails: nil)),
                (vendor, .currency(balance: 0, limit: nil, spent: nil, currencyCode: "USD")),
            ]
        }
    }
}

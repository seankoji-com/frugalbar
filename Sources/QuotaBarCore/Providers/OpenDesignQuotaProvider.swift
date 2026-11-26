import Foundation

/// OpenDesign Go coding-plan usage for one verified workspace and web sign-in.
///
/// The linked workspace comes from `/api/v1/workspaces/current`. Usage reads
/// `/api/v1/workspaces/{id}/billing/coding-plan-usage` with the matching
/// `X-Vela-Workspace-Id` header. Both are authenticated by the open-design.ai web
/// session; an OpenDesign inference API key is answered `401 unauthenticated`
/// (checked against a real key on 22 November 2026 AEDT, 21 November UTC), so
/// there is no key slot.
/// The session is an opt-in in-app WebKit sign-in, like Muse's portal: no
/// cookie crosses into Swift.
///
/// Windows are chosen by `durationSeconds`, never by array order: 18000 is 5H,
/// 604800 is WK, and a 28–31 day window is MO. MO is drawn only when the vendor
/// publishes that window. Credits are allowance units, not money.
public struct OpenDesignQuotaProvider: QuotaProvider {
    public let vendorId: VendorIdentifier = .opendesign
    public var displayName: String { workspace == nil ? vendorId.displayName : slot.displayName }
    public var instanceID: String { workspace?.seriesID ?? vendorId.rawValue }
    public let category: MetricCategory = .aiSubscriptions

    static let apiBase = "https://amr-api.open-design.ai/api/v1/workspaces/"
    static let dashboardURL = URL(string: "https://open-design.ai/cloud/dashboard")!
    static let notConnected = UnavailableReason.notConfigured

    private let transport: any OpenDesignTransport
    private let slot: OpenDesignConnection
    private let workspace: OpenDesignWorkspace?

    public init() {
        self.init(slot: .primary, workspace: TestHost.isActive ? nil : OpenDesignConnections.load().workspace(for: .primary))
    }

    init(slot: OpenDesignConnection = .primary, workspace: OpenDesignWorkspace? = nil,
         transport: (any OpenDesignTransport)? = nil) {
        self.slot = slot
        self.workspace = workspace
        self.transport = transport ?? (TestHost.isActive ? OpenDesignDisconnectedTransport() :
            OpenDesignWebTransport(slot: slot, workspaceID: workspace?.workspaceId))
    }

    static func configuredProviders(
        connections: OpenDesignConnections = TestHost.isActive ? OpenDesignConnections() : OpenDesignConnections.load()
    ) -> [Self] {
        return OpenDesignConnection.allCases.compactMap { slot in
            let showUnconfigured = slot == .primary && !connections.isConnected(.secondary)
            guard connections.isConnected(slot) || showUnconfigured else { return nil }
            return Self(slot: slot, workspace: connections.workspace(for: slot))
        }
    }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        try await fetchSnapshot(now: Date())
    }

    func fetchSnapshot(now: Date) async throws -> QuotaSnapshot {
        guard let connection = await transport.connection else { return unavailable(Self.notConnected) }
        let selected: OpenDesignWorkspace
        if let workspace {
            selected = workspace
        } else {
            // Until explicitly linked, an existing primary still follows the
            // dashboard's current workspace, with no cross-series retention.
            switch Self.workspaceSelection(from: await transport.get(
                url: Self.apiBase + "current", workspaceID: nil, connection: connection), now: now) {
            case .selected(let workspace): selected = workspace
            case .failed(let reason): return unavailable(reason)
            }
        }
        guard Self.validWorkspaceID(selected.workspaceId) else { return unavailable(.badResponse) }
        let path = Self.apiBase + selected.workspaceId + "/billing/coding-plan-usage"
        switch await transport.get(url: path, workspaceID: selected.workspaceId, connection: connection) {
        case .failure(let reason): return unavailable(reason)
        case .response(let status, let data, let retryAfter):
            if let reason = Self.failureReason(status: status, retryAfter: retryAfter, now: now) {
                return unavailable(reason)
            }
            return Self.snapshot(from: data, workspace: selected, provider: self, now: now)
        }
    }

    enum WorkspaceSelection {
        case selected(OpenDesignWorkspace)
        case failed(UnavailableReason)
    }

    static func workspaceSelection(from result: OpenDesignResult, now: Date) -> WorkspaceSelection {
        switch result {
        case .failure(let reason): return .failed(reason)
        case .response(let status, let data, let retryAfter):
            if let reason = failureReason(status: status, retryAfter: retryAfter, now: now) { return .failed(reason) }
            guard let workspace = try? JSONDecoder().decode(OpenDesignWorkspace.self, from: data),
                  validWorkspaceID(workspace.workspaceId) else { return .failed(.badResponse) }
            return .selected(workspace)
        }
    }

    /// 401 means the session is gone; a 403 does not prove that, but either
    /// way the user's next step is to sign in again. 429 is a throttle, and its
    /// `Retry-After` is the vendor's instruction. Any other non-2xx is a failed
    /// read, never a healthy one.
    static func failureReason(status: Int, retryAfter: String? = nil, now: Date = Date()) -> UnavailableReason? {
        QuotaHTTP.failureReason(for: status, retryAfter: retryAfter, now: now)
    }

    /// History and retention belong to one workspace. Only a legacy primary
    /// can report a failure under the bare vendor ID before it knows which
    /// workspace it is reading.
    /// Every workspace series key starts with this, so vendor-wide history
    /// reads find all of them.
    public static let instancePrefix = "opendesign:"

    static func seriesID(workspaceID: String) -> String {
        instancePrefix + ClaudeAccount.digest("opendesign|" + workspaceID)
    }

    /// The id becomes a path component, so only a plain token is accepted.
    static func validWorkspaceID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    struct Usage: Decodable {
        let workspaceId: String?
        let eligible: Bool?
        let tier: String?
        let windows: [Window]?
    }

    struct Window: Decodable {
        let durationSeconds: Double?
        let usedCredits: Amount?
        let limitCredits: Amount?
        let resetsAt: String?
    }

    /// A non-negative credit count from a JSON number or a plain numeric
    /// string. Anything else is no figure.
    struct Amount: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw: Double?
            if let number = try? c.decode(Double.self) {
                raw = number
            } else if let text = try? c.decode(String.self),
                      text.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil {
                raw = Double(text)
            } else {
                raw = nil
            }
            // A 400-digit string parses to infinity; a ratio of two of them is
            // NaN and traps the percentage's Int conversion.
            value = raw.flatMap { $0.isFinite && $0 >= 0 && $0 <= Self.maximum ? $0 : nil }
        }
        /// Above this a credit count is not a figure a plan publishes.
        static let maximum = 9_007_199_254_740_991.0
    }

    enum Span { case fiveHour, week, month }

    static func span(of seconds: Double?) -> Span? {
        guard let seconds else { return nil }
        if seconds == QuotaWindow.fiveHours { return .fiveHour }
        if seconds == QuotaWindow.week { return .week }
        if (28 * 86_400.0...31 * 86_400.0).contains(seconds) { return .month }
        return nil
    }

    static func snapshot(from data: Data, workspace: OpenDesignWorkspace,
                         provider: OpenDesignQuotaProvider, now: Date) -> QuotaSnapshot {
        guard let usage = try? JSONDecoder().decode(Usage.self, from: data),
              usage.workspaceId == workspace.workspaceId,
              let windows = usage.windows else { return provider.unavailable(.badResponse) }
        guard usage.eligible == true else {
            return provider.unavailable(.unsupported("No OpenDesign Go coding plan on this workspace"))
        }
        var rows: [Span: DualBarMetrics] = [:]
        for window in windows {
            guard let span = span(of: window.durationSeconds) else { continue }
            // Two windows of one length leave no way to say which is the
            // plan's: that is not a reading.
            guard rows[span] == nil else { return provider.unavailable(.badResponse) }
            guard let row = row(window, span: span, now: now) else { return provider.unavailable(.badResponse) }
            rows[span] = row
        }
        let ordered = [rows[.fiveHour], rows[.week], rows[.month]].compactMap { $0 }
        guard let worst = ordered.compactMap(\.primaryFraction).max() else {
            return provider.unavailable(.badResponse)
        }
        let urgency: Urgency = worst >= 0.90 ? .critical : worst >= 0.70 ? .warning : .none
        let plan = [usage.tier, workspace.personalMembershipTier]
            .compactMap { $0?.trimmed }.first { !$0.isEmpty }
            .map { "OpenDesign Go · " + $0.capitalized }
        return QuotaSnapshot(
            id: workspace.seriesID,
            vendorId: provider.vendorId,
            displayName: provider.displayName,
            category: provider.category,
            metric: .subscription(tierName: nil, renewalDate: nil),
            status: .measured(urgency),
            resetsAt: rows[.month]?.resetsAt ?? rows[.week]?.resetsAt ?? rows[.fiveHour]?.resetsAt,
            lastUpdated: now,
            auxiliaryInfo: "Live OpenDesign Go coding-plan usage",
            row1: rows[.fiveHour],
            row2: rows[.week],
            row3: rows[.month],
            badgeText: "\(Int(((1 - worst) * 100).rounded()))% left",
            planName: plan,
            cliSource: "open-design.ai web session"
        )
    }

    /// One window. A missing or zero limit is not a window with room in it: it
    /// fails the whole read rather than drawing a bar nobody measured.
    static func row(_ window: Window, span: Span, now: Date) -> DualBarMetrics? {
        guard let used = window.usedCredits?.value, let limit = window.limitCredits?.value, limit > 0,
              (used / limit).isFinite else { return nil }
        let fraction = min(max(used / limit, 0), 1)
        let reset = window.resetsAt.flatMap(ClinePassQuotaProvider.parseResetsAt)
        let label: String
        let length: TimeInterval?
        switch span {
        case .fiveHour: label = "5H"; length = QuotaWindow.fiveHours
        case .week: label = "WK"; length = QuotaWindow.week
        case .month: label = "MO"; length = window.durationSeconds
        }
        return DualBarMetrics(
            primaryFraction: fraction,
            expectedPaceFraction: reset == nil ? nil : length.flatMap {
                DualBarMetrics.proRataPace(resetsAt: reset, windowLength: $0, now: now)
            },
            label: label,
            usedText: "\(Int((fraction * 100).rounded()))% used",
            resetText: reset.map { "Resets \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now))" },
            resetsAt: reset,
            windowLength: reset == nil ? nil : length
        )
    }
}

/// What one OpenDesign GET produced.
enum OpenDesignResult: Sendable {
    case response(status: Int, data: Data, retryAfter: String? = nil)
    case failure(UnavailableReason)
}

/// How the provider reaches OpenDesign. Production goes through the signed-in
/// in-app web session; tests inject a stub and assert it was called.
protocol OpenDesignTransport: Sendable {
    /// The current connection's generation, or nil when disabled or replaced.
    var connection: UUID? { get async }
    func get(url: String, workspaceID: String?, connection: UUID) async -> OpenDesignResult
}

struct OpenDesignDisconnectedTransport: OpenDesignTransport {
    var connection: UUID? { get async { nil } }
    func get(url: String, workspaceID: String?, connection: UUID) async -> OpenDesignResult { .failure(.notConfigured) }
}

struct OpenDesignWebTransport: OpenDesignTransport {
    let slot: OpenDesignConnection
    let workspaceID: String?

    var connection: UUID? {
        get async { await OpenDesignWebSession.session(for: slot).pollGeneration(workspaceID: workspaceID) }
    }
    func get(url: String, workspaceID: String?, connection: UUID) async -> OpenDesignResult {
        await OpenDesignWebSession.session(for: slot).get(url: url, workspaceID: workspaceID, connection: connection)
    }
}

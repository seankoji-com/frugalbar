import Foundation

public enum GoWorkspaceAccount: String, CaseIterable, Codable, Identifiable, Sendable {
    case openCode, openDesign

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .openCode: "OpenCode Go"
        case .openDesign: "OpenDesign Go"
        }
    }

    public var vendor: VendorIdentifier { self == .openCode ? .opencode : .opendesign }

    public func seriesID(for workspace: Workspace) -> String {
        switch self {
        case .openCode: OpenCodeGoWorkspaceStore.instancePrefix + ClaudeAccount.digest("opencode|" + workspace.id)
        case .openDesign: OpenDesignQuotaProvider.seriesID(workspaceID: workspace.id)
        }
    }

    var dashboard: URL {
        switch self {
        case .openCode: URL(string: "https://opencode.ai/console")!
        case .openDesign: OpenDesignQuotaProvider.dashboardURL
        }
    }

    var directoryURL: URL {
        switch self {
        case .openCode: URL(string: "https://opencode.ai/console/api/orgs")!
        case .openDesign: URL(string: "https://amr-api.open-design.ai/api/v1/workspaces")!
        }
    }

    func canReadAccount(from page: URL) -> Bool {
        guard page.scheme == "https", page.host == dashboard.host, (page.port ?? 443) == 443 else { return false }
        if self == .openCode, page.path != "/console", !page.path.hasPrefix("/console/") { return false }
        let signInRoutes = ["auth", "login", "sign-in", "signin", "oauth"]
        return !page.pathComponents.contains { signInRoutes.contains($0.lowercased()) }
    }

    var workspaceHeader: String {
        switch self {
        case .openCode: "x-org-id"
        case .openDesign: "X-Vela-Workspace-Id"
        }
    }

    func usageURL(for workspace: Workspace) -> URL {
        switch self {
        case .openCode: URL(string: "https://opencode.ai/console/api/go/status")!
        case .openDesign: directoryURL.appending(path: workspace.id).appending(path: "billing/coding-plan-usage")
        }
    }

    public struct Workspace: Codable, Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        var membershipTier: String? = nil
    }

    public struct Window: Sendable, Equatable {
        public let label: String
        public let fraction: Double?
        public let resetsAt: Date?
        public let isBlocked: Bool
        var windowLength: TimeInterval? = nil
    }

    public enum Usage: Sendable, Equatable {
        case measured([Window])
        case noPlan
        case failed(UnavailableReason)
    }

    public struct Reading: Identifiable, Sendable, Equatable {
        public var id: String { workspace.id }
        public let workspace: Workspace
        public let usage: Usage
    }

    public enum Verification: Sendable, Equatable {
        case workspaces([Reading])
        case failed(UnavailableReason)
    }

    enum Directory: Sendable {
        case workspaces([Workspace])
        case failed(UnavailableReason)
    }

    /// Queries the whole directory before reading usage. Nothing from a partial
    /// or failed verification is written to provider settings or quota history.
    func verify(now: Date, isolation: isolated (any Actor)? = #isolation,
                get: (URL, String?) async -> OpenDesignResult) async -> Verification {
        let result = directory(from: await get(directoryURL, nil), now: now)
        guard !Task.isCancelled else { return .failed(.notConfigured) }
        let workspaces: [Workspace]
        switch result {
        case .workspaces(let found): workspaces = found
        case .failed(let reason): return .failed(reason)
        }
        var readings: [Reading] = []
        var rateLimit: UnavailableReason?
        for workspace in workspaces {
            guard !Task.isCancelled else { return .failed(.notConfigured) }
            let usage: Usage
            if let rateLimit {
                usage = .failed(rateLimit)
            } else {
                let result = await get(usageURL(for: workspace), workspace.id)
                usage = parseUsage(result, workspace: workspace, now: now)
                if case .failed(let failure) = usage, case .rateLimited = failure { rateLimit = failure }
            }
            readings.append(Reading(workspace: workspace, usage: usage))
        }
        return Task.isCancelled ? .failed(.notConfigured) : .workspaces(readings)
    }

    func directory(from result: OpenDesignResult, now: Date) -> Directory {
        switch result {
        case .failure(let reason): return .failed(reason)
        case .response(let status, let data, let retryAfter):
            if let reason = QuotaHTTP.failureReason(for: status, retryAfter: retryAfter, now: now) {
                return .failed(reason)
            }
            guard let workspaces = parseDirectory(data) else { return .failed(.badResponse) }
            return .workspaces(workspaces)
        }
    }

    private struct ConsoleOrganization: Decodable {
        let id: String
        let name: String?
    }

    private struct OpenDesignDirectory: Decodable {
        let items: [OpenDesignWorkspace]
    }

    func parseDirectory(_ data: Data) -> [Workspace]? {
        let decoder = JSONDecoder()
        let workspaces: [Workspace]
        switch self {
        case .openCode:
            guard let rows = try? decoder.decode([ConsoleOrganization].self, from: data),
                  rows.allSatisfy({ $0.id.count > 4 && ($0.id.hasPrefix("org_") || $0.id.hasPrefix("wrk_")) }) else { return nil }
            workspaces = rows.map { Workspace(id: $0.id, name: $0.name?.trimmed.nonempty ?? $0.id) }
        case .openDesign:
            guard let directory = try? decoder.decode(OpenDesignDirectory.self, from: data) else { return nil }
            workspaces = directory.items.map {
                Workspace(id: $0.workspaceId, name: $0.name ?? $0.workspaceId, membershipTier: $0.personalMembershipTier)
            }
        }
        guard workspaces.allSatisfy({ OpenDesignQuotaProvider.validWorkspaceID($0.id) }),
              Set(workspaces.map(\.id)).count == workspaces.count else { return nil }
        return workspaces
    }

    func parseUsage(_ result: OpenDesignResult, workspace: Workspace, now: Date) -> Usage {
        switch result {
        case .failure(let reason): return .failed(reason)
        case .response(let status, let data, let retryAfter):
            if let reason = QuotaHTTP.failureReason(for: status, retryAfter: retryAfter, now: now) {
                return .failed(reason)
            }
            switch self {
            case .openCode: return Self.consoleUsage(data, workspaceID: workspace.id)
            case .openDesign: return Self.openDesignUsage(data, workspace: workspace, now: now)
            }
        }
    }

    private static func openDesignUsage(_ data: Data, workspace: Workspace, now: Date) -> Usage {
        guard let usage = try? JSONDecoder().decode(OpenDesignQuotaProvider.Usage.self, from: data),
              usage.workspaceId == workspace.id, let eligible = usage.eligible else { return .failed(.badResponse) }
        guard eligible else { return .noPlan }
        let linked = OpenDesignWorkspace(workspaceId: workspace.id, workspaceName: workspace.name,
                                         personalMembershipTier: workspace.membershipTier)
        let provider = OpenDesignQuotaProvider(workspace: linked, transport: OpenDesignDisconnectedTransport())
        let snapshot = OpenDesignQuotaProvider.snapshot(from: data, workspace: linked, provider: provider, now: now)
        if let reason = snapshot.status.unavailableReason { return .failed(reason) }
        return .measured(snapshot.bars.map {
            Window(label: $0.label, fraction: $0.primaryFraction, resetsAt: $0.resetsAt,
                   isBlocked: $0.isBlocked, windowLength: $0.windowLength)
        })
    }

    private static func consoleUsage(_ data: Data, workspaceID: String) -> Usage {
        let wire: ConsoleUsage?
        do {
            wire = try JSONDecoder().decode(ConsoleUsage?.self, from: data)
        } catch {
            return .failed(.badResponse)
        }
        guard let wire else { return .noPlan }
        guard wire.orgID == nil || wire.orgID == workspaceID else { return .failed(.badResponse) }
        guard let access = wire.access else { return .noPlan }
        let meters = [("5H", access.meters?.fiveHour), ("WK", access.meters?.week), ("MO", access.meters?.month)]
        var windows: [Window] = []
        for (label, value) in meters {
            guard let value else { continue }
            let blocked = value.status == "rate-limited"
            let fraction: Double?
            if let limit = value.limit?.value, let used = value.used?.value {
                guard limit > 0, (used / limit).isFinite else { return .failed(.badResponse) }
                fraction = min(used / limit, 1)
            } else {
                guard blocked else { continue }
                fraction = nil
            }
            let reset = (value.resetsAt ?? (label == "MO" ? access.endsAt : nil)).flatMap(OpenCodeGoProvider.parseDate)
            let length: TimeInterval? = switch label {
            case "5H": QuotaWindow.fiveHours
            case "WK": QuotaWindow.week
            default: reset.flatMap(DualBarMetrics.monthWindowLength(endingAt:))
            }
            windows.append(Window(label: label, fraction: fraction, resetsAt: reset,
                                  isBlocked: blocked, windowLength: length))
        }
        return windows.isEmpty ? .failed(.unsupported("OpenCode reported no usage window")) : .measured(windows)
    }

    private struct ConsoleUsage: Decodable {
        struct Access: Decodable {
            struct Meters: Decodable {
                let fiveHour: Meter?
                let week: Meter?
                let month: Meter?
            }
            let meters: Meters?
            let endsAt: String?
        }

        let access: Access?
        let orgID: String?

        private enum CodingKeys: String, CodingKey { case access, orgID = "orgId" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            access = try values.decode(Access?.self, forKey: .access)
            orgID = try values.decodeIfPresent(String.self, forKey: .orgID)
        }
    }

    private struct Meter: Decodable {
        let status: String?
        let resetsAt: String?
        let limit: Amount?
        let used: Amount?

        private enum CodingKeys: String, CodingKey {
            case status, resetsAt, limit = "limitMicroCents", used = "usedMicroCents"
        }
    }

    private struct Amount: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = (try? container.decode(Double.self)) ?? (try? container.decode(String.self)).flatMap(Double.init)
            guard let raw, raw.isFinite, raw >= 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid micro-cent amount")
            }
            value = raw
        }
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

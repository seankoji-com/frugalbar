import Foundation

extension Notification.Name {
    /// History reads preferences from this notification without requesting a quota poll.
    public static let frugalbarGoAccountHistoryDidChange = Notification.Name("frugalbarGoAccountHistoryDidChange")
}

/// Only workspace metadata is stored here. Each service's WebKit profile owns
/// the sign-in. Retired legacy settings and history are left on disk.
public struct GoWorkspaceAccountSettings: Codable, Equatable, Sendable {
    private static let key = "QuotaBarGoWorkspaceAccounts"
    private var linked: [GoWorkspaceAccount: [GoWorkspaceAccount.Workspace]] = [:]
    private var remembered: [GoWorkspaceAccount: [GoWorkspaceAccount.Workspace]] = [:]
    private var migrated: Set<GoWorkspaceAccount> = []
    private var planless: [GoWorkspaceAccount: Set<String>]? = nil
    private var approvedReplacements: Set<GoWorkspaceAccount>? = nil

    public init() {}

    public static func load() -> Self {
        guard let data = CredentialStore.preferences.data(forKey: key),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    @MainActor public func save() {
        guard Self.load() != self, let data = try? JSONEncoder().encode(self) else { return }
        CredentialStore.preferences.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: .frugalbarGoAccountHistoryDidChange, object: nil)
    }

    public func isLinked(_ service: GoWorkspaceAccount) -> Bool { linked[service] != nil }
    public func usesAccount(_ service: GoWorkspaceAccount) -> Bool { migrated.contains(service) }
    public func workspaces(for service: GoWorkspaceAccount) -> [GoWorkspaceAccount.Workspace] { linked[service] ?? [] }
    public func knownWorkspaces(for service: GoWorkspaceAccount) -> [GoWorkspaceAccount.Workspace] {
        remembered[service] ?? []
    }

    public func activeHistoryIDs(for service: GoWorkspaceAccount) -> Set<String> {
        Set(workspacesWithPlan(for: service).map { service.seriesID(for: $0) })
    }

    func workspacesWithPlan(for service: GoWorkspaceAccount) -> [GoWorkspaceAccount.Workspace] {
        let excluded = planless?[service] ?? []
        return workspaces(for: service).filter { !excluded.contains($0.id) }
    }

    public struct LegacyRequirements: Sendable {
        let openCodeCount: Int
        let openDesignCount: Int
        let openDesignIDs: Set<String>
        var openDesignPrimarySeries: String? = nil
        var needsOpenDesignPrimaryReading = false

        func minimum(for service: GoWorkspaceAccount) -> Int {
            service == .openCode ? openCodeCount : openDesignCount
        }

        public static func read(snapshots: [QuotaSnapshot]) async -> Self {
            let workspaces = OpenCodeGoWorkspaceStore.resolved()
            let hasLegacy: Bool
            if workspaces.contains(where: { $0.isEnabled && $0.id == OpenCodeGoWorkspaceStore.legacyID }) {
                let saved = await CredentialStore.hasSavedCredentialAsync(for: .opencode)
                let resolved = await CredentialStore.apiKeyAsync(for: .opencode) != nil
                hasLegacy = saved == true || resolved
            } else {
                hasLegacy = false
            }
            let openCode = workspaces.filter { workspace in
                guard workspace.isEnabled else { return false }
                return workspace.id != OpenCodeGoWorkspaceStore.legacyID
                    || hasLegacy
                    || snapshots.contains { $0.id == workspace.instanceID && $0.status.unavailableReason != .notConfigured }
            }
            let openDesign = OpenDesignConnections.load()
            let pinned = OpenDesignConnection.allCases.compactMap { openDesign.workspace(for: $0) }
            let primary = snapshots.first { snapshot in
                snapshot.vendorId == .opendesign && snapshot.id.hasPrefix(OpenDesignQuotaProvider.instancePrefix)
                    && snapshot.status.confidence == .measured && snapshot.staleReading == nil
                    && !pinned.contains(where: { $0.seriesID == snapshot.id })
            }?.id
            return Self(openCodeCount: openCode.count,
                        openDesignCount: OpenDesignConnection.allCases.count(where: openDesign.isConnected),
                        openDesignIDs: Set(pinned.map(\.workspaceId)),
                        openDesignPrimarySeries: openDesign.followsLegacyPrimary ? primary : nil,
                        needsOpenDesignPrimaryReading: openDesign.followsLegacyPrimary && primary == nil)
        }

        func covers(_ workspaces: [GoWorkspaceAccount.Workspace], service: GoWorkspaceAccount) -> Bool {
            guard workspaces.count >= minimum(for: service) else { return false }
            guard service == .openDesign else { return true }
            return !needsOpenDesignPrimaryReading && openDesignIDs.isSubset(of: Set(workspaces.map(\.id)))
                && (openDesignPrimarySeries.map { id in workspaces.contains { service.seriesID(for: $0) == id } } ?? true)
        }
    }

    /// A successful verification stages the account. On an existing setup,
    /// retire the old sources together once every configured service is ready.
    @discardableResult
    public mutating func connect(_ service: GoWorkspaceAccount, verification: GoWorkspaceAccount.Verification,
                                 requirements: LegacyRequirements, replaceEarlierConnections: Bool = false) -> Bool {
        guard case .workspaces(let readings) = verification,
              !readings.contains(where: { if case .failed = $0.usage { true } else { false } }) else { return false }
        let measured = readings.compactMap { reading in
            if case .measured = reading.usage { reading.workspace } else { nil }
        }
        guard !measured.isEmpty, Set(readings.map(\.id)).count == readings.count else { return false }
        let minimum = usesAccount(service) ? 0 : requirements.minimum(for: service)
        let coversEarlier = requirements.covers(measured, service: service)
        guard usesAccount(service) || coversEarlier || replaceEarlierConnections else { return false }
        var approvals = approvedReplacements ?? []
        if !coversEarlier && replaceEarlierConnections { approvals.insert(service) }
        else { approvals.remove(service) }
        approvedReplacements = approvals
        let noPlan = readings.compactMap { $0.usage == .noPlan ? $0.id : nil }
        var workspacePlans = planless ?? [:]
        workspacePlans[service, default: []].formUnion(noPlan)
        planless = workspacePlans
        updateWorkspaces(readings.map(\.workspace), for: service)
        for workspace in measured { remember(workspace, for: service) }
        if minimum == 0 { migrated.insert(service) }
        let ready = GoWorkspaceAccount.allCases.allSatisfy { account in
            if usesAccount(account) || requirements.minimum(for: account) == 0 { return true }
            return isLinked(account) && (approvals.contains(account) || requirements.covers(workspacesWithPlan(for: account), service: account))
        }
        if ready { migrated.formUnion(linked.keys) }
        return true
    }

    public mutating func disconnect(_ service: GoWorkspaceAccount) {
        linked[service] = nil
        planless?[service] = nil
        approvedReplacements?.remove(service)
    }

    mutating func updateWorkspaces(_ workspaces: [GoWorkspaceAccount.Workspace], for service: GoWorkspaceAccount) {
        // A directory response can temporarily omit a workspace. Keep its last plan status.
        linked[service] = workspaces
    }

    mutating func remember(_ workspace: GoWorkspaceAccount.Workspace, for service: GoWorkspaceAccount) {
        planless?[service]?.remove(workspace.id)
        var history = knownWorkspaces(for: service)
        if let index = history.firstIndex(where: { $0.id == workspace.id }) {
            history[index] = workspace
        } else {
            history.append(workspace)
        }
        remembered[service] = history
    }

    mutating func markNoPlan(_ workspace: GoWorkspaceAccount.Workspace, for service: GoWorkspaceAccount) {
        guard workspaces(for: service).contains(where: { $0.id == workspace.id }) else { return }
        var noPlan = planless ?? [:]
        noPlan[service, default: []].insert(workspace.id)
        planless = noPlan
    }
}

import Foundation

/// Only workspace metadata is stored here. Each service's WebKit profile owns
/// the sign-in. Retired legacy settings and history are left on disk.
public struct GoWorkspaceAccountSettings: Codable, Equatable, Sendable {
    private static let key = "QuotaBarGoWorkspaceAccounts"
    private var linked: [GoWorkspaceAccount: [GoWorkspaceAccount.Workspace]] = [:]
    private var remembered: [GoWorkspaceAccount: [GoWorkspaceAccount.Workspace]] = [:]
    private var migrated: Set<GoWorkspaceAccount> = []

    public init() {}

    public static func load() -> Self {
        guard let data = CredentialStore.preferences.data(forKey: key),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    @MainActor public func save() {
        if let data = try? JSONEncoder().encode(self) { CredentialStore.preferences.set(data, forKey: Self.key) }
    }

    public func isLinked(_ service: GoWorkspaceAccount) -> Bool { linked[service] != nil }
    public func usesAccount(_ service: GoWorkspaceAccount) -> Bool { migrated.contains(service) }
    public func workspaces(for service: GoWorkspaceAccount) -> [GoWorkspaceAccount.Workspace] { linked[service] ?? [] }
    public func knownWorkspaces(for service: GoWorkspaceAccount) -> [GoWorkspaceAccount.Workspace] {
        remembered[service] ?? []
    }

    public struct LegacyRequirements: Sendable {
        let openCodeCount: Int
        let openDesignCount: Int
        let openDesignIDs: Set<String>

        func minimum(for service: GoWorkspaceAccount) -> Int {
            service == .openCode ? openCodeCount : openDesignCount
        }

        public static func read(snapshots: [QuotaSnapshot]) -> Self {
            let openCode = OpenCodeGoWorkspaceStore.resolved().filter { workspace in
                guard workspace.isEnabled else { return false }
                return workspace.id != OpenCodeGoWorkspaceStore.legacyID
                    || OpenCodeGoWorkspaceStore.hasCredential(for: workspace)
                    || snapshots.contains { $0.id == workspace.instanceID && $0.status.unavailableReason != .notConfigured }
            }
            let openDesign = OpenDesignConnections.load()
            return Self(openCodeCount: openCode.count,
                        openDesignCount: OpenDesignConnection.allCases.count(where: openDesign.isConnected),
                        openDesignIDs: Set(OpenDesignConnection.allCases.compactMap { openDesign.workspace(for: $0)?.workspaceId }))
        }
    }

    /// A successful verification stages the account. On an existing setup,
    /// retire the old sources together once every configured service is ready.
    @discardableResult
    public mutating func connect(_ service: GoWorkspaceAccount, verification: GoWorkspaceAccount.Verification,
                                 requirements: LegacyRequirements) -> Bool {
        guard case .workspaces(let readings) = verification,
              !readings.contains(where: { if case .failed = $0.usage { true } else { false } }) else { return false }
        let measured = readings.compactMap { reading in
            if case .measured = reading.usage { reading.workspace } else { nil }
        }
        guard !measured.isEmpty, Set(measured.map(\.id)).count == measured.count else { return false }
        let minimum = usesAccount(service) ? 0 : requirements.minimum(for: service)
        guard measured.count >= minimum else { return false }
        if service == .openDesign, !usesAccount(service),
           !requirements.openDesignIDs.isSubset(of: Set(measured.map(\.id))) { return false }
        updateWorkspaces(measured, for: service)
        if minimum == 0 { migrated.insert(service) }
        let ready = GoWorkspaceAccount.allCases.allSatisfy { account in
            if usesAccount(account) || requirements.minimum(for: account) == 0 { return true }
            let workspaces = workspaces(for: account)
            return workspaces.count >= requirements.minimum(for: account) &&
                (account != .openDesign || requirements.openDesignIDs.isSubset(of: Set(workspaces.map(\.id))))
        }
        if ready { migrated.formUnion(linked.keys) }
        return true
    }

    public mutating func disconnect(_ service: GoWorkspaceAccount) {
        linked[service] = nil
    }

    mutating func updateWorkspaces(_ workspaces: [GoWorkspaceAccount.Workspace], for service: GoWorkspaceAccount) {
        linked[service] = workspaces
        let discovered = Set(workspaces.map(\.id))
        remembered[service] = workspaces + knownWorkspaces(for: service).filter { !discovered.contains($0.id) }
    }
}

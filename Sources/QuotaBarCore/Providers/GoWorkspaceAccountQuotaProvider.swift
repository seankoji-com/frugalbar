import Foundation

struct GoWorkspaceAccountQuotaProvider: QuotaProvider {
    static let noPlan = UnavailableReason.unsupported("This workspace has no Go plan")

    let service: GoWorkspaceAccount
    let workspace: GoWorkspaceAccount.Workspace
    let navigation: UUID
    let directoryFailure: UnavailableReason?

    var vendorId: VendorIdentifier { service.vendor }
    var displayName: String { workspace.name }
    var instanceID: String { service.seriesID(for: workspace) }
    let category: MetricCategory = .aiSubscriptions

    func fetchSnapshot() async throws -> QuotaSnapshot {
        if let directoryFailure { return unavailable(directoryFailure) }
        let response = await GoWorkspaceAccountWebSession.session(for: service)
            .readWorkspace(workspace, generation: navigation)
        let now = Date()
        switch service.parseUsage(response, workspace: workspace, now: now) {
        case .noPlan: return unavailable(Self.noPlan)
        case .failed(let reason): return unavailable(reason)
        case .measured(let windows): return snapshot(windows: windows, planName: planName(from: response), now: now)
        }
    }

    private func planName(from response: OpenDesignResult) -> String? {
        guard case .response(_, let data, _) = response else { return nil }
        switch service {
        case .openCode:
            struct Status: Decodable { let product: OpenCodeGoProvider.Plan? }
            return (try? JSONDecoder().decode(Status.self, from: data))?.product?.name
        case .openDesign:
            let tier = (try? JSONDecoder().decode(OpenDesignQuotaProvider.Usage.self, from: data))?.tier?.trimmed
            return tier.flatMap { $0.isEmpty ? nil : "OpenDesign Go · " + $0.capitalized }
        }
    }

    private func snapshot(windows: [GoWorkspaceAccount.Window], planName: String?, now: Date) -> QuotaSnapshot {
        func row(_ label: String) -> DualBarMetrics? {
            guard let window = windows.first(where: { $0.label == label }) else { return nil }
            return DualBarMetrics(primaryFraction: window.fraction,
                expectedPaceFraction: window.windowLength.flatMap {
                    DualBarMetrics.proRataPace(resetsAt: window.resetsAt, windowLength: $0, now: now)
                }, label: label, isBlocked: window.isBlocked, resetsAt: window.resetsAt, windowLength: window.windowLength)
        }
        let worst = windows.compactMap(\.fraction).max()
        let thresholds = service == .openCode ? (critical: 0.95, warning: 0.80) : (critical: 0.90, warning: 0.70)
        let urgency: Urgency = windows.contains(where: \.isBlocked) || (worst.map { $0 >= thresholds.critical } ?? false)
            ? .critical : (worst.map { $0 >= thresholds.warning } ?? false) ? .warning : .none
        return QuotaSnapshot(id: instanceID, vendorId: vendorId, displayName: displayName, category: category,
            metric: .subscription(tierName: planName, renewalDate: nil), status: .measured(urgency),
            resetsAt: windows.compactMap(\.resetsAt).max(), lastUpdated: now,
            auxiliaryInfo: "\(service.name) account", row1: row("5H"), row2: row("WK"), row3: row("MO"),
            planName: planName, cliSource: "Web sign-in")
    }
}

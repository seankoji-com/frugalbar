import SwiftUI
import AppKit
import QuotaBarCore

/// Inspector modal presenting detailed metrics and diagnostics.
///
/// Carried a "Test Quota Simulation" slider that wrote a made-up fraction into
/// the live snapshot — which then drove the advice engine and the menu bar
/// icon. A debug affordance that fabricates the one number this app exists to
/// report has no business shipping, so it is gone.
public struct MetricDetailModalView: View {

    @State private var snapshot: QuotaSnapshot
    let onClose: () -> Void

    @State private var copied = false

    public init(
        snapshot: QuotaSnapshot,
        onClose: @escaping () -> Void
    ) {
        _snapshot = State(initialValue: snapshot)
        self.onClose = onClose
    }

    private var accentColor: Color {
        Color(hexString: snapshot.vendorId.accentColorHex) ?? Theme.primary
    }

    public var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // Modal card
            VStack(spacing: 0) {
                header
                content
                footer
            }
            .frame(width: 348)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Theme.outlineVariant.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.6), radius: 20, x: 0, y: 10)
            .padding(Theme.edgeMargin)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VendorAvatarView(
                vendorId: snapshot.vendorId,
                status: snapshot.status,
                isExhausted: MetricRowPresentation(snapshot: snapshot).isExhausted
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot.displayName)
                        .font(Theme.Typography.title)
                        .tracking(Theme.Tracking.title)
                        .foregroundStyle(Theme.onSurface)

                    if let badge = snapshot.badgeText {
                        Text(badge)
                            .font(Theme.Typography.token)
                            .tracking(Theme.Tracking.token)
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.primary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }

                Text(snapshot.category.rawValue)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .padding(7)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .background(Theme.surfaceContainerHigh)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.outlineVariant.opacity(0.5)).frame(height: 0.5)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 12) {
            // Status alert banner
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusBannerIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusBannerColor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusBannerHeadline)
                        .font(Theme.Typography.cardBody.weight(.semibold))
                        .foregroundStyle(statusBannerColor)

                    if let note = snapshot.auxiliaryInfo {
                        Text(note)
                            .font(Theme.Typography.subtitle)
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusBannerColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(statusBannerColor.opacity(0.3), lineWidth: 0.5)
            )

            // Quick metrics grid (5H & Weekly)
            HStack(spacing: 8) {
                metricCard(
                    title: "5H Window Usage",
                    icon: "clock",
                    primaryValue: snapshot.row1?.usedText ?? "—",
                    secondaryValue: snapshot.row1?.resetText ?? snapshot.resetsAt.map { ResetCountdownBadge.format($0) } ?? "—",
                    bar: snapshot.row1
                )

                metricCard(
                    title: "Weekly Velocity",
                    icon: "cpu",
                    primaryValue: snapshot.row2?.usedText ?? "—",
                    secondaryValue: snapshot.row2?.resetText ?? "—",
                    bar: snapshot.row2
                )
            }

            // Technical diagnostics
            VStack(spacing: 6) {
                // Every value here is either measured or absent. A plausible
                // placeholder in a diagnostics panel is worse than a dash: it
                // is read as fact.
                diagRow(label: "Latency & Ping", value: snapshot.latencyMs.map { "\($0)ms" } ?? "—", valueColor: Theme.secondary)
                diagRow(label: "Auth / CLI Source", value: snapshot.cliSource ?? "—")
                diagRow(label: "Key Fingerprint", value: snapshot.keyMasked ?? "—")
                diagRow(label: "Plan Tier", value: snapshot.planName ?? snapshot.badgeText ?? "—", valueColor: Theme.primary)
            }
            .padding(10)
            .background(Theme.surfaceContainerLowest.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
            )

        }
        .padding(Theme.cardPadding)
    }

    private func metricCard(title: String, icon: String, primaryValue: String, secondaryValue: String, bar: DualBarMetrics?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(Theme.Typography.subtitle)
            }
            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.75))

            Text(primaryValue)
                .font(Theme.Typography.numeric)
                .tracking(Theme.Tracking.numeric)
                .foregroundStyle(Theme.onSurface)
                .padding(.top, 1)

            Text(secondaryValue)
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.primary.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let burnText = burnRateText(bar) {
                Text(burnText)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(burnRateColor(bar))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }

            if let exhaustionText = exhaustionText(bar) {
                Text(exhaustionText)
                    .font(Theme.Typography.subtitle)
                    .foregroundStyle(Theme.error)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceContainerLowest.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    /// "Burning 1.8x pace" or "0.6x pace" — how fast the window is being
    /// spent relative to how fast it is elapsing. Nil whenever the bar has no
    /// pace to compare against (a fresh window, or a vendor with no reset
    /// time), rather than a rate computed against nothing.
    private func burnRateText(_ bar: DualBarMetrics?) -> String? {
        guard let bar, (bar.primaryFraction ?? 0) < MetricRowPresentation.exhaustionThreshold,
              let rate = bar.burnRateMultiplier
        else { return nil }
        return "Burning \(String(format: "%.1f", rate))× pace"
    }

    private func burnRateColor(_ bar: DualBarMetrics?) -> Color {
        guard let rate = bar?.burnRateMultiplier else { return Theme.onSurfaceVariant.opacity(0.75) }
        if rate > 1.04 { return Theme.tertiary }
        if rate < 0.96 { return Theme.healthy }
        return Theme.onSurfaceVariant.opacity(0.75)
    }

    /// Only rendered when the current burn rate would actually exhaust the
    /// window before it resets — a real projection from a real reset date and
    /// window length, never a guess dressed up as one.
    private func exhaustionText(_ bar: DualBarMetrics?) -> String? {
        guard let date = bar?.projectedExhaustionDate else { return nil }
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "Exhausts \(relative)"
    }

    private func diagRow(label: String, value: String, valueColor: Color = Theme.onSurface) -> some View {
        HStack {
            Text(label)
                .font(Theme.Typography.subtitle)
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
            Spacer()
            Text(value)
                .font(Theme.Typography.subtitle.monospaced())
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: copyJson) {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                    Text(copied ? "Copied" : "Copy JSON")
                        .font(Theme.Typography.footer)
                }
                .foregroundStyle(copied ? Theme.secondary : Theme.onSurfaceVariant)
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Done", action: onClose)
                .font(Theme.Typography.footer)
                .foregroundStyle(Theme.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 10)
        .background(Theme.surfaceContainerLowest)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.outlineVariant.opacity(0.5)).frame(height: 0.5)
        }
    }

    private func copyJson() {
        let json = """
        {
          "id": "\(snapshot.id)",
          "vendor": "\(snapshot.displayName)",
          "category": "\(snapshot.category.rawValue)",
          "status": "\(snapshot.status.confidence == .measured ? "measured" : "unavailable")",
          "5h_fraction": \(snapshot.row1?.primaryFraction.map { String($0) } ?? "null"),
          "last_updated": "\(snapshot.lastUpdated)"
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    private var statusBannerIcon: String {
        switch snapshot.status.urgency {
        case .none:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private var statusBannerColor: Color {
        switch snapshot.status.urgency {
        case .none:     return Theme.secondary
        case .warning:  return Theme.tertiary
        case .critical: return Theme.error
        }
    }

    private var statusBannerHeadline: String {
        switch snapshot.status.urgency {
        case .none:     return "All Systems Healthy"
        case .warning:  return "Quota Warning (Elevated Burn)"
        case .critical: return "Critical Limits Approaching"
        }
    }
}

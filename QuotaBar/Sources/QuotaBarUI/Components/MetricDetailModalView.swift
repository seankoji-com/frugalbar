import SwiftUI
import AppKit
import QuotaBarCore

/// Inspector modal presenting detailed metrics, diagnostics, and test simulation.
public struct MetricDetailModalView: View {

    @State private var snapshot: QuotaSnapshot
    let onClose: () -> Void
    var onUpdateUsage: ((Double) -> Void)? = nil

    @State private var copied = false
    @State private var sliderValue: Double

    public init(
        snapshot: QuotaSnapshot,
        onClose: @escaping () -> Void,
        onUpdateUsage: ((Double) -> Void)? = nil
    ) {
        _snapshot = State(initialValue: snapshot)
        self.onClose = onClose
        self.onUpdateUsage = onUpdateUsage
        _sliderValue = State(initialValue: snapshot.row1?.primaryFraction ?? snapshot.consumptionFraction ?? 0.5)
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
            .frame(width: 320)
            .background(Theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.outlineVariant.opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 8)
            .padding(10)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VendorAvatarView(vendorId: snapshot.vendorId, status: snapshot.status)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(snapshot.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onSurface)

                    if let badge = snapshot.badgeText {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.primary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Text(snapshot.category.rawValue)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .padding(5)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceContainerHigh)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.outlineVariant.opacity(0.5)).frame(height: 0.5)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 10) {
            // Status alert banner
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: statusBannerIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusBannerColor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusBannerHeadline)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusBannerColor)

                    if let note = snapshot.auxiliaryInfo {
                        Text(note)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusBannerColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(statusBannerColor.opacity(0.3), lineWidth: 0.5)
            )

            // Quick metrics grid (5H & Weekly)
            HStack(spacing: 8) {
                metricCard(
                    title: "5H Window Usage",
                    icon: "clock",
                    primaryValue: snapshot.row1?.usedText ?? "\(Int(sliderValue * 100))% used",
                    secondaryValue: snapshot.row1?.resetText ?? (snapshot.resetsAt.map { ResetCountdownBadge.format($0) } ?? "Rolling window")
                )

                metricCard(
                    title: "Weekly Velocity",
                    icon: "cpu",
                    primaryValue: snapshot.row2?.usedText ?? "Capacity Normal",
                    secondaryValue: snapshot.row2?.resetText ?? "Active Tier"
                )
            }

            // Technical diagnostics
            VStack(spacing: 4) {
                diagRow(label: "Latency & Ping", value: "\(snapshot.latencyMs ?? 85)ms (HTTP 200 OK)", valueColor: Theme.secondary)
                diagRow(label: "Auth / CLI Source", value: snapshot.cliSource ?? "Local Keychain")
                diagRow(label: "Key Fingerprint", value: snapshot.keyMasked ?? "••••••••••••")
                diagRow(label: "Plan Tier", value: snapshot.planName ?? snapshot.badgeText ?? "Standard", valueColor: Theme.primary)
            }
            .padding(8)
            .background(Theme.surfaceContainerLowest.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
            )

            // Live simulation slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Test Quota Simulation", systemImage: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.primary)

                    Spacer()

                    Text("\(Int((sliderValue * 100).rounded()))%")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onSurface)
                }

                Slider(value: $sliderValue, in: 0...1, step: 0.05) {
                    Text("Quota")
                }
                .accentColor(Theme.primary)
                .onChange(of: sliderValue) { _, newValue in
                    onUpdateUsage?(newValue)
                }


                HStack {
                    Text("0% (Green)")
                    Spacer()
                    Text("70% (Amber)")
                    Spacer()
                    Text("90%+ (Critical)")
                }
                .font(.system(size: 7.5, weight: .regular))
                .monospaced()
                .foregroundStyle(Theme.outline)
            }
            .padding(8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
            )
        }
        .padding(12)
    }

    private func metricCard(title: String, icon: String, primaryValue: String, secondaryValue: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(title)
                    .font(.system(size: 8.5, weight: .medium))
            }
            .foregroundStyle(Theme.onSurfaceVariant.opacity(0.7))

            Text(primaryValue)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.onSurface)
                .padding(.top, 1)

            Text(secondaryValue)
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(Theme.primary.opacity(0.85))
                .lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceContainerLowest.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.outlineVariant.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func diagRow(label: String, value: String, valueColor: Color = Theme.onSurface) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 8.5, weight: .regular))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.8))
            Spacer()
            Text(value)
                .font(.system(size: 8.5, weight: .medium))
                .monospaced()
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: copyJson) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                    Text(copied ? "Copied" : "Copy JSON")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(copied ? Theme.secondary : Theme.onSurfaceVariant)
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Done", action: onClose)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.onSurface)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
          "5h_fraction": \(snapshot.row1?.primaryFraction ?? sliderValue),
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

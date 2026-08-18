import SwiftUI
import QuotaBarCore
import AppKit

/// Dynamic NSStatusItem with a gauge icon that reflects worst-case health.
/// This is a helper — the actual MenuBarExtra setup is in AppMain.
struct MenuBarStatusView: View {

    let worstStatus: ProviderStatus
    let worstFraction: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(iconColor)
            if worstStatus.severity >= 2 {
                Circle()
                    .fill(iconColor)
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var iconName: String {
        switch worstStatus {
        case .healthy:        "gauge.with.needle"
        case .warning:        "gauge.with.needle"
        case .critical:       "gauge.with.needle"
        case .rateLimited:    "exclamationmark.arrow.trianglehead.counterclockwise"
        case .unauthenticated, .networkError: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch worstStatus {
        case .healthy:        .secondary
        case .warning:        .orange
        case .critical:       .red
        case .rateLimited:    .red
        case .unauthenticated, .networkError: .gray
        }
    }
}

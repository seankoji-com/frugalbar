import SwiftUI
import QuotaBarCore

/// A 6px dot indicator matching the status severity.
struct StatusIndicatorDot: View {
    let status: ProviderStatus

    var color: Color {
        switch status {
        case .healthy:        .green
        case .warning:        .orange
        case .critical:       .red
        case .unauthenticated: .gray
        case .rateLimited:    .red
        case .networkError:   .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

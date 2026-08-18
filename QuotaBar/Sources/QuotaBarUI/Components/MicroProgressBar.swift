import SwiftUI
import QuotaBarCore

/// A slim 4pt-tall micro progress bar used inside each metric row.
struct MicroProgressBar: View {
    let fraction: Double            // 0.0 – 1.0 consumed
    let statusColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 4)

                // Fill
                Capsule()
                    .fill(statusColor)
                    .frame(width: max(geo.size.width * min(fraction, 1.0), 2), height: 4)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 4)
    }
}

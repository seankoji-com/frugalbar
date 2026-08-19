import SwiftUI

/// A slim bar showing consumed fraction.
///
/// `fraction` is optional on purpose. A nil fraction means there is no
/// denominator — an unreadable provider, a subscription, or an uncapped spend
/// figure — and renders as an empty track. It must never be coerced to 0 or 1,
/// which would read as "plenty left" or "exhausted".
struct MicroProgressBar: View {

    let fraction: Double?
    let statusColor: Color

    private var clamped: Double? {
        fraction.map { min(max($0, 0), 1) }
    }

    var body: some View {
        if fraction != nil {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.outlineVariant.opacity(0.35))
                        .frame(height: 5.5)

                    if let clamped {
                        Capsule()
                            .fill(statusColor)
                            // Keep a sliver visible at very low values so the bar
                            // reads as "nearly empty" rather than "not rendered".
                            .frame(width: max(geo.size.width * clamped, clamped > 0 ? 4 : 0), height: 5.5)
                            .animation(.easeOut(duration: 0.3), value: clamped)
                    }
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: 5.5)
            .accessibilityHidden(true)   // the row supplies the spoken label
        }
    }

}


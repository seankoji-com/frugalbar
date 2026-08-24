import SwiftUI

/// Small reusable pill: compact text on a tinted rounded rectangle.
///
/// Two near-identical inline versions of this shape already existed —
/// `MetricDetailModalView`'s `badgeText` chip and `MetricRowView`'s
/// no-reading fallback chip — before the OpenRouter model badges needed a
/// third. This is the shared shape instead. Callers still set their own
/// `accessibilityLabel`: colour and pill styling alone are not an accessible
/// status channel (WCAG 1.4.1).
struct BadgePillView: View {
    let text: String
    var tint: Color = Theme.primary

    var body: some View {
        Text(text)
            .font(Theme.Typography.token)
            .tracking(Theme.Tracking.token)
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

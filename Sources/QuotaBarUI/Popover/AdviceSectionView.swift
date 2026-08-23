import SwiftUI
import QuotaBarCore

/// The routing recommendation, presented as the popover's hero card: what to
/// use next, why, and a single button that goes and does it.
public struct AdviceSectionView: View {

    let advice: QuotaAdvice
    var onActionTap: (() -> Void)? = nil

    @State private var isHovered = false

    public init(advice: QuotaAdvice, onActionTap: (() -> Void)? = nil) {
        self.advice = advice
        self.onActionTap = onActionTap
    }

    private var accentColor: Color {
        Color(hexString: advice.iconColorHex) ?? Theme.secondary
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {

                // Vendor brand logo, or a glowing status icon when the advice
                // is not about one particular vendor.
                if let vendorId = advice.vendorId, let nsImg = VendorSVGLogo.nsImage(for: vendorId) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7.5))
                } else {
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.18))
                            .frame(width: 32, height: 32)

                        Image(systemName: advice.iconName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(accentColor)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(advice.headline)
                        .font(Theme.Typography.cardTitle)
                        .tracking(Theme.Tracking.cardTitle)
                        .foregroundStyle(Theme.onSurface)

                    // The card is the control now that the button is gone, so
                    // it needs some mark that it can be clicked. A chevron next
                    // to the title is the smallest thing that reads as one.
                    if isActionable {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onSurface.opacity(isHovered ? 0.95 : 0.45))
                    }
                }

                Text(advice.message)
                    .font(Theme.Typography.cardBody)
                    .lineSpacing(2)
                    .foregroundStyle(Theme.onSurface.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActionable && isHovered ? Theme.surfaceContainerHigh : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onActionTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActionable ? .isButton : [])
        .accessibilityLabel(advice.suggestedAction.map { "\(advice.headline). \(advice.message) \($0)" }
                            ?? "\(advice.headline). \(advice.message)")
    }

    private var isActionable: Bool { onActionTap != nil }
}

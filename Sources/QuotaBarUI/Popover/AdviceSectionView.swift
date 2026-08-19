import SwiftUI
import QuotaBarCore

/// Actionable advice and model routing recommendation section.
public struct AdviceSectionView: View {

    let advice: QuotaAdvice
    var onActionTap: (() -> Void)? = nil

    @State private var isActionHovered = false

    public init(advice: QuotaAdvice, onActionTap: (() -> Void)? = nil) {
        self.advice = advice
        self.onActionTap = onActionTap
    }

    private var accentColor: Color {
        Color(hexString: advice.iconColorHex) ?? Theme.secondary
    }

    public var body: some View {
        // Advice card
        HStack(alignment: .top, spacing: 10) {

            // Vendor Brand Logo or glowing status icon
            if let vendorId = advice.vendorId, let nsImg = VendorSVGLogo.nsImage(for: vendorId) {
                Image(nsImage: nsImg)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5.5))
                    .padding(.top, 1)
            } else {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.18))
                        .frame(width: 24, height: 24)

                    Image(systemName: advice.iconName)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(accentColor)
                }
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3.5) {

                HStack(spacing: 4) {
                    Text(advice.headline)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.onSurface)

                    Spacer()

                    if let action = advice.suggestedAction {
                        Button {
                            onActionTap?()
                        } label: {
                            HStack(spacing: 3) {
                                Text(action)
                                    .font(.system(size: 9.5, weight: .semibold))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(isActionHovered ? Theme.onSurface : accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5)
                                    .fill(isActionHovered ? accentColor.opacity(0.30) : accentColor.opacity(0.14))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4.5)
                                    .stroke(accentColor.opacity(isActionHovered ? 0.75 : 0.40), lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isActionHovered = $0 }
                    }
                }

                Text(advice.message)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.90))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceContainerLowest.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 6.5))
        .overlay(
            RoundedRectangle(cornerRadius: 6.5)
                .stroke(Theme.outlineVariant.opacity(0.30), lineWidth: 0.5)
        )

    }
}




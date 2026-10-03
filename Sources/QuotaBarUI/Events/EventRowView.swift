import SwiftUI
import AppKit
import QuotaBarCore

extension EventsPresentation {
    /// Tint for an event kind. Decoration only: the kind's SF Symbol is the
    /// channel that carries it (WCAG 1.4.1), and the row's label says it.
    public static func kindTint(_ kind: AIEventKind) -> Color {
        switch kind {
        case .usageReset:         Theme.primary
        case .usageRestored:      Theme.healthy
        case .resetCreditGranted: Color(hexString: "#5EEAD4") ?? Theme.healthy
        case .newModel:           Color(hexString: "#C4B5FD") ?? Theme.primary
        case .priceChange:        Theme.tertiary
        }
    }
}

/// One compact event row: kind symbol, vendor mark, one-line title, and a
/// caption naming when it happened and where the evidence came from.
///
/// Every width here is flexible; the title truncates rather than pushing the
/// row past the popover's 324pt content budget.
public struct EventRowView: View {

    let event: AIEvent
    let now: Date
    var compact: Bool = true

    @State private var isLinkHovered = false

    public init(event: AIEvent, now: Date, compact: Bool = true) {
        self.event = event
        self.now = now
        self.compact = compact
    }

    private var tint: Color { EventsPresentation.kindTint(event.kind) }
    private var link: URL? { EventsPresentation.openableURL(for: event) }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: event.kind.symbolName)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: compact ? 16 : 20)

            VendorAvatarView(vendorId: event.vendorId, status: .healthy, size: compact ? 16 : 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                    .foregroundStyle(Theme.onSurface)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(EventsPresentation.caption(for: event, now: now))
                    .font(.system(size: compact ? 10.5 : 11))
                    .foregroundStyle(Theme.outline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !compact, let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let link {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onSurface.opacity(isLinkHovered ? 0.95 : 0.5))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isLinkHovered = $0 }
                .help("Open \(link.host() ?? "link")")
            }
        }
        .padding(.vertical, compact ? 4 : 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EventsPresentation.accessibilityLabel(for: event, now: now))
        .accessibilityActions {
            if let link {
                Button("Open link") { NSWorkspace.shared.open(link) }
            }
        }
    }
}

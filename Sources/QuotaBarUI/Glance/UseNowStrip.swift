import SwiftUI
import QuotaBarCore

/// The glance's two answers at the top of Subscriptions: which pool to use
/// now, and when the soonest spent one comes back (owner, 23 Nov 2026).
///
/// Built from the same `GlancePresentation` as the menu-bar title, so the
/// popover and the status item can never name different pools. Without it the
/// open popover gave every group equal weight and the pick lived only in the
/// menu bar.
struct UseNowPresentation: Equatable {
    enum Tone: Equatable { case pick, caveat, none, unknown }

    let tone: Tone
    /// "Use Codex", "Best available: Claude Code Primary", "All spent".
    let headline: String
    /// "34% WK used · resets in 5d".
    let detail: String?
    /// "Back soonest: Claude Code Secondary · 2d".
    let backSoon: String?
    /// The pick's snapshot, opened when the line is clicked.
    let snapshotID: String?
    let vendor: VendorIdentifier?
    let spoken: String

    init(glance: GlancePresentation) {
        let now = glance.now
        if let pick = glance.ranking.first {
            let name = GlancePresentation.spokenName(pick.pool)
            tone = pick.isCaveat ? .caveat : .pick
            headline = pick.isCaveat ? "Best available: \(name)" : "Use \(name)"
            let used = pick.binding.used.map {
                "\(GlancePresentation.usedPercentText($0)) \(pick.binding.bar.label) used"
            }
            let reset = pick.binding.bar.resetsAt.flatMap { ResetCountdownBadge.compact($0, now: now) }
                .map { $0 == "due" ? "reset due" : "resets in \($0)" } ?? "reset not published"
            detail = [used, reset].compactMap { $0 }.joined(separator: " · ")
            snapshotID = pick.pool.id
            vendor = pick.pool.snapshot.vendorId
        } else {
            let title = glance.menuTitle
            tone = title.tone == .critical ? .none : .unknown
            headline = title.text
            detail = nil
            snapshotID = nil
            vendor = nil
        }
        // The soonest published return among spent pools; with nothing usable
        // the headline already names it, so it is not repeated.
        // Subscriptions' countdown unit (`ResetCountdownBadge.compact`), so the
        // line matches the badge and cell of the row it names.
        if glance.ranking.first != nil,
           let entry = GlancePresentation.soonestReturn(glance.backSoon, now: now),
           let at = entry.pool.returnsAt, let when = ResetCountdownBadge.compact(at, now: now) {
            let verb = entry.isBlocked ? "Unblocks soonest" : "Back soonest"
            backSoon = "\(verb): \(GlancePresentation.spokenName(entry.pool)) · \(when)"
        } else {
            backSoon = nil
        }
        let caveat = tone == .caveat ? ", not a strong pick" : ""
        spoken = ([headline + caveat, detail, backSoon].compactMap { $0 }).joined(separator: ". ")
    }
}

struct UseNowStrip: View {
    let presentation: UseNowPresentation
    var onSelect: (String) -> Void = { _ in }
    @State private var isHovered = false

    var body: some View {
        Button {
            if let id = presentation.snapshotID { onSelect(id) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                glyph
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(presentation.headline)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(headlineColor)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = presentation.detail {
                            Text(detail)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.onSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let back = presentation.backSoon {
                        Text(back)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.outline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if presentation.snapshotID != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isHovered ? Theme.onSurfaceVariant : Theme.outline)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isHovered && presentation.snapshotID != nil ? Theme.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation.snapshotID == nil)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.spoken)
        .accessibilityHint(presentation.snapshotID == nil ? "" : "Opens this pool's details")
    }

    @ViewBuilder private var glyph: some View {
        switch presentation.tone {
        case .pick, .caveat:
            if let vendor = presentation.vendor {
                VendorAvatarView(vendorId: vendor, status: .measured(.none), isExhausted: false, size: 18)
            }
        case .none:
            Image(systemName: "nosign").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.error)
        case .unknown:
            Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundStyle(Theme.outline)
        }
    }

    /// The menu bar's tone, in the popover's colours: plain for a pick, amber
    /// with "Best available" for a caveat pick, the text red when nothing is
    /// usable. The words carry each state, never the colour alone.
    private var headlineColor: Color {
        switch presentation.tone {
        case .pick: Theme.onSurface
        case .caveat: Theme.tertiary
        case .none: Theme.error
        case .unknown: Theme.onSurfaceVariant
        }
    }
}

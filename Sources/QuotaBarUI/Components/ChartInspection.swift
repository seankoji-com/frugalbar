import SwiftUI
import Charts
import QuotaBarCore

// Shared pieces that let a chart be interrogated: hover a point, or step to
// it with the keyboard or VoiceOver, and read the exact recorded figure and
// when it was taken. Used by the History timeline,
// the History overview and the inspector's charts, so each says a reading the
// same way.

/// Reports the date under the pointer while it is over the plot area, and nil
/// once it leaves.
struct ChartHoverCatcher: View {
    let proxy: ChartProxy
    let onChange: (Date?) -> Void

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else { return onChange(nil) }
                        let origin = geometry[plotFrame].origin
                        onChange(proxy.value(atX: location.x - origin.x, as: Date.self))
                    case .ended:
                        onChange(nil)
                    }
                }
        }
    }
}

/// The poll under the pointer or the keyboard selection: when it was
/// recorded, to the second, and each window's share used at that poll as the
/// store holds it — unrounded past two decimals and unclamped, because this is
/// the layer that promises the exact figure. Shape and words carry the state,
/// never colour alone.
struct ReadingReadout: View {
    let poll: HistoryOverviewPresentation.InspectedPoll

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.exactTimestampText(poll.timestamp))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.onSurface)
            ForEach(poll.rows, id: \.barLabel) { row in
                HStack(spacing: 4) {
                    Image(systemName: Self.figureSymbol(isBlocked: row.point.isBlocked, urgency: row.point.urgency))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Self.color(isBlocked: row.point.isBlocked, urgency: row.point.urgency))
                    Text("\(row.barLabel) \(Self.exactPercentText(row.point.fraction)) used\(row.point.isBlocked ? ", blocked" : "")")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onSurfaceVariant)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Theme.surfaceContainerHighest.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.outlineVariant.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(poll))
    }

    /// "Tue 14 Oct 2026, 14:05:32": the day, the year and the second, so a
    /// reading is never ambiguous about which poll it was.
    nonisolated static func exactTimestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy, HH:mm:ss"
        return formatter.string(from: date)
    }

    /// "Tue 14 Oct, 14:05" for a multi-day span, "14:05" within a day. For
    /// captions, not for the inspected reading.
    nonisolated static func timestampText(_ date: Date, showsDate: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = showsDate ? "EEE d MMM, HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }

    /// The recorded fraction as a percentage to two decimals, trailing zeros
    /// dropped: 0.62 is "62%", 0.62345 is "62.35%", and 1.03 stays "103%".
    nonisolated static func exactPercentText(_ fraction: Double) -> String {
        var text = String(format: "%.2f", fraction * 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "%"
    }

    nonisolated static func spoken(_ poll: HistoryOverviewPresentation.InspectedPoll) -> String {
        let figures = poll.rows.map { row -> String in
            "\(WindowColumn.column(forLabel: row.barLabel)?.spokenName ?? row.barLabel) "
                + "\(exactPercentText(row.point.fraction).dropLast()) percent used"
                + (row.point.isBlocked ? ", blocked" : "")
        }
        return (["Reading at \(exactTimestampText(poll.timestamp))"] + figures).joined(separator: ", ")
    }

    /// The point-shape vocabulary of the charts, as symbols.
    nonisolated static func symbol(isBlocked: Bool, urgency: Urgency) -> String {
        if isBlocked { return "square.fill" }
        if urgency == .critical { return "triangle.fill" }
        if urgency == .warning { return "diamond.fill" }
        return "circle.fill"
    }

    /// The symbol beside a figure written out in words. A blocked figure
    /// wears the shared nosign glyph, as it does everywhere a blocked figure
    /// is drawn; the chart's square is a point shape, not a word anyone reads
    /// as "blocked".
    nonisolated static func figureSymbol(isBlocked: Bool, urgency: Urgency) -> String {
        isBlocked ? BlockedGlyph.symbolName : symbol(isBlocked: false, urgency: urgency)
    }

    static func color(isBlocked: Bool, urgency: Urgency) -> Color {
        if isBlocked || urgency == .critical { return Theme.error }
        if urgency == .warning { return Theme.tertiary }
        return Theme.healthy
    }
}

/// Makes a chart interrogable without a pointer. The chart takes keyboard
/// focus; the left and right arrow keys step from poll to poll (the first
/// press lands on the newest), Escape clears the selection, and VoiceOver's
/// adjust action does the same stepping and reads the selected reading as the
/// chart's value. Hover and the keyboard share one selection, so the readout
/// is the same whichever drove it.
struct ReadingInspection: ViewModifier {
    let segments: [HistoryPresentation.TimelineSegment]
    @Binding var selection: Date?
    let tolerance: TimeInterval
    let label: String
    let summary: String

    private var selected: HistoryOverviewPresentation.InspectedPoll? {
        selection.flatMap {
            HistoryOverviewPresentation.nearestPoll(to: $0, in: segments, tolerance: tolerance)
        }
    }

    func body(content: Content) -> some View {
        content
            .focusable()
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .onKeyPress(.escape) {
                guard selection != nil else { return .ignored }
                selection = nil
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(selected.map(ReadingReadout.spoken) ?? summary)
            .accessibilityHint("Arrow keys or adjust step through the recorded readings.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: _ = step(1)
                case .decrement: _ = step(-1)
                @unknown default: break
                }
            }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let current = selected?.timestamp ?? selection
        guard let next = HistoryOverviewPresentation.steppedPoll(from: current, by: offset, in: segments) else {
            return .ignored
        }
        selection = next
        return .handled
    }
}

/// Names each window's dash pattern when a chart draws more than one.
struct WindowDashLegend: View {
    let labels: [String]

    static let dashes: [[CGFloat]] = [[], [5, 3], [1.5, 2.5]]

    static func dash(for label: String, in labels: [String]) -> [CGFloat] {
        let index = labels.firstIndex(of: label) ?? 0
        return dashes[index % dashes.count]
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(labels, id: \.self) { label in
                HStack(spacing: 4) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 4))
                        p.addLine(to: CGPoint(x: 16, y: 4))
                    }
                    .stroke(Theme.onSurfaceVariant,
                            style: StrokeStyle(lineWidth: 1.5, dash: Self.dash(for: label, in: labels)))
                    .frame(width: 16, height: 8)
                    Text(label)
                        .font(Theme.Typography.token)
                        .foregroundStyle(Theme.onSurfaceVariant)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

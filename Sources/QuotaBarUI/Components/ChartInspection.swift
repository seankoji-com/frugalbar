import SwiftUI
import Charts
import QuotaBarCore

// Shared pieces that let a chart be interrogated: hover a point and read the
// exact recorded figure and when it was taken. Used by the History timeline,
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

/// The figure under the pointer: when it was recorded, and each window's
/// share used at that poll. Shape and words carry the state, never colour
/// alone.
struct ReadingReadout: View {
    struct Row: Identifiable {
        var id: String { label }
        let label: String
        let usedFraction: Double
        let isBlocked: Bool
        let urgency: Urgency
    }

    let timestamp: Date
    let rows: [Row]
    /// Include the day as well as the time: a range longer than a day.
    let showsDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.timestampText(timestamp, showsDate: showsDate))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.onSurface)
            ForEach(rows) { row in
                HStack(spacing: 4) {
                    Image(systemName: Self.symbol(for: row))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Self.color(for: row))
                    Text("\(row.label) \(Int((min(max(row.usedFraction, 0), 1) * 100).rounded()))% used\(row.isBlocked ? ", blocked" : "")")
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
        .accessibilityLabel(Self.spoken(timestamp: timestamp, rows: rows, showsDate: showsDate))
    }

    /// "Tue 14 Oct, 14:05" for a multi-day span, "14:05" within a day.
    static func timestampText(_ date: Date, showsDate: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = showsDate ? "EEE d MMM, HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }

    static func spoken(timestamp: Date, rows: [Row], showsDate: Bool) -> String {
        let figures = rows.map { row -> String in
            let percent = Int((min(max(row.usedFraction, 0), 1) * 100).rounded())
            return "\(WindowColumn.column(forLabel: row.label)?.spokenName ?? row.label) \(percent) percent used"
                + (row.isBlocked ? ", blocked" : "")
        }
        return (["Reading at \(timestampText(timestamp, showsDate: showsDate))"] + figures).joined(separator: ", ")
    }

    /// The point-shape vocabulary of the charts, as symbols.
    static func symbol(for row: Row) -> String {
        if row.isBlocked { return "square.fill" }
        if row.urgency == .critical { return "triangle.fill" }
        if row.urgency == .warning { return "diamond.fill" }
        return "circle.fill"
    }

    static func color(for row: Row) -> Color {
        if row.isBlocked || row.urgency == .critical { return Theme.error }
        if row.urgency == .warning { return Theme.tertiary }
        return Theme.healthy
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

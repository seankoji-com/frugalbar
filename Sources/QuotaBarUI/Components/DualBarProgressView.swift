import SwiftUI
import QuotaBarCore

/// Progress bar with pro-rata burndown pacing marker and exact colored delta:
/// - Red between marker and bar when usage is above pro-rata pace (over budget)
/// - Green between bar and marker when usage is below pro-rata pace (healthy buffer)
public struct DualBarProgressView: View {

    let metrics: DualBarMetrics
    let accentColor: Color
    let urgency: Urgency

    /// Track and fill thickness.
    static let barHeight: CGFloat = 8
    /// Pace marker height, and therefore the bar's layout height.
    static let tickHeight: CGFloat = 14

    public init(
        metrics: DualBarMetrics,
        accentColor: Color,
        urgency: Urgency
    ) {
        self.metrics = metrics
        self.accentColor = accentColor
        self.urgency = urgency
    }

    private var consumedPct: Double {
        max(0, min(1, metrics.primaryFraction))
    }

    /// nil when the vendor gave us no way to know how far through the window we
    /// are. The bar then shows consumption alone rather than measuring it
    /// against an invented target.
    private var targetPacePct: Double? {
        metrics.expectedPaceFraction.map { max(0, min(1, $0)) }
    }

    private var isExhausted: Bool {
        consumedPct >= 0.999
    }

    private var labelColor: Color {
        if isExhausted {
            return Theme.errorBold
        } else if let pace = targetPacePct, consumedPct > pace {
            return Color(red: 0.96, green: 0.72, blue: 0.15) // Bright warning yellow
        } else {
            return Theme.healthy // Vibrant green
        }
    }

    private var trackColor: Color {
        Color.white.opacity(0.08)
    }

    public var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let aX = consumedPct * w
                let mX = (targetPacePct ?? 0) * w
                let hasPace = targetPacePct != nil

                ZStack(alignment: .leading) {
                    // Track and every consumption/pace segment are flat
                    // rectangles clipped together to a single outer Capsule,
                    // so only the bar's two true ends round — an internal
                    // seam between two independently-capsuled segments (e.g.
                    // brand colour meeting the red overuse delta) used to
                    // leave a lens-shaped notch where their rounded caps met.
                    ZStack(alignment: .leading) {
                        // 1. Subtle background track across full width
                        Rectangle()
                            .fill(trackColor)
                            .frame(height: Self.barHeight)

                        if isExhausted {
                            // --- CASE 1: NOTHING LEFT ---
                            // Red end to end. Splitting this at the pace marker
                            // painted most of the bar in the vendor's brand colour
                            // and reddened only the tail, so a spent quota read as
                            // a mostly-healthy one with a red tip.
                            Rectangle()
                                .fill(Theme.errorBold)
                                .frame(width: w, height: Self.barHeight)
                                .shadow(color: Theme.errorBold.opacity(0.6), radius: 2)
                        } else if !hasPace {
                            // --- CASE 0: NO PACE TARGET ---
                            // Consumption only. Nothing here is measured against a
                            // number we did not receive.
                            if aX > 0 {
                                Rectangle()
                                    .fill(accentColor)
                                    .frame(width: max(4, aX), height: Self.barHeight)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }
                        } else if aX > mX {
                            // --- CASE 2: OVERUSE (Marker is INSIDE the bar: aX > mX) ---
                            // Actual usage bar within budget (0 -> mX) in vendor brand color
                            if mX > 0 {
                                Rectangle()
                                    .fill(accentColor)
                                    .frame(width: max(4, mX), height: Self.barHeight)
                            }

                            // Overuse delta segment between marker and actual usage (mX -> aX) in RED
                            if aX > mX {
                                Rectangle()
                                    .fill(Theme.error)
                                    .frame(width: max(4, aX - mX), height: Self.barHeight)
                                    .offset(x: mX)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }
                        } else if aX < mX {
                            // --- CASE 3: UNDERUSE (Marker is OUTSIDE the bar: aX < mX) ---
                            // Underuse buffer segment between actual usage and marker (aX -> mX) in GREEN
                            if mX > aX {
                                Rectangle()
                                    .fill(Theme.healthy)
                                    .frame(width: max(4, mX - aX), height: Self.barHeight)
                                    .offset(x: aX)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }

                            // Actual usage bar (0 -> aX) in vendor brand color
                            if aX > 0 {
                                Rectangle()
                                    .fill(accentColor)
                                    .frame(width: max(4, aX), height: Self.barHeight)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }
                        } else {
                            // --- CASE 4: AT PACE (aX == mX) ---
                            if aX > 0 {
                                Rectangle()
                                    .fill(accentColor)
                                    .frame(width: max(4, aX), height: Self.barHeight)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }
                        }
                    }
                    .frame(width: w, height: Self.barHeight, alignment: .leading)
                    .clipShape(Capsule())

                    // 3. Target Pace Marker (vertical white tick at mX)
                    if hasPace, mX > 0, mX < w {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 2.5, height: Self.tickHeight)
                            .offset(x: min(w - 2.5, max(0, mX - 1.25)))
                            .shadow(color: Color.black.opacity(0.65), radius: 2, x: 0, y: 0)
                    }
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            // Taller than the track so the 14pt pace tick has room to stand
            // proud of it instead of overflowing an 8pt layout box.
            .frame(height: Self.tickHeight)

            // The window token, always. Colour carries the state: green at or
            // under pace, amber ahead of it, red once it is spent.
            Text(metrics.label)
                .font(Theme.Typography.token)
                .tracking(Theme.Tracking.token)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: Theme.tokenColumnWidth, alignment: .trailing)
        }
        .help(helpText)
        .accessibilityHidden(true)
    }



    private var helpText: String {
        let usedPctInt = Int((consumedPct * 100).rounded())
        let detail = metrics.usedText ?? "\(usedPctInt)% used"
        guard let delta = metrics.burndownDelta else {
            return "\(metrics.label): \(usedPctInt)% used • \(detail)"
        }
        let deltaInt = Int((delta * 100).rounded())
        let paceStatus = deltaInt > 0
            ? "+\(deltaInt)% above pro-rata pace (overuse)"
            : "\(abs(deltaInt))% buffer behind pro-rata pace (healthy underuse)"
        return "\(metrics.label): \(usedPctInt)% used • \(paceStatus) • \(detail)"
    }
}







extension Color {
    init?(hexString: String) {
        var clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard let hex = UInt32(clean, radix: 16) else { return nil }
        if clean.count == 6 {
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b)
        } else {
            return nil
        }
    }
}

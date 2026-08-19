import SwiftUI
import QuotaBarCore

/// Progress bar with pro-rata burndown pacing marker and exact colored delta:
/// - Red between marker and bar when usage is above pro-rata pace (over budget)
/// - Green between bar and marker when usage is below pro-rata pace (healthy buffer)
public struct DualBarProgressView: View {

    let metrics: DualBarMetrics
    let accentColor: Color
    let urgency: Urgency

    public init(metrics: DualBarMetrics, accentColor: Color, urgency: Urgency) {
        self.metrics = metrics
        self.accentColor = accentColor
        self.urgency = urgency
    }

    private var consumedPct: Double {
        max(0, min(1, metrics.primaryFraction))
    }

    private var targetPacePct: Double {
        max(0, min(1, metrics.expectedPaceFraction ?? (metrics.label == "5H" ? 0.40 : (metrics.label == "WK" ? 0.45 : 0.50))))
    }

    private var isExhausted: Bool {
        consumedPct >= 0.999
    }

    private var labelColor: Color {
        if isExhausted {
            return Theme.error
        } else if consumedPct > targetPacePct {
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
                let mX = targetPacePct * w

                ZStack(alignment: .leading) {
                    // 1. Subtle background track across full width
                    Capsule()
                        .fill(trackColor)
                        .frame(height: 5.5)

                    if isExhausted {
                        // --- CASE 1: 100% EXHAUSTED ---
                        // Budget portion up to marker in vendor brand color
                        if mX > 0 {
                            Capsule()
                                .fill(accentColor)
                                .frame(width: max(4, mX), height: 5.5)
                        }

                        // Overage segment in bright glowing RED to the end
                        Capsule()
                            .fill(Theme.error)
                            .frame(width: max(4, w - mX), height: 5.5)
                            .offset(x: mX)
                            .shadow(color: Theme.error.opacity(0.6), radius: 2)
                    } else if aX > mX {
                        // --- CASE 2: OVERUSE (Marker is INSIDE the bar: aX > mX) ---
                        // Actual usage bar within budget (0 -> mX) in vendor brand color
                        if mX > 0 {
                            Capsule()
                                .fill(accentColor)
                                .frame(width: max(4, mX), height: 5.5)
                        }

                        // Overuse delta segment between marker and actual usage (mX -> aX) in RED
                        if aX > mX {
                            Capsule()
                                .fill(Theme.error)
                                .frame(width: max(4, aX - mX), height: 5.5)
                                .offset(x: mX)
                                .animation(.easeOut(duration: 0.35), value: consumedPct)
                        }
                    } else if aX < mX {
                        // --- CASE 3: UNDERUSE (Marker is OUTSIDE the bar: aX < mX) ---
                        // Underuse buffer segment between actual usage and marker (aX -> mX) in GREEN
                        if mX > aX {
                            Capsule()
                                .fill(Theme.healthy)
                                .frame(width: max(4, mX - aX), height: 5.5)
                                .offset(x: aX)
                                .animation(.easeOut(duration: 0.35), value: consumedPct)
                        }

                        // Actual usage bar (0 -> aX) in vendor brand color
                        if aX > 0 {
                            Capsule()
                                .fill(accentColor)
                                .frame(width: max(4, aX), height: 5.5)
                                .animation(.easeOut(duration: 0.35), value: consumedPct)
                        }
                    } else {
                        // --- CASE 4: AT PACE (aX == mX) ---
                        if aX > 0 {
                            Capsule()
                                .fill(accentColor)
                                .frame(width: max(4, aX), height: 5.5)
                                .animation(.easeOut(duration: 0.35), value: consumedPct)
                        }
                    }

                    // 3. Target Pace Marker (vertical white tick at mX)
                    if mX > 0 && mX < w {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2.0, height: 9.0)
                            .offset(x: min(w - 2.0, max(0, mX - 1.0)))
                            .shadow(color: Color.black.opacity(0.5), radius: 1.5, x: 0, y: 0)
                    }
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: 5.5)

            // High-contrast window interval label (5H, WK, MO) with dynamic color & warning icon on 100%
            HStack(spacing: 3) {
                if isExhausted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.error)
                }

                Text(metrics.label)
                    .font(.system(size: 9.5, weight: .bold))
                    .monospaced()
                    .foregroundStyle(labelColor)
            }
            .frame(width: 32, alignment: .trailing)
        }
        .help(helpText)
        .accessibilityHidden(true)
    }



    private var helpText: String {
        let deltaInt = Int(((consumedPct - targetPacePct) * 100).rounded())
        let paceStatus = deltaInt > 0 ? "+\(deltaInt)% above pro-rata pace (overuse)" : "\(abs(deltaInt))% buffer behind pro-rata pace (healthy underuse)"
        let usedPctInt = Int((consumedPct * 100).rounded())
        let detail = metrics.usedText ?? "\(usedPctInt)% used"
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

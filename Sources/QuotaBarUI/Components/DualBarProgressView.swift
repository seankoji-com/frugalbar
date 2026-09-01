import SwiftUI
import QuotaBarCore

/// Progress bar with pro-rata burndown pacing marker and exact colored delta:
/// - Red between marker and bar when usage is above pro-rata pace (over budget)
/// - Green between bar and marker when usage is below pro-rata pace (healthy buffer)
public struct DualBarProgressView: View {

    let metrics: DualBarMetrics
    let accentColor: Color

    /// Track and fill thickness.
    static let barHeight: CGFloat = 8
    /// Pace marker height, and therefore the bar's layout height.
    static let tickHeight: CGFloat = 14

    public init(
        metrics: DualBarMetrics,
        accentColor: Color
    ) {
        self.metrics = metrics
        self.accentColor = accentColor
    }

    /// nil when the vendor declared this window blocked/critical but reported
    /// no percentage — never coerced to 0 or 1 to give the bar something to
    /// draw against.
    private var consumedPct: Double? {
        metrics.primaryFraction.map { max(0, min(1, $0)) }
    }

    /// nil when the vendor gave us no way to know how far through the window we
    /// are. The bar then shows consumption alone rather than measuring it
    /// against an invented target.
    private var targetPacePct: Double? {
        metrics.expectedPaceFraction.map { max(0, min(1, $0)) }
    }

    /// Only ever evaluated once `hasNoReading` has already routed the nil
    /// case away (see `body` and `labelColor`), so the `?? 0` here never
    /// stands in as a fabricated "not exhausted" verdict for an unmeasured
    /// window.
    private var isExhausted: Bool {
        (consumedPct ?? 0) >= 0.999
    }

    /// The vendor's own colour, honoured only for a window the vendor itself
    /// declared blocked. That per-bar flag is the one case where the vendor
    /// knows something the pace/exhaustion arithmetic below cannot derive —
    /// a blocked window with a low percentage used to still render green.
    ///
    /// Deliberately *not* also keyed on `urgency == .critical`. `urgency` is
    /// the whole snapshot's, applied to every one of its bars, and
    /// `blockedColor` is a brand colour for the vendors that use it. Letting
    /// critical urgency pull it in painted a spent OpenAI bar green and
    /// repainted the snapshot's still-healthy weekly/monthly bars along with
    /// it.
    private var vendorStatusColor: Color? {
        guard metrics.isBlocked else { return nil }
        return metrics.blockedColor.flatMap(Color.init(hexString:))
    }

    /// The colour a blocked placeholder must fall back to when the vendor gave
    /// no colour of its own: the shared error tone, so a hatched placeholder,
    /// its stroke, and an exhausted-fill bar all agree rather than drawing the
    /// same state in different colours.
    private var blockedFillColor: Color {
        vendorStatusColor ?? Theme.errorBold
    }

    /// True whenever the vendor gave no percentage to measure this window
    /// with, blocked or not. The umbrella guard that keeps every fraction
    /// below (`aX`, `isExhausted`, the pace comparison in `labelColor`) from
    /// ever substituting a coerced 0 for a reading that does not exist —
    /// `DualBarMetrics(primaryFraction: nil, expectedPaceFraction: 0.5)` must
    /// never render as "0% used" against a real pace marker.
    private var hasNoReading: Bool {
        metrics.primaryFraction == nil
    }

    /// True exactly in the case the vendor told us "blocked" but gave no
    /// percentage to measure it with. The bar still has to draw *something*
    /// here — omitting it entirely reads as "nothing to report" rather than
    /// "this window is blocked" — but it must not fabricate a fraction to do
    /// it.
    private var isBlockedWithoutReading: Bool {
        metrics.isBlocked && hasNoReading
    }

    private var labelColor: Color {
        if let vendorStatusColor {
            return vendorStatusColor
        } else if isBlockedWithoutReading {
            // Matches the hatched placeholder bar's own fallback below
            // (`vendorStatusColor ?? Theme.errorBold`) — a blocked window
            // with no vendor colour and no reading must not show a label in
            // one colour beside a bar drawn in another.
            return Theme.errorBold
        } else if hasNoReading {
            // No reading and not vendor-flagged blocked: neutral, not a
            // fabricated "healthy" green.
            return Theme.outline
        } else if isExhausted {
            return Theme.errorBold
        } else if let pace = targetPacePct, let consumedPct, consumedPct > pace {
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
                let aX = (consumedPct ?? 0) * w
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

                        if isBlockedWithoutReading {
                            // --- CASE B: BLOCKED, NO READING ---
                            // The vendor told us this window cannot be used at
                            // all but gave no percentage. Omitting the bar
                            // here used to read as "nothing to report"; a
                            // hatched placeholder in the vendor's declared
                            // status colour says "blocked" without inventing
                            // a fraction to fill it with.
                            RoundedRectangle(cornerRadius: Self.barHeight / 2)
                                .fill(blockedFillColor.opacity(0.30))
                                .frame(width: w, height: Self.barHeight)
                            RoundedRectangle(cornerRadius: Self.barHeight / 2)
                                .strokeBorder(
                                    blockedFillColor,
                                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                                )
                                .frame(width: w, height: Self.barHeight)
                        } else if hasNoReading {
                            // --- CASE B': NO READING, NOT BLOCKED ---
                            // The vendor gave no percentage but isn't
                            // reporting the window blocked either — e.g. a
                            // real pace target with no usage to compare it
                            // against. The track alone is drawn above; adding
                            // a fill here would mean inventing a 0% reading
                            // this window never reported.
                        } else if isExhausted {
                            // --- CASE 1: NOTHING LEFT ---
                            // Red end to end. Splitting this at the pace marker
                            // painted most of the bar in the vendor's brand colour
                            // and reddened only the tail, so a spent quota read as
                            // a mostly-healthy one with a red tip.
                            Rectangle()
                                .fill(blockedFillColor)
                                .frame(width: w, height: Self.barHeight)
                                .shadow(color: blockedFillColor.opacity(0.6), radius: 2)
                        } else if !hasPace {
                            // --- CASE 0: NO PACE TARGET ---
                            // Consumption only. Nothing here is measured against a
                            // number we did not receive.
                            if aX > 0 {
                                Rectangle()
                                    .fill(vendorStatusColor ?? accentColor)
                                    .frame(width: max(4, aX), height: Self.barHeight)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }
                        } else if aX > mX {
                            // --- CASE 2: OVERUSE (Marker is INSIDE the bar: aX > mX) ---
                            // Actual usage bar within budget (0 -> mX) in vendor
                            // brand color, or the vendor's declared blocked
                            // colour when this bar's own isBlocked flag is set —
                            // reaching pace is not "fine" for a window the
                            // vendor has already cut off.
                            if mX > 0 {
                                Rectangle()
                                    .fill(vendorStatusColor ?? accentColor)
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
                            // Underuse buffer segment between actual usage and
                            // marker (aX -> mX) in GREEN — but never for a
                            // blocked window: "healthy margin before budget"
                            // is exactly the false-health reading vendorStatusColor
                            // exists to prevent, and pace alone can't override that.
                            if mX > aX, !metrics.isBlocked {
                                Rectangle()
                                    .fill(Theme.healthy)
                                    .frame(width: max(4, mX - aX), height: Self.barHeight)
                                    .offset(x: aX)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }

                            // Actual usage bar (0 -> aX) in vendor brand color,
                            // or the vendor's declared blocked colour when
                            // this bar's own isBlocked flag is set.
                            if aX > 0 {
                                Rectangle()
                                    .fill(vendorStatusColor ?? accentColor)
                                    .frame(width: max(4, aX), height: Self.barHeight)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }
                        } else {
                            // --- CASE 4: AT PACE (aX == mX) ---
                            if aX > 0 {
                                Rectangle()
                                    .fill(vendorStatusColor ?? accentColor)
                                    .frame(width: max(4, aX), height: Self.barHeight)
                                    .animation(.easeOut(duration: 0.35), value: consumedPct)
                            }
                        }
                    }
                    .frame(width: w, height: Self.barHeight, alignment: .leading)
                    .clipShape(Capsule())

                    // 3. Target Pace Marker (vertical white tick at mX)
                    if hasPace, mX > 0, mX < w, !isBlockedWithoutReading {
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
                // Most window codes are two characters and need no scaling —
                // that's what kept the column from looking ragged when every
                // label shrank together regardless of length. But not every
                // label is two characters: GitHub's REST/GraphQL rows, an
                // absent-limit OpenAI "PLAN", and the hand-entered "CYCLE"
                // row all run longer, and were truncating silently without a
                // fallback. Only those get scaled.
                .minimumScaleFactor(metrics.label.count > 2 ? 0.6 : 1.0)
                .frame(width: Theme.tokenColumnWidth, alignment: .trailing)
        }
        .help(helpText)
        .accessibilityHidden(true)
    }



    /// The fallback detail shown for a window with no percentage. Blocked
    /// windows name the state plainly; a window that is merely unmeasured
    /// (e.g. a real pace target with no usage to compare it against) is not
    /// "blocked" and must not say it is.
    static func blockedFallbackDetail(for metrics: DualBarMetrics) -> String {
        if let usedText = metrics.usedText {
            return usedText
        }
        return metrics.isBlocked
            ? "blocked • no reading reported"
            : "no reading reported"
    }

    private var helpText: String {
        guard let consumedPct else {
            // No percentage with no usedText: say so plainly rather than
            // printing a "0% used" that would misreport an unmeasured window
            // as an empty one — and don't call an unmeasured window "blocked"
            // unless the vendor actually declared it so.
            let detail = Self.blockedFallbackDetail(for: metrics)
            return "\(metrics.label): \(detail)"
        }
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

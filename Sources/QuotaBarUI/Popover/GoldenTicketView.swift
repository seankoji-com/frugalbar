import SwiftUI

enum GoldenTicketGlintState {
    static func motionAdjusted(isGlinting: Bool, reduceMotion: Bool) -> Bool {
        reduceMotion ? false : isGlinting
    }
}

/// One banked reset credit, drawn as a golden ticket.
///
/// The action is deliberately small: a soft gold gradient, a scale lift while
/// a single sparkle glints, and a pause between glints. There is no continuous
/// shimmer — five of these sit in one row, and constant motion there competes
/// with the quota bars beside them.
struct GoldenTicketView: View {
    /// Staggers the glint so a run of tickets does not flash in unison.
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glint = false

    private static let light = Color(red: 1.00, green: 0.93, blue: 0.68)
    private static let gold = Color(red: 0.94, green: 0.72, blue: 0.25)
    private static let deep = Color(red: 0.66, green: 0.43, blue: 0.10)

    var body: some View {
        Image(systemName: "ticket.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                LinearGradient(colors: [Self.light, Self.gold, Self.deep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "sparkle")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .opacity(glint ? 1 : 0)
                    .scaleEffect(glint ? 1 : 0.25)
                    .offset(x: 2, y: -1)
                    .shadow(color: .white.opacity(0.55), radius: 1.5)
            }
            .scaleEffect(glint ? 1.05 : 1)
            .shadow(color: Self.gold.opacity(0.25), radius: 2, y: 0.5)
            .animation(.easeOut(duration: 0.22), value: glint)
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                // Stagger the first glint, then leave several seconds of calm
                // between them. `.task` cancels when the row scrolls away.
                try? await Task.sleep(for: .seconds(2.2 + Double(index) * 0.7))
                while !Task.isCancelled {
                    glint = true
                    try? await Task.sleep(for: .seconds(0.42))
                    glint = false
                    try? await Task.sleep(for: .seconds(4.4 + Double(index) * 0.55))
                }
            }
            .onChange(of: reduceMotion) { _, enabled in
                glint = GoldenTicketGlintState.motionAdjusted(
                    isGlinting: glint, reduceMotion: enabled
                )
            }
    }
}

import SwiftUI

/// Design system tokens for QuotaBar matching DESIGN.md and stitch designs.
public enum Theme {
    // MARK: - Surface colors
    /// The page behind the cards. Near-black rather than the previous #121317
    /// so the card surface below reads as genuinely lifted off it. The floating
    /// card look needs contrast between ground and card; translucent cards on a
    /// near-identical ground collapsed the whole popover into one slab.
    public static let surface = Color(red: 0x0a / 255.0, green: 0x0a / 255.0, blue: 0x0b / 255.0)              // #0a0a0b
    public static let surfaceDim = Color(red: 0x0a / 255.0, green: 0x0a / 255.0, blue: 0x0b / 255.0)           // #0a0a0b

    /// Card fill. Solid on purpose: stacking `.opacity()` over a near-identical
    /// ground is what made the old cards indistinguishable from the page.
    public static let card = Color(red: 0x1c / 255.0, green: 0x1d / 255.0, blue: 0x20 / 255.0)                 // #1c1d20
    public static let surfaceContainerLow = Color(red: 0x1a / 255.0, green: 0x1b / 255.0, blue: 0x1f / 255.0)  // #1a1b1f
    public static let surfaceContainer = Color(red: 0x1e / 255.0, green: 0x1f / 255.0, blue: 0x23 / 255.0)     // #1e1f23
    public static let surfaceContainerHigh = Color(red: 0x29 / 255.0, green: 0x2a / 255.0, blue: 0x2e / 255.0) // #292a2e
    public static let surfaceContainerHighest = Color(red: 0x34 / 255.0, green: 0x35 / 255.0, blue: 0x39 / 255.0) // #343539
    public static let surfaceContainerLowest = Color(red: 0x0d / 255.0, green: 0x0e / 255.0, blue: 0x12 / 255.0) // #0d0e12

    // MARK: - Content colors
    public static let onSurface = Color(red: 0xe3 / 255.0, green: 0xe2 / 255.0, blue: 0xe7 / 255.0)        // #e3e2e7
    public static let onSurfaceVariant = Color(red: 0xc1 / 255.0, green: 0xc6 / 255.0, blue: 0xd7 / 255.0) // #c1c6d7
    public static let outline = Color(red: 0x8b / 255.0, green: 0x90 / 255.0, blue: 0xa0 / 255.0)          // #8b90a0
    public static let outlineVariant = Color(red: 0x41 / 255.0, green: 0x47 / 255.0, blue: 0x55 / 255.0)   // #414755

    // MARK: - Accent & Status colors
    public static let primary = Color(red: 0xad / 255.0, green: 0xc6 / 255.0, blue: 0xff / 255.0)          // #adc6ff
    public static let secondary = Color(red: 0x53 / 255.0, green: 0xe1 / 255.0, blue: 0x6f / 255.0)        // #53e16f (success / healthy neon green)
    public static let healthy = Color(red: 0x53 / 255.0, green: 0xe1 / 255.0, blue: 0x6f / 255.0)          // #53e16f (healthy underuse buffer green)
    public static let tertiary = Color(red: 0xff / 255.0, green: 0xb8 / 255.0, blue: 0x74 / 255.0)         // #ffb874 (warning orange)
    public static let tertiaryContainer = Color(red: 0xd4 / 255.0, green: 0x7b / 255.0, blue: 0x00 / 255.0)// #d47b00
    public static let error = Color(red: 0xff / 255.0, green: 0xb4 / 255.0, blue: 0xab / 255.0)            // #ffb4ab (critical coral red)
    public static let errorContainer = Color(red: 0x93 / 255.0, green: 0x00 / 255.0, blue: 0x0a / 255.0)   // #93000a
    /// Saturated red for filled shapes. `error` is tuned for text on a dark
    /// ground and reads as pink once it is 8pt tall and 130pt wide — which put
    /// an exhausted quota and a merely over-pace one in the same colour. The
    /// over-pace delta keeps `error`; only "there is nothing left" gets this.
    public static let errorBold = Color(red: 0xe5 / 255.0, green: 0x3d / 255.0, blue: 0x3d / 255.0)        // #e53d3d


    // MARK: - Spacing & Geometry
    public static let popoverWidth: CGFloat = 384
    public static let edgeMargin: CGFloat = 12
    public static let sectionGap: CGFloat = 12
    public static let stackGap: CGFloat = 6
    public static let cornerRadius: CGFloat = 16
    /// Breathing room inside a card, distinct from the gutter between cards.
    public static let cardPadding: CGFloat = 14
    /// Comfortable row height. Two lines of 17pt/12.5pt text plus padding, or
    /// up to three stacked window bars, both land near this.
    public static let rowMinHeight: CGFloat = 56

    /// Width of the vendor name column. Sized so the longest string that can
    /// land there — "Resets on 1st of month", 134pt at `subtitle` — fits
    /// without `minimumScaleFactor` engaging. Auto-shrink is itself an
    /// inconsistency: it renders one row's subtitle a point smaller than its
    /// neighbours', which is exactly what made the rows look mismatched.
    public static let nameColumnWidth: CGFloat = 132

    /// Shared by the bar labels and the spend-window labels, so every token in
    /// the popover sits in one right-aligned column. 40pt fits the two-letter
    /// windows with room to spare; only the developer-limits section, which is
    /// suppressed unless a limit is elevated, has longer names.
    public static let tokenColumnWidth: CGFloat = 40

    // MARK: - Typography

    /// One scale, one role per token.
    ///
    /// The popover previously carried seventeen distinct font declarations
    /// across nine sizes and five weights, and set the same role — a plan name,
    /// a money figure — differently in different rows. Roles are distinguished
    /// by size and colour; weight is held as steady as the hierarchy allows.
    public enum Typography {
        /// Card headings.
        public static let cardTitle = Font.system(size: 20, weight: .semibold)
        /// Body copy inside a card.
        public static let cardBody  = Font.system(size: 14.5, weight: .regular)
        /// Primary call to action.
        public static let button    = Font.system(size: 16, weight: .semibold)

        /// Vendor names. Semibold, not bold: at 17pt in a 384pt popover bold
        /// reads as shouting, and every row shouting is the same as none.
        public static let title     = Font.system(size: 17, weight: .semibold)
        /// Plan names and reset text. One treatment for both — colour tells
        /// them apart, never size or weight.
        public static let subtitle  = Font.system(size: 12.5, weight: .regular)
        /// Every money figure in a row, balance and spend alike. Monospaced
        /// digits so the column does not jitter between refreshes.
        public static let numeric   = Font.system(size: 15, weight: .semibold).monospacedDigit()
        /// Boxed values in the no-denominator fallback layout.
        public static let chip      = Font.system(size: 12.5, weight: .semibold).monospacedDigit()
        /// Window tokens (5H / WK / MO / 1D). Monospaced so a stacked column
        /// has one width whatever the labels are.
        public static let token     = Font.system(size: 10.5, weight: .bold).monospaced()

        public static let footer     = Font.system(size: 12.5, weight: .semibold)
        public static let footerMeta = Font.system(size: 11, weight: .regular).monospacedDigit()
    }

    /// Tracking is a `Text` modifier rather than part of `Font`, so it travels
    /// alongside the scale. Large text tightens; small tokens open up.
    public enum Tracking {
        public static let cardTitle: CGFloat = -0.3
        public static let title: CGFloat = -0.2
        public static let numeric: CGFloat = -0.1
        // 0.8 was too loose on a monospaced face — the glyphs are already
        // padded to a fixed advance, so added tracking reads as "5 H".
        public static let token: CGFloat = 0.3
    }
}


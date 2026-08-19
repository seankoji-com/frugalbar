import SwiftUI

/// Design system tokens for QuotaBar matching DESIGN.md and stitch designs.
public enum Theme {
    // MARK: - Surface colors
    public static let surface = Color(red: 0x12 / 255.0, green: 0x13 / 255.0, blue: 0x17 / 255.0)              // #121317
    public static let surfaceDim = Color(red: 0x12 / 255.0, green: 0x13 / 255.0, blue: 0x17 / 255.0)           // #121317
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


    // MARK: - Spacing & Geometry
    public static let popoverWidth: CGFloat = 368
    public static let edgeMargin: CGFloat = 12
    public static let sectionGap: CGFloat = 12
    public static let stackGap: CGFloat = 6
    public static let cornerRadius: CGFloat = 12
}


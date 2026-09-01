import SwiftUI
import AppKit
import QuotaBarCore

/// Official branded vector and pixel definitions for each vendor.
public enum VendorSVGLogo {
    public static func nsImage(for vendor: VendorIdentifier) -> NSImage? {
        let svg = svgString(for: vendor)
        if let data = svg.data(using: .utf8), let img = NSImage(data: data) {
            return img
        }
        if let base64 = base64Png(for: vendor),
           let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let img = NSImage(data: data) {
            return img
        }
        return nil
    }

    public static func base64Png(for vendor: VendorIdentifier) -> String? {
        VendorAssetData.base64Png(for: vendor)
    }

    public static func svgString(for vendor: VendorIdentifier) -> String {
        switch vendor {
        case .claude:
            return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 3.5 24 17" width="24" height="24">
              <path clip-rule="evenodd"
                    d="M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z"
                    fill="#D97757"
                    fill-rule="evenodd" />
            </svg>
            """
        case .openai:
            // Official mark. The source ships `fill="currentColor"` and `1em`
            // dimensions, neither of which means anything to NSImage — there is
            // no CSS context offscreen — so the fill is explicit and the badge
            // padding comes from an oversized viewBox rather than a `<g
            // transform>`, which macOS SVG support handles unevenly.
            return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="-4 -4 32 32" width="24" height="24">
              <rect x="-4" y="-4" width="32" height="32" rx="6" fill="#10A37F"/>
              <path fill="#FFFFFF" fill-rule="evenodd"
                    d="M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z" />
            </svg>
            """
        case .gemini:
            return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none">
              <path fill="url(#gemini-grad)" d="M12 0 C12 7.2 16.8 12 24 12 C16.8 12 12 16.8 12 24 C12 16.8 7.2 12 0 12 C7.2 12 12 7.2 12 0 Z"/>
              <defs>
                <linearGradient id="gemini-grad" x1="0" y1="0" x2="24" y2="24" gradientUnits="userSpaceOnUse">
                  <stop offset="0.0" stop-color="#FF5555"/>
                  <stop offset="0.25" stop-color="#E8C838"/>
                  <stop offset="0.6" stop-color="#38A8F8"/>
                  <stop offset="1.0" stop-color="#28B868"/>
                </linearGradient>
              </defs>
            </svg>
            """
        case .opencode:
            return """
            <svg viewBox="0 0 24 24" width="24" height="24" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect width="24" height="24" rx="4.5" fill="#0f0f11"/>
              <rect x="5.5" y="3.5" width="13" height="17" rx="1.5" fill="#EDEDED"/>
              <rect x="7.5" y="5.5" width="9" height="5" fill="#18181b"/>
              <rect x="7.5" y="10.5" width="9" height="7.5" fill="#4B4B4B"/>
            </svg>
            """
        case .copilot:
            return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 84" width="24" height="24" fill="none">
              <rect width="100" height="84" rx="18" fill="#18181b"/>
              <path d="M60.18,50.87c2.29,0,4.15,1.86,4.15,4.15v8.3c0,2.29-1.86,4.15-4.15,4.15s-4.15-1.86-4.15-4.15v-8.3c0-2.29,1.86-4.15,4.15-4.15Z" fill="#ffffff"/>
              <path d="M43.59,55.02c0-2.29-1.86-4.15-4.15-4.15s-4.15,1.86-4.15,4.15v8.3c0,2.29,1.86,4.15,4.15,4.15s4.15-1.86,4.15-4.15v-8.3Z" fill="#ffffff"/>
              <path d="M99.19,62.25c-3.57,6.2-24.29,20.83-49.42,20.83S3.91,68.45.35,62.25c-.26-.45-.35-.97-.35-1.49v-11.03c0-.46.07-.91.24-1.34,1.54-3.87,5.58-9.5,10.8-11.01.69-1.78,1.72-4.37,2.67-6.29-.16-1.47-.22-2.98-.22-4.5,0-5.52,1.17-10.36,4.69-13.96,1.65-1.68,3.69-2.97,6.11-3.95C30.1,3.96,38.36,0,49.68,0s19.76,3.96,25.56,8.68c2.42.97,4.46,2.26,6.11,3.95,3.52,3.6,4.69,8.44,4.69,13.96,0,1.53-.06,3.04-.22,4.5.96,1.92,1.98,4.51,2.67,6.29,5.22,1.51,9.26,7.14,10.8,11.01.17.42.24.88.24,1.34v11.03c0,.52-.08,1.04-.35,1.49ZM53.14,25.25c-.18-1.37-.26-2.61-.26-3.7v-.09c0-3.19.7-5.27,1.82-6.54,1.41-1.62,4.34-2.86-10.5-2.19,6.24.68,9.73,2.22,11.71,4.25,1.92,1.96,2.92,4.89,2.92,9.61,0,5.02-.72,7.99-2.31,9.79-1.51,1.72-4.49,3.11-11.02,3.11-5.02,0-7.88-1.63-9.72-3.89-1.97-2.42-3.08-5.97-3.64-10.35ZM46.4,25.25c.18-1.37.26-2.61.26-3.7v-.09c0-3.19-.7-5.27-1.82-6.54-1.41-1.62-4.34-2.86-10.5-2.19-6.24.68-9.73,2.22-11.71,4.25-1.92,1.96-2.92,4.89-2.92,9.61,0,5.02.72,7.99,2.31,9.79,1.51,1.72,4.49,3.11,11.02,3.11,5.02,0,7.88-1.63,9.72-3.89,1.97-2.42,3.08-5.97,3.64-10.35ZM50.48,37.41h-.31c-.38,0-.94,0-1.12,0-.44.73-.93,1.44-1.47,2.11-3.19,3.93-7.95,6.18-14.54,6.18-7.15,0-12.39-1.49-15.68-5.22-.19-.21-.35-.43-.35-.43l-.4.43v27.3c5.95,3.23,18.71,9.03,33.16,9.03s27.22-5.8,33.16-9.03v-27.3l-.4-.43s-.14.19-.35.43c-3.29,3.73-8.53,5.22-15.68,5.22-6.59,0-11.35-2.26-14.54-6.18-.54-.67-1.03-1.37-1.47-2.11Z" fill="#ffffff" fill-rule="evenodd"/>
            </svg>
            """
        case .openrouter:
            return """
            <svg viewBox="0 0 24 24" width="24" height="24" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect width="24" height="24" rx="4.5" fill="#1e1b4b"/>
              <path fill="#6366F1" d="M18.654 3.87a5.087 5.087 0 110 10.174L23.7 19.09c.64.641.187 1.737-.72 1.737H8.48a8.479 8.479 0 010-16.958h10.175zM8.479 7.26a5.087 5.087 0 100 10.176 5.087 5.087 0 000-10.175z"/>
            </svg>
            """
        case .grok:
            // The xAI Grok mark used since February 2025. The two `#mark` paths
            // of the official logotype carry the glyph; the rest of that SVG is
            // the "Grok" wordmark, which has no place in a 24pt badge. They are
            // drawn at their native coordinates inside a viewBox sized to the
            // mark (plus margin) so there is no `<g transform>`, which macOS
            // SVG support handles unevenly.
            return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="-1.5 -1 36 36" width="24" height="24" fill="none">
              <rect x="-1.5" y="-1" width="36" height="36" rx="7" fill="#000000"/>
              <path fill="#ffffff" d="M13.2371 21.0407L24.3186 12.8506C24.8619 12.4491 25.6384 12.6057 25.8973 13.2294C27.2597 16.5185 26.651 20.4712 23.9403 23.1851C21.2297 25.8989 17.4581 26.4941 14.0108 25.1386L10.2449 26.8843C15.6463 30.5806 22.2053 29.6665 26.304 25.5601C29.5551 22.3051 30.562 17.8683 29.6205 13.8673L29.629 13.8758C28.2637 7.99809 29.9647 5.64871 33.449 0.844576C33.5314 0.730667 33.6139 0.616757 33.6964 0.5L29.1113 5.09055V5.07631L13.2343 21.0436"/>
              <path fill="#ffffff" d="M10.9503 23.0313C7.07343 19.3235 7.74185 13.5853 11.0498 10.2763C13.4959 7.82722 17.5036 6.82767 21.0021 8.2971L24.7595 6.55998C24.0826 6.07017 23.215 5.54334 22.2195 5.17313C17.7198 3.31926 12.3326 4.24192 8.67479 7.90126C5.15635 11.4239 4.0499 16.8403 5.94992 21.4622C7.36924 24.9165 5.04257 27.3598 2.69884 29.826C1.86829 30.7002 1.0349 31.5745 0.36364 32.5L10.9474 23.0341"/>
            </svg>
            """
        case .kiro:
            return """
            <svg viewBox="0 0 24 24" width="24" height="24" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect width="24" height="24" rx="4.5" fill="#9046ff"/>
              <path fill="#ffffff" d="M13.4 3.5L6.6 12.9h4.1l-1.1 7.6 6.8-9.4h-4.1l1.1-7.6z"/>
            </svg>
            """
        case .devpass:
            return """
            <svg viewBox="0 0 24 24" width="24" height="24" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect width="24" height="24" rx="4.5" fill="#0f3d3a"/>
              <path fill="#00b8a9" d="M4 8.5A1.5 1.5 0 015.5 7h13A1.5 1.5 0 0120 8.5v2a1.75 1.75 0 000 3.5v2A1.5 1.5 0 0118.5 17h-13A1.5 1.5 0 014 15.5v-2a1.75 1.75 0 000-3.5v-2zm5.6 1.1v4.8h1.5v-1.6h.9a1.6 1.6 0 100-3.2H9.6zm1.5 1.2h.7a.4.4 0 010 .8h-.7v-.8z"/>
            </svg>
            """
        case .githubRest, .githubGraphql:
            return """
            <svg viewBox="0 0 24 24" width="24" height="24" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect width="24" height="24" rx="4.5" fill="#24292f"/>
              <path fill="#ffffff" d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/>
            </svg>
            """
        }
    }
}


/// Vendor avatar badge rendering the official brand SVG plus a status dot,
/// or a red ✗ in place of the logo once a window is fully spent.
public struct VendorAvatarView: View {

    let vendorId: VendorIdentifier
    let status: ProviderStatus
    /// Strikes the brand mark through with a ✗ and fades it back. The vendor
    /// still has to be identifiable at a glance — the row is read by its logo
    /// before its name — so the mark stays and the ✗ sits over it.
    let isExhausted: Bool
    let size: CGFloat

    public init(
        vendorId: VendorIdentifier,
        status: ProviderStatus,
        isExhausted: Bool = false,
        size: CGFloat = 32
    ) {
        self.vendorId = vendorId
        self.status = status
        self.isExhausted = isExhausted
        self.size = size
    }

    @ViewBuilder
    private var mark: some View {
        if let nsImg = VendorSVGLogo.nsImage(for: vendorId) {
            Image(nsImage: nsImg)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
        } else {
            RoundedRectangle(cornerRadius: size * 0.23)
                .fill(Color(hexString: vendorId.accentColorHex) ?? Theme.primary)
                .frame(width: size, height: size)
        }
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                // Faded rather than hidden: enough to keep the vendor
                // recognisable, dim enough that the ✗ is what registers first.
                mark.opacity(isExhausted ? 0.40 : 1)

                if isExhausted {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.78, weight: .heavy))
                        .foregroundStyle(Theme.error)
                }
            }
            .frame(width: size, height: size)

            // The ✗ already says everything the dot would, louder.
            if !isExhausted {
                StatusIndicatorDot(status: status)
                    .offset(x: 3, y: -3)
            }
        }
        .frame(width: size, height: size)
    }
}


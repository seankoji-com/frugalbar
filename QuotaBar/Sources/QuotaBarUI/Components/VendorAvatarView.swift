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


/// 20x20 vendor avatar badge rendering official brand SVG and status dot.
public struct VendorAvatarView: View {

    let vendorId: VendorIdentifier
    let status: ProviderStatus

    public init(vendorId: VendorIdentifier, status: ProviderStatus) {
        self.vendorId = vendorId
        self.status = status
    }

    private var isCritical: Bool { status.urgency == .critical }
    private var isWarning: Bool { status.urgency == .warning }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImg = VendorSVGLogo.nsImage(for: vendorId) {
                Image(nsImage: nsImg)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5.5))
            } else {
                RoundedRectangle(cornerRadius: 5.5)
                    .fill(Color(hexString: vendorId.accentColorHex) ?? Theme.primary)
                    .frame(width: 24, height: 24)
            }

            if isCritical {
                Circle()
                    .fill(Theme.error)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 1))
                    .shadow(color: Theme.error.opacity(0.8), radius: 2)
                    .offset(x: 2.5, y: -2.5)
            } else if isWarning {
                Circle()
                    .fill(Theme.tertiary)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 1))
                    .shadow(color: Theme.tertiary.opacity(0.6), radius: 1.5)
                    .offset(x: 2.5, y: -2.5)
            }
        }
        .frame(width: 24, height: 24)
    }
}



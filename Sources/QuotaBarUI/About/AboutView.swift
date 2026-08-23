import SwiftUI
import AppKit
import QuotaBarCore

/// The About window.
///
/// Replaces `NSApp.orderFrontStandardAboutPanel`, which reads its contents out
/// of `Bundle.main` — empty for the bare executable a release actually ships,
/// so the panel came up with the process name and nothing else.
public struct AboutView: View {

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                mark

                VStack(spacing: 3) {
                    Text(AppInfo.name)
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(Theme.Tracking.cardTitle)
                        .foregroundStyle(Theme.onSurface)

                    Text(AppInfo.versionDisplay)
                        .font(Theme.Typography.subtitle)
                        .monospacedDigit()
                        .foregroundStyle(Theme.onSurfaceVariant.opacity(0.85))
                        .textSelection(.enabled)
                }

                Text(AppInfo.tagline)
                    .font(Theme.Typography.cardBody)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.onSurface.opacity(0.90))
                    .fixedSize(horizontal: false, vertical: true)

                Text(AppInfo.principle)
                    .font(Theme.Typography.subtitle)
                    .lineSpacing(1.5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.onSurfaceVariant.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                linkButton("Source", url: AppInfo.repositoryURL)
                linkButton("Report an issue", url: AppInfo.issuesURL)
            }

            Text(AppInfo.copyright)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.onSurfaceVariant.opacity(0.55))
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .frame(width: 360)
        .background(Theme.surface)
    }

    /// No icon ships with the app, so the mark is drawn rather than loaded —
    /// a placeholder bundle icon would look more broken than this does.
    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
                .frame(width: 64, height: 64)

            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.healthy)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.outlineVariant.opacity(0.35), lineWidth: 0.5)
        )
    }

    private func linkButton(_ title: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .font(Theme.Typography.subtitle.weight(.semibold))
                .foregroundStyle(Theme.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.surfaceContainerHigh))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

/// Owns the single About window, so repeated menu clicks raise the existing one
/// instead of stacking copies.
@MainActor
public enum AboutWindow {

    private static var window: NSWindow?

    public static func show() {
        // The app runs as an accessory, so it has to be activated explicitly or
        // the window opens behind whatever the user was in.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: AboutView())
        let created = NSWindow(contentViewController: hosting)
        created.title = "About \(AppInfo.name)"
        created.styleMask = [.titled, .closable, .fullSizeContentView]
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.isMovableByWindowBackground = true
        created.appearance = NSAppearance(named: .darkAqua)
        created.backgroundColor = NSColor.black
        created.isReleasedWhenClosed = false
        created.center()

        window = created
        created.makeKeyAndOrderFront(nil)
    }
}

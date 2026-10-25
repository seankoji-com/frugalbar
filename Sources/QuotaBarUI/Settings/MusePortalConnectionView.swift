import SwiftUI
import WebKit
import QuotaBarCore

struct MusePortalConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session = MusePortalSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Muse portal quota").font(.headline)
            Text("Sign in with the same Meta account as Muse CLI. Refresh teams, then explicitly select the team holding your Muse subscription. Only published usage is read; no model request is made.")
                .font(.caption)
            HStack {
                Picker("Subscription team", selection: $session.selectedTeamID) {
                    Text("Choose a team").tag("")
                    ForEach(session.teamPickerOptions) { team in Text(team.name).tag(team.id) }
                }.disabled(!session.isEnabled || session.isDisconnecting)
                // The read and its in-flight flag belong to the session, which
                // outlives this sheet and clears the flag on every exit.
                Button("Refresh teams") {
                    Task { await session.refreshTeams() }
                }.disabled(session.isReadingTeams || !session.isEnabled || session.isDisconnecting)
            }
            Text(session.message).font(.caption)
            if let webView = session.webView { MusePortalWebView(webView: webView) }
            HStack {
                Text("This app keeps your Meta sign-in and team after restart. Disconnect clears only this app's Meta session.").font(.caption)
                Spacer()
                Button("Disconnect") {
                    Task { await session.disconnect(); dismiss() }
                }.disabled(session.isDisconnecting)
                Button("Done") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 800, height: 660)
        // Disconnecting in the parent Settings pane takes the session's web
        // view away, so this sheet has nothing left to show.
        .onChange(of: session.isEnabled) { _, enabled in
            if !enabled { dismiss() }
        }
    }
}

private struct MusePortalWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MusePortalSession.shared.hostWebView()
    }
}

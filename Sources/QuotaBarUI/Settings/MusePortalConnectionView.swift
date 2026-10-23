import SwiftUI
import WebKit
import QuotaBarCore

struct MusePortalConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = MusePortalSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Muse portal quota").font(.headline)
            Text("Sign in with the same Meta account as Muse CLI. Refresh teams, then explicitly select the team holding your Muse subscription. Only published usage is read; no model request is made.")
                .font(.caption)
            HStack {
                Picker("Subscription team", selection: $session.selectedTeamID) {
                    Text("Choose a team").tag("")
                    ForEach(session.teams) { team in Text(team.name).tag(team.id) }
                }
                // The read and its in-flight flag belong to the session, which
                // outlives this sheet: closing mid-read cannot strand a flag on a
                // view that is gone, and the session clears it on every exit.
                Button("Refresh teams") {
                    Task { await session.refreshTeams() }
                }.disabled(session.isReadingTeams)
            }
            Text(session.message).font(.caption)
            if let webView = session.webView { MusePortalWebView(webView: webView) }
            HStack {
                Text("This sign-in lasts until disconnection or app exit.").font(.caption)
                Spacer()
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
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    /// The web view outlives this representable: `MusePortalSession` owns it
    /// and hands it over on each presentation. Without this it is left attached
    /// to a container SwiftUI has torn down, with whatever page state it had.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.removeFromSuperview()
    }
}

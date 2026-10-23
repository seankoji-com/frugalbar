import SwiftUI
import WebKit
import QuotaBarCore

struct MusePortalConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = MusePortalSession.shared
    @State private var isReading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Muse portal quota").font(.headline)
            Text("Sign in with the same Meta account as Muse CLI. Refresh teams, then explicitly select the team holding your Muse subscription. Only published usage is read; no model request is made.")
                .font(.caption)
            HStack {
                Picker("Subscription team", selection: $session.selectedTeamID) {
                    Text("Choose a team").tag("")
                    ForEach(session.teams) { team in Text(team.name).tag(team.id) }
                }.disabled(!session.isEnabled || session.isDisconnecting)
                Button("Refresh teams") {
                    isReading = true
                    Task { await session.refreshTeams(); isReading = false }
                }.disabled(isReading || !session.isEnabled || session.isDisconnecting)
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
    }
}

private struct MusePortalWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

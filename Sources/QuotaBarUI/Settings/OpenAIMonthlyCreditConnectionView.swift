import SwiftUI
import WebKit
import QuotaBarCore

/// A normal OpenAI Platform sign-in inside the app's WebKit session. The page
/// chooses the active organization; FrugalBar only reads its credit grants.
struct OpenAIMonthlyCreditConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenAI monthly API credit").font(.headline)
            Text("Sign in to the OpenAI Platform, select the organization receiving the API credits, and open Billing → Credit grants. Leave the page open until its monthly grant appears. FrugalBar reads the grant amount, remaining amount and expiry, never your session token.")
                .font(.caption)
            OpenAICreditWebView()
            HStack {
                Text("Your sign-in stays in this app's WebKit session.").font(.caption)
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 800, height: 660)
    }
}

private struct OpenAICreditWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { OpenAIMonthlyCreditSession.shared.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

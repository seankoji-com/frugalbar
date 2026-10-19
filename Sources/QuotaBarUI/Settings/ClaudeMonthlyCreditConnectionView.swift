import SwiftUI
import WebKit
import QuotaBarCore

/// A normal Claude sign-in inside the app's WebKit session. The billing page
/// chooses the active organisation; FrugalBar only reads its monthly grant.
struct ClaudeMonthlyCreditConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude monthly API credit").font(.headline)
            Text("Sign in to Claude, then open Billing for the organisation whose monthly API credit you want to show. Leave the billing page open until its monthly credit appears. FrugalBar reads the allowance and next credit date, never a remaining balance.")
                .font(.caption)
            ClaudeCreditWebView()
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

private struct ClaudeCreditWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { ClaudeMonthlyCreditSession.shared.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

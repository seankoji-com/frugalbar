import SwiftUI
import WebKit
import QuotaBarCore

/// A normal OpenDesign sign-in inside the app's WebKit session. FrugalBar
/// reads only the current workspace's coding-plan usage from the signed-in page.
struct OpenDesignConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenDesign Go usage").font(.headline)
            Text("Sign in to OpenDesign and open the workspace whose coding plan you want to track. FrugalBar reads that workspace's published usage windows; it makes no model request.")
                .font(.caption)
            OpenDesignWebView()
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

private struct OpenDesignWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { OpenDesignWebSession.shared.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

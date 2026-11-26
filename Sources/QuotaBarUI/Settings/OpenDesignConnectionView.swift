import SwiftUI
import WebKit
import QuotaBarCore

/// A normal OpenDesign sign-in inside the app's WebKit session. FrugalBar
/// reads only the current workspace's coding-plan usage from the signed-in page.
struct OpenDesignConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var verification: Task<Void, Never>?
    @State private var failure: String?
    let connection: OpenDesignConnection
    let onLink: (Set<String>) -> Void

    private var session: OpenDesignWebSession { .session(for: connection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(connection.displayName).font(.headline)
            Text("Sign in to OpenDesign, choose the workspace in its workspace switcher, then link that workspace to this connection.")
                .font(.caption)
            OpenDesignWebView(session: session)
            if let failure { Text(failure).font(.callout) }
            HStack {
                Text("Your sign-in stays in this app's WebKit session.").font(.caption)
                Spacer()
                Button("Close") { dismiss() }
                Button("Link selected workspace") {
                    failure = nil
                    verification = Task {
                        defer { verification = nil }
                        do {
                            let invalidated = try await session.linkCurrentWorkspace()
                            onLink(invalidated)
                            dismiss()
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                }
                .disabled(verification != nil)
            }
        }
        .padding(16)
        .frame(width: 800, height: 660)
        .onDisappear { verification?.cancel() }
    }
}

private struct OpenDesignWebView: NSViewRepresentable {
    let session: OpenDesignWebSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

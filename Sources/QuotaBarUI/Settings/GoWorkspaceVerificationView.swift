import SwiftUI
import WebKit
import QuotaBarCore

struct GoWorkspaceVerificationView: View {
    let service: GoWorkspaceAccount
    let isLinked: Bool
    let onConnect: (GoWorkspaceAccount.Verification) -> String?
    @Binding var result: GoWorkspaceAccount.Verification?
    @Environment(\.dismiss) private var dismiss
    @State private var verification: Task<Void, Never>?
    @State private var connectionStatus: String?

    private var session: GoWorkspaceAccountWebSession { .session(for: service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(service.name) account").font(.headline)
            Text("Sign in once to connect the workspaces on this account.")
                .font(.caption)
            AccountWebView(session: session)
                .allowsHitTesting(verification == nil)
            if let result { verificationReport(result) }
            if let connectionStatus { Text(connectionStatus).font(.caption) }
            HStack {
                if verification != nil {
                    ProgressView().controlSize(.small)
                    Text("Reading workspaces…").font(.caption)
                }
                Spacer()
                Button("Close") { dismiss() }
                Button(isLinked ? "Refresh workspaces" : "Connect account") { verify() }
                    .disabled(verification != nil)
            }
        }
        .padding(16)
        .frame(width: 800, height: 700)
        .onAppear { session.open() }
        .onDisappear { verification?.cancel() }
    }

    private func verify() {
        result = nil
        connectionStatus = nil
        verification = Task {
            defer { verification = nil }
            let checked = await session.verify()
            guard !Task.isCancelled else { return }
            result = checked
            connectionStatus = onConnect(checked)
        }
    }

    @ViewBuilder
    private func verificationReport(_ result: GoWorkspaceAccount.Verification) -> some View {
        switch result {
        case .failed(.notConfigured), .failed(.credentialRejected):
            Text("Workspace access could not be verified. Finish signing in, then try again.")
                .font(.callout)
        case .failed(let reason):
            Text("Could not list workspaces. \(reason.headline)").font(.callout)
        case .workspaces(let readings):
            let measured = readings.count { if case .measured = $0.usage { true } else { false } }
            Text("\(measured) quota readings from \(readings.count) workspaces").font(.headline)
            if !readings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(readings) { reading in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reading.workspace.name).font(.callout.weight(.medium))
                                Text(summary(for: reading.usage)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 145)
            }
        }
    }

    private func summary(for usage: GoWorkspaceAccount.Usage) -> String {
        switch usage {
        case .noPlan: "No Go plan"
        case .failed(let reason): reason.headline
        case .measured(let windows):
            windows.map { window in
                let reading = window.fraction.map { "\($0.formatted(.percent.precision(.fractionLength(0)))) used" }
                return [window.label, reading, window.isBlocked ? "blocked" : nil].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: " · ")
        }
    }
}

private struct AccountWebView: NSViewRepresentable {
    let session: GoWorkspaceAccountWebSession

    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

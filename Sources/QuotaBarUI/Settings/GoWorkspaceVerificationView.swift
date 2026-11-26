import SwiftUI
import WebKit
import QuotaBarCore

enum GoWorkspaceConnectionOutcome {
    case cancelled
    case connected(String)
    case replacementRequired
}

struct GoWorkspaceVerificationView: View {
    let service: GoWorkspaceAccount
    let isLinked: Bool
    let onConnect: (GoWorkspaceAccount.Verification, _ replaceEarlierConnections: Bool) async -> GoWorkspaceConnectionOutcome
    @Binding var result: GoWorkspaceAccount.Verification?
    @Environment(\.dismiss) private var dismiss
    @State private var verification: Task<Void, Never>?
    @State private var connectionStatus: String?
    @State private var verifiedGeneration: UUID?
    @State private var confirmReplacement = false

    private var session: GoWorkspaceAccountWebSession { .session(for: service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(service.name) account").font(.headline)
            Text("Sign in once to connect the workspaces on this account.")
                .font(.caption)
            AccountWebView(session: session)
                .allowsHitTesting(verification == nil && verifiedGeneration == nil)
            if let result { verificationReport(result) }
            if let connectionStatus { Text(connectionStatus).font(.caption) }
            HStack {
                if verification != nil {
                    ProgressView().controlSize(.small)
                    Text("Reading workspaces…").font(.caption)
                }
                Spacer()
                Button("Reload sign-in page") {
                    verifiedGeneration = nil
                    result = nil
                    connectionStatus = nil
                    session.reloadSignIn()
                }
                    .disabled(verification != nil)
                Button("Close") { dismiss() }
                if verifiedGeneration != nil {
                    Button("Use these workspaces") { confirm(replacing: false) }.disabled(verification != nil)
                } else {
                    Button(isLinked ? "Refresh workspaces" : "Verify workspaces") { verify() }
                    .disabled(verification != nil)
                }
            }
        }
        .padding(16)
        .frame(width: 800, height: 700)
        .onAppear { session.beginManaging() }
        .alert("Replace earlier \(service.name) connections?", isPresented: $confirmReplacement) {
            Button("Keep existing connections", role: .cancel) { verifiedGeneration = nil }
            Button("Replace earlier connections", role: .destructive) { confirm(replacing: true) }
        } message: {
            Text("This sign-in could not verify every earlier workspace. Replacing the earlier connections will stop their quota updates when the new account takes over. Saved credentials and History stay on this Mac.")
        }
        .onDisappear {
            verification?.cancel()
            session.endManaging()
        }
    }

    private func verify() {
        result = nil
        connectionStatus = nil
        verifiedGeneration = nil
        verification = Task {
            defer { verification = nil }
            let checked = await session.verify()
            guard !Task.isCancelled else { return }
            result = checked
            if case .workspaces(let readings) = checked,
               readings.contains(where: { if case .measured = $0.usage { true } else { false } }),
               !readings.contains(where: { if case .failed = $0.usage { true } else { false } }) {
                verifiedGeneration = session.verificationGeneration
                connectionStatus = "Confirm these are the workspaces you want FrugalBar to monitor."
            }
        }
    }

    private func confirm(replacing: Bool) {
        guard let result, verifiedGeneration == session.verificationGeneration else {
            verifiedGeneration = nil
            connectionStatus = "The sign-in changed. Verify the workspaces again."
            return
        }
        verification = Task {
            defer { verification = nil }
            switch await onConnect(result, replacing) {
            case .cancelled: verifiedGeneration = nil
            case .connected(let status):
                verifiedGeneration = nil
                connectionStatus = status
            case .replacementRequired:
                guard !Task.isCancelled else { return }
                confirmReplacement = true
            }
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

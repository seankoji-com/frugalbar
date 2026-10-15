import AppKit
import SwiftUI
import QuotaBarCore

/// Preferences → Phone & Watch. Present only in a build with a sync client.
///
/// The disclosure is on screen whenever sync can be turned on, so it is read
/// before the sign-in it leads to. Sign-in never becomes a requirement for
/// anything else in FrugalBar.
struct SyncSettingsPane: View {
    @Bindable var controller: SyncController

    var body: some View {
        let presentation = controller.presentation
        Form {
            Section {
                Label(presentation.statusLine, systemImage: symbol(for: controller.status))
                    .font(.headline)
                    .accessibilityLabel("\(SyncSettingsText.toggleTitle): \(presentation.statusLine)")
                if let detail = presentation.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                if let line = presentation.lastPublishedLine {
                    Text(line).font(.callout)
                }
                if let line = presentation.lastErrorLine {
                    Label(line, systemImage: "exclamationmark.triangle").font(.callout)
                }
                if let message = presentation.exportMessage {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout)
                }
                actions(presentation.actions)
            } header: {
                Text(SyncSettingsText.toggleTitle)
            }

            if presentation.signInLink != nil || presentation.signInTimedOut || presentation.signInError != nil {
                signInSection(presentation)
            }

            if let notice = presentation.abandonedNotice {
                Section {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            if presentation.showsDisclosure {
                disclosureSection
            }

            Section {
                TextField(SyncSettingsText.labelTitle, text: $controller.macLabel)
            }
        }
        .formStyle(.grouped)
    }

    private func symbol(for status: SyncStatus) -> String {
        switch status.phase {
        case .off, .stopped: "iphone.slash"
        case .stopping: "hourglass"
        case .active:
            status.needsSignIn || status.ownership != nil ? "exclamationmark.triangle" : "checkmark.circle"
        }
    }

    @ViewBuilder
    private func actions(_ actions: [SyncSettingsPresentation.Action]) -> some View {
        HStack {
            ForEach(actions, id: \.self) { action in
                switch action {
                case .signIn:
                    Button(SyncSettingsText.signInButton) { controller.beginSignIn() }
                case .signInAgain:
                    Button(SyncSettingsText.signInAgain) { controller.beginSignIn() }
                case .signInToFinishCleanup:
                    Button(SyncSettingsText.signInToFinishCleanup) { controller.beginSignIn() }
                case .finishWithoutDeleting:
                    Button(SyncSettingsText.finishWithoutDeleting) { controller.finishWithoutDeleting() }
                case .takeOver:
                    Button(SyncSettingsText.takeOverButton) { controller.takeOver() }
                case .stop:
                    Button(SyncSettingsText.stopButton) { controller.stop() }
                }
            }
        }
    }

    private func signInSection(_ presentation: SyncSettingsPresentation) -> some View {
        Section {
            if let url = presentation.signInLink {
                Text(presentation.signInInstruction ?? SyncSettingsText.signInInstruction)
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button(SyncSettingsText.openLinkButton) { controller.openSignInLink() }
                    Button(SyncSettingsText.copyLinkButton) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button(SyncSettingsText.cancelButton) { controller.cancelSignIn() }
                }
            } else if presentation.signInTimedOut {
                Label(SyncSettingsText.signInTimedOut, systemImage: "clock.badge.exclamationmark")
                Text(SyncSettingsText.signInInstruction).font(.callout).foregroundStyle(.secondary)
                Button(SyncSettingsText.retryButton) { controller.beginSignIn() }
            } else if let error = presentation.signInError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button(SyncSettingsText.retryButton) { controller.beginSignIn() }
            }
        }
    }

    private var disclosureSection: some View {
        Section {
            Text(SyncSettingsText.summary).font(.callout)
            ForEach(SyncSettingsText.disclosureLines, id: \.self) { line in
                Label(line, systemImage: "info.circle").font(.callout)
            }
            Link(SyncSettingsText.privacyPolicyTitle, destination: SyncLinks.privacyPolicy)
        } header: {
            Text(SyncSettingsText.disclosureTitle)
        }
    }
}

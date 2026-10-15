import Foundation
import QuotaBarCore

/// Every sentence the sync pane shows, in one place.
public enum SyncSettingsText {
    public static let toggleTitle = "Sync to phone & watch"

    /// What syncing sends, before the disclosure.
    public static let summary = """
        FrugalBar can copy what this Mac shows (usage, plan names, resets, \
        balances, recent events and your notification choices) to the \
        FrugalBar app on your Android phone and watch, through a hidden folder \
        in your own Google Drive. It never copies a vendor key or login.
        """

    /// D§2.2.A / REQ-MAC-DISCLOSE (a): stated before sign-in.
    public static let disclosureTitle = "Before you sign in"
    public static let disclosureAccessControl =
        "Google account access control is the only protection: anyone who can use this Google account can read the synced data."
    public static let disclosureNoEncryption =
        "FrugalBar adds no encryption of its own. Google encrypts the data at rest."
    public static let disclosureNoWriterCheck =
        "Nothing checks which Mac wrote the data."
    public static let disclosureNoRollback =
        "Nothing prevents older data from replacing newer data (no rollback protection)."
    public static let privacyPolicyTitle = "Privacy policy"

    public static var disclosureLines: [String] {
        [disclosureAccessControl, disclosureNoEncryption, disclosureNoWriterCheck, disclosureNoRollback]
    }

    public static let signInButton = "Sign in with Google…"
    /// Spike 1 decision 9: a consent approved on another device never
    /// reaches this Mac's 127.0.0.1.
    public static let signInInstruction =
        "Open this link in a browser on this Mac. Sign-in can't finish on another device, because Google returns you to this Mac."
    public static let openLinkButton = "Open in Browser"
    public static let copyLinkButton = "Copy Link"
    public static let cancelButton = "Cancel"
    public static let signInTimedOut = "Sign-in timed out"
    public static let retryButton = "Try Again"

    public static let syncingTo = "Syncing to"
    public static let notPublishedYet = "Not published yet"
    public static let lastPublished = "Last published"
    public static let lastError = "Last error"
    public static let stopButton = "Stop Syncing"

    public static let signInAgain = "Sign in again"
    public static let signInAgainDetail = "Google stopped accepting FrugalBar's sign-in, so publishing has stopped."
    public static let takeOverButton = "Take Over"
    public static let otherMacTookOver = "Another Mac took over syncing"

    /// REQ-MAC-STOP (c): no end time, so it can never be out of date.
    public static let finishingCleanup = "Finishing sync cleanup"
    public static let finishingCleanupDetail =
        "FrugalBar is removing its sync data from Google Drive. Sync can be turned on again when this finishes."
    public static let cleanupNeedsSignIn =
        "FrugalBar lost access to Google Drive before it finished removing its sync data."
    public static let signInToFinishCleanup = "Sign in to finish cleanup"
    public static let finishWithoutDeleting = "Finish without deleting"

    public static let labelTitle = "This Mac's name on your phone"
    public static let wrongAccount = "That was a different Google account. Sign in as the account sync uses."
    public static let signInFailed = "Sign-in didn't finish. Try again."

    /// "Another Mac (label) is syncing — Take over?"
    public static func otherMacSyncing(label: String?) -> String {
        if let label, !label.isEmpty { return "Another Mac (\(label)) is syncing — Take over?" }
        return "Another Mac is syncing — Take over?"
    }

    /// The notice after "Finish without deleting", naming the account's real
    /// email address (spike decision 8).
    public static func abandonedNotice(email: String) -> String {
        "FrugalBar couldn't delete its sync data from \(email). To remove it, open Google Drive → Settings → "
            + "Manage apps → FrugalBar → Delete hidden app data. This deletes all FrugalBar sync data for that account."
    }
}

/// Where the privacy policy lives.
public enum SyncLinks {
    public static let privacyPolicy = URL(string: "https://github.com/seankoji-com/frugalbar/blob/main/docs/privacy.md")!
}

/// Where the interactive sign-in is.
public enum SyncSignInState: Equatable, Sendable {
    case idle
    /// Waiting for the browser; the link to show and open.
    case waiting(URL)
    case timedOut
    case failed(String)
}

/// The sync pane, as data: which status, notices and actions apply.
public struct SyncSettingsPresentation: Equatable {
    public enum Action: Equatable, Sendable {
        case signIn, stop, signInAgain, takeOver, signInToFinishCleanup, finishWithoutDeleting
    }

    /// The headline under the toggle.
    public var statusLine: String
    public var detail: String?
    public var lastPublishedLine: String?
    public var lastErrorLine: String?
    public var exportMessage: String?
    public var abandonedNotice: String?
    public var actions: [Action]
    /// Whether the setup screen with the disclosure is shown.
    public var showsDisclosure: Bool
    /// The sign-in screen's instruction, link or timeout.
    public var signInInstruction: String?
    public var signInLink: URL?
    public var signInTimedOut: Bool
    public var signInError: String?

    public static func make(status: SyncStatus, signIn: SyncSignInState, timeFormatter: (Date) -> String) -> Self {
        var actions: [Action] = []
        let statusLine: String
        var detail: String?
        switch status.phase {
        case .off, .stopped:
            statusLine = "Off"
            if signIn == .idle { actions.append(.signIn) }
        case .stopping:
            statusLine = SyncSettingsText.finishingCleanup
            if status.cleanupNeedsSignIn {
                detail = SyncSettingsText.cleanupNeedsSignIn
                actions += [.signInToFinishCleanup, .finishWithoutDeleting]
            } else {
                detail = SyncSettingsText.finishingCleanupDetail
            }
        case .active:
            if status.needsSignIn {
                statusLine = SyncSettingsText.signInAgain
                detail = SyncSettingsText.signInAgainDetail
                actions.append(.signInAgain)
            } else if case .otherMacSyncing(let label) = status.ownership {
                statusLine = SyncSettingsText.otherMacSyncing(label: label)
                actions.append(.takeOver)
            } else if case .tookOver = status.ownership {
                statusLine = SyncSettingsText.otherMacTookOver
                actions.append(.takeOver)
            } else {
                statusLine = status.account.map { "\(SyncSettingsText.syncingTo) \($0.email)" } ?? SyncSettingsText.toggleTitle
            }
            actions.append(.stop)
        }

        var presentation = SyncSettingsPresentation(
            statusLine: statusLine,
            detail: detail,
            lastPublishedLine: nil,
            lastErrorLine: status.lastError.map { "\(SyncSettingsText.lastError): \($0)" },
            exportMessage: status.exportMessage,
            abandonedNotice: status.abandoned.map { SyncSettingsText.abandonedNotice(email: $0.account.email) },
            actions: actions,
            showsDisclosure: status.canStart,
            signInInstruction: nil,
            signInLink: nil,
            signInTimedOut: false,
            signInError: nil)
        if status.phase == .active {
            presentation.lastPublishedLine = status.lastSuccessfulPublishAt
                .map { "\(SyncSettingsText.lastPublished) \(timeFormatter($0))" } ?? SyncSettingsText.notPublishedYet
        }
        switch signIn {
        case .idle:
            break
        case .waiting(let url):
            presentation.signInInstruction = SyncSettingsText.signInInstruction
            presentation.signInLink = url
        case .timedOut:
            presentation.signInTimedOut = true
        case .failed(let message):
            presentation.signInError = message
        }
        return presentation
    }
}

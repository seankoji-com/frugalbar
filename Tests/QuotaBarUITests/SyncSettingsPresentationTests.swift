import AppKit
import Foundation
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

private let account = SyncAccount(permissionId: "perm-owner-01", email: "owner@example.test")
private let publishedAt = Date(timeIntervalSince1970: 1_791_000_000)

private func presentation(
    _ configure: (inout SyncStatus) -> Void = { _ in },
    signIn: SyncSignInState = .idle
) -> SyncSettingsPresentation {
    var status = SyncStatus()
    configure(&status)
    return SyncSettingsPresentation.make(status: status, signIn: signIn) { _ in "15 Oct 2026 at 14:05" }
}

@Suite("Sync settings (REQ-MAC-OPTIN, REQ-MAC-OAUTH UX, REQ-MAC-STOP c–d, REQ-MAC-DISCLOSE)")
@MainActor
struct SyncSettingsPresentationTests {

    @Test("without a sync client the Phone & Watch pane is not listed; with one it is")
    func paneHiddenWithoutClient() {
        #expect(!SettingsView.Pane.visible(syncAvailable: false).contains(.sync))
        #expect(SettingsView.Pane.visible(syncAvailable: false)
                == SettingsView.Pane.allCases.filter { $0 != .sync })
        #expect(SettingsView.Pane.visible(syncAvailable: true).contains(.sync))
    }

    @Test("off by default: the only action is the optional sign-in, and the disclosure is on screen first")
    func offByDefault() {
        let off = presentation()
        #expect(SyncStatus().phase == .off)
        #expect(off.statusLine == "Off")
        #expect(off.actions == [.signIn])
        #expect(off.showsDisclosure)
    }

    @Test("the setup screen states every disclosure before sign-in, with a privacy policy link")
    func disclosureContent() {
        let lines = SyncSettingsText.disclosureLines.joined(separator: " ")
        #expect(lines.contains("Google account access control is the only protection"))
        #expect(lines.contains("no encryption of its own"))
        #expect(lines.contains("Nothing checks which Mac wrote the data"))
        #expect(lines.contains("no rollback protection"))
        #expect(SyncLinks.privacyPolicy.scheme == "https")
        #expect(SyncSettingsText.privacyPolicyTitle == "Privacy policy")
        #expect(!presentation { $0.phase = .active; $0.account = account }.showsDisclosure)
    }

    @Test("the sign-in screen says to open the link in a browser on this Mac")
    func signInSaysUseThisMac() throws {
        let url = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?state=s"))
        let waiting = presentation(signIn: .waiting(url))
        #expect(waiting.signInLink == url)
        #expect(waiting.signInInstruction?.contains("in a browser on this Mac") == true)
        #expect(waiting.actions.isEmpty)
    }

    @Test("a timeout shows Sign-in timed out with a retry button")
    func timeoutShowsRetry() {
        let timedOut = presentation(signIn: .timedOut)
        #expect(timedOut.signInTimedOut)
        #expect(SyncSettingsText.signInTimedOut == "Sign-in timed out")
        #expect(SyncSettingsText.retryButton == "Try Again")
    }

    @Test("a terminal refresh failure shows Sign in again")
    func terminalFailureShowsSignInAgain() {
        let needs = presentation {
            $0.phase = .active
            $0.account = account
            $0.needsSignIn = true
        }
        #expect(needs.statusLine == "Sign in again")
        #expect(needs.actions.contains(.signInAgain))
    }

    @Test("Settings shows the last successful publish and the last error")
    func showsLastPublishAndError() {
        let active = presentation {
            $0.phase = .active
            $0.account = account
            $0.lastSuccessfulPublishAt = publishedAt
            $0.lastError = "Google Drive answered 503; retrying"
        }
        #expect(active.statusLine == "Syncing to owner@example.test")
        #expect(active.lastPublishedLine == "Last published 15 Oct 2026 at 14:05")
        #expect(active.lastErrorLine == "Last error: Google Drive answered 503; retrying")
        #expect(presentation { $0.phase = .active }.lastPublishedLine == "Not published yet")
    }

    @Test("another Mac's session offers Take over; a takeover says so")
    func ownershipLines() {
        let other = presentation {
            $0.phase = .active
            $0.ownership = .otherMacSyncing(label: "Office Mac")
        }
        #expect(other.statusLine == "Another Mac (Office Mac) is syncing — Take over?")
        #expect(other.actions.contains(.takeOver))
        let took = presentation {
            $0.phase = .active
            $0.ownership = .tookOver(label: nil)
        }
        #expect(took.statusLine == "Another Mac took over syncing")
    }

    @Test("while stopping, Start is unavailable and the app shows Finishing sync cleanup with no end time")
    func stoppingShowsCleanupWithoutEndTime() {
        let stopping = presentation { $0.phase = .stopping; $0.account = account }
        #expect(stopping.statusLine == "Finishing sync cleanup")
        #expect(!stopping.actions.contains(.signIn))
        #expect(!stopping.showsDisclosure)
        let shown = [stopping.statusLine, stopping.detail ?? ""].joined(separator: " ")
        #expect(shown.rangeOfCharacter(from: .decimalDigits) == nil)
        #expect(!shown.localizedCaseInsensitiveContains("minute"))
        #expect(stopping.lastPublishedLine == nil)
    }

    @Test("an unreadable saved state offers only Try Again: no sign-in, no disclosure, and it says why")
    func unreadableStateOffersOnlyRetry() {
        for phase in [SyncPhase.off, .stopped] {
            let unreadable = presentation { $0.phase = phase; $0.stateUnreadable = true }
            #expect(unreadable.statusLine == SyncSettingsText.stateUnreadable)
            #expect(unreadable.detail == SyncSettingsText.stateUnreadableDetail)
            #expect(unreadable.actions == [.retryStateRead])
            #expect(!unreadable.showsDisclosure)
        }
        var status = SyncStatus()
        status.stateUnreadable = true
        #expect(!status.canStart)
    }

    @Test("a terminal auth failure during cleanup offers Sign in to finish cleanup and Finish without deleting")
    func cleanupAuthLostOffersTwoChoices() {
        let paused = presentation {
            $0.phase = .stopping
            $0.account = account
            $0.cleanupNeedsSignIn = true
        }
        #expect(paused.actions == [.signInToFinishCleanup, .finishWithoutDeleting])
        #expect(SyncSettingsText.signInToFinishCleanup == "Sign in to finish cleanup")
        #expect(SyncSettingsText.finishWithoutDeleting == "Finish without deleting")
    }

    @Test("the abandonment notice names the account's real email, never a placeholder")
    func abandonedNoticeNamesEmail() throws {
        let stopped = presentation {
            $0.phase = .stopped
            $0.abandoned = SyncAbandonedData(account: account)
        }
        let notice = try #require(stopped.abandonedNotice)
        #expect(notice.contains("owner@example.test"))
        #expect(!notice.contains("<email>"))
        #expect(!notice.localizedCaseInsensitiveContains("placeholder"))
        #expect(notice.contains("Delete hidden app data"))
        #expect(presentation { $0.phase = .stopped }.abandonedNotice == nil)
    }

    @Test("every symbol the sync pane draws exists")
    func symbolsResolve() {
        for name in [SettingsView.Pane.sync.symbol, "iphone.slash", "hourglass", "checkmark.circle",
                     "exclamationmark.triangle", "clock.badge.exclamationmark", "exclamationmark.circle", "info.circle"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test("NSSystemClockDidChangeNotification reaches the publisher through the controller")
    func clockNotificationReachesPublisher() async throws {
        let center = NotificationCenter()
        let publisher = SyncPublisher(
            configuration: SyncClientConfiguration(clientID: "fake-client-id.apps.example.test",
                                                   clientSecret: "fake-client-secret-for-tests"),
            transport: RefusingTransport(), secrets: EmptySecrets(), stateStore: InMemorySyncStateStore(),
            label: { "Test Mac" })
        let controller = SyncController(
            publisher: publisher,
            flow: SyncSignInFlow(configuration: SyncClientConfiguration(
                clientID: "fake-client-id.apps.example.test", clientSecret: "fake-client-secret-for-tests"),
                transport: RefusingTransport(), secrets: EmptySecrets()),
            eventsLoader: { [] }, notificationCenter: center, openURL: { _ in }, macLabel: "Test Mac")
        center.post(name: .NSSystemClockDidChange, object: nil)
        var applied = false
        for _ in 0..<200 where !applied {
            applied = await publisher.clockDiscontinuities == 1
            if !applied { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(applied)
        withExtendedLifetime(controller) {}
    }
}

/// Fails every request: these tests must never reach Google.
private struct RefusingTransport: SyncTransport {
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct EmptySecrets: SyncSecretStore {
    func read(_ account: String) throws -> String? { nil }
    func write(_ value: String, account: String) throws {}
    func delete(_ account: String) throws {}
}

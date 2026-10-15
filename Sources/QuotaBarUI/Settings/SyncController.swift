import AppKit
import Foundation
import Observation
import QuotaBarCore
import SystemConfiguration

/// Drives sync for the running app: owns the publisher, runs it off the poll
/// path, and holds what the sync pane shows.
///
/// Exists only when this build has a sync client (`makeIfAvailable`); without
/// one there is no controller, no pane and no Google traffic.
@MainActor
@Observable
public final class SyncController {

    public private(set) var status = SyncStatus()
    public private(set) var signIn: SyncSignInState = .idle

    /// The name the phone shows for this Mac.
    public var macLabel: String {
        didSet { CredentialStore.preferences.set(macLabel, forKey: Self.labelDefaultsKey) }
    }

    static let labelDefaultsKey = "QuotaBarSyncMacLabel"

    private let publisher: SyncPublisher
    private let flow: SyncSignInFlow
    private let makeListener: @Sendable () throws -> any SyncCallbackListener
    private let eventsLoader: @Sendable () async -> [AIEvent]
    private let openURL: @MainActor (URL) -> Void
    private var loopTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var clockObserver: SyncClockChangeObserver?
    private var wakeRequested = false
    /// The last poll's snapshots, so a new session publishes without waiting
    /// for the next poll.
    private var lastSnapshots: [QuotaSnapshot] = []

    init(
        publisher: SyncPublisher,
        flow: SyncSignInFlow,
        makeListener: @escaping @Sendable () throws -> any SyncCallbackListener = { try SyncLoopbackListener() },
        eventsLoader: @escaping @Sendable () async -> [AIEvent],
        notificationCenter: NotificationCenter = .default,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        macLabel: String
    ) {
        self.publisher = publisher
        self.flow = flow
        self.makeListener = makeListener
        self.eventsLoader = eventsLoader
        self.openURL = openURL
        self.macLabel = macLabel
        // A clock correction makes every reading retained so far untrusted
        // until it is measured again (REQ-MAC-CLOCK b).
        clockObserver = SyncClockChangeObserver(publisher: publisher, center: notificationCenter)
    }

    /// The controller for this build, or nil when it has no sync client.
    public static func makeIfAvailable(eventsLoader: @escaping @Sendable () async -> [AIEvent]) -> SyncController? {
        guard let configuration = SyncClientConfiguration.current else { return nil }
        let stored = CredentialStore.preferences.string(forKey: labelDefaultsKey)
        let label = (stored?.isEmpty == false ? stored : nil) ?? Self.computerName()
        let labelBox = LabelBox(label)
        let controller = SyncController(
            publisher: SyncPublisher(configuration: configuration, label: { labelBox.value }),
            flow: SyncSignInFlow(configuration: configuration),
            eventsLoader: eventsLoader,
            macLabel: label)
        controller.labelBox = labelBox
        return controller
    }

    /// Shares the label with the publisher, which reads it off the main actor.
    private var labelBox: LabelBox?

    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    // MARK: Driving

    /// Resumes an unfinished Stop, then runs the publisher until the app quits.
    public func start() {
        guard loopTask == nil else { return }
        let publisher = self.publisher
        loopTask = Task { [weak self] in
            await publisher.resume()
            while !Task.isCancelled {
                await publisher.tick()
                let status = await publisher.status()
                let next = await publisher.nextWakeup()
                guard let self else { return }
                self.status = status
                await self.wait(until: next)
            }
        }
    }

    /// Sleeps until `deadline`, a wake request, or a minute at most, so a
    /// wall-clock change is noticed.
    private func wait(until deadline: Date?) async {
        let limit = Date().addingTimeInterval(60)
        let target = min(deadline ?? limit, limit)
        while !Task.isCancelled, !wakeRequested, Date() < target {
            try? await Task.sleep(for: .seconds(1))
        }
        wakeRequested = false
    }

    private func wake() { wakeRequested = true }

    /// After each poll. Returns at once: events are read and the input handed
    /// over off the poll path, and nothing waits on Google.
    public func submit(snapshots: [QuotaSnapshot]) {
        lastSnapshots = snapshots
        labelBox?.value = macLabel
        let publisher = self.publisher
        let eventsLoader = self.eventsLoader
        let prefs = SyncExportSource.currentNotificationPrefs()
        Task { [weak self] in
            guard await publisher.status().phase == .active else { return }
            let events = await eventsLoader()
            await publisher.submit(SyncExportSource(snapshots: snapshots, events: events, notificationPrefs: prefs))
            self?.wake()
        }
    }

    // MARK: Actions

    public var presentation: SyncSettingsPresentation {
        SyncSettingsPresentation.make(status: status, signIn: signIn) {
            $0.formatted(date: .abbreviated, time: .shortened)
        }
    }

    /// "Sign in with Google…", "Sign in again" and "Sign in to finish
    /// cleanup" share one flow; the last two must come back as the same
    /// account.
    public func beginSignIn() {
        signInTask?.cancel()
        let publisher = self.publisher
        let flow = self.flow
        let makeListener = self.makeListener
        signInTask = Task { [weak self] in
            // The publisher's own status, not the pane's last copy: a sign-in
            // stores its refresh token before activation can refuse it.
            let current = await publisher.status()
            guard !current.stateUnreadable else {
                self?.signIn = .failed(SyncSettingsText.signInFailed)
                await self?.refresh()
                return
            }
            let expected: SyncAccount? = current.canStart ? nil : current.account
            do {
                let listener = try makeListener()
                let result = try await flow.run(
                    listener: listener,
                    loginHint: expected?.email,
                    expectedPermissionId: expected?.permissionId
                ) { url in
                    await MainActor.run {
                        self?.signIn = .waiting(url)
                        self?.openURL(url)
                    }
                }
                if current.canStart {
                    try await publisher.activate(account: result.account)
                } else {
                    try await publisher.reauthorized(account: result.account)
                }
                await publisher.primeAccessToken(result.accessToken, expiresIn: result.expiresIn)
                self?.signIn = .idle
                if let self { self.submit(snapshots: self.lastSnapshots) }
            } catch SyncSignInError.timedOut {
                self?.signIn = .timedOut
            } catch SyncSignInError.cancelled {
                self?.signIn = .idle
            } catch SyncSignInError.wrongAccount {
                self?.signIn = .failed(SyncSettingsText.wrongAccount)
            } catch SyncActivationError.stateNotSaved {
                self?.signIn = .failed(SyncSettingsText.stateNotSaved)
            } catch {
                self?.signIn = .failed(SyncSettingsText.signInFailed)
            }
            await self?.refresh()
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = .idle
    }

    public func openSignInLink() {
        if case .waiting(let url) = signIn { openURL(url) }
    }

    public func stop() {
        let publisher = self.publisher
        Task { [weak self] in
            await publisher.stop()
            await self?.refresh()
        }
    }

    public func takeOver() {
        let publisher = self.publisher
        Task { [weak self] in
            await publisher.takeOver()
            await self?.refresh()
        }
    }

    /// "Try Again" after the saved sync state could not be read.
    public func retryLoadingState() {
        let publisher = self.publisher
        Task { [weak self] in
            await publisher.retryLoadingState()
            await self?.refresh()
        }
    }

    public func finishWithoutDeleting() {
        let publisher = self.publisher
        Task { [weak self] in
            await publisher.finishWithoutDeleting()
            await self?.refresh()
        }
    }

    func refresh() async {
        status = await publisher.status()
        wake()
    }
}

/// The Mac label, readable from the publisher's actor.
private final class LabelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

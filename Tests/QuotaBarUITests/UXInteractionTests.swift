import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import QuotaBarCore
@testable import QuotaBarUI

// Opt-in, one test per process: these host production views in a real
// window and drive them through the macOS accessibility client API — the path
// VoiceOver and Voice Control take — and real key events, which needs a window
// server and an accessibility-trusted runner. Fixtures never enter a live
// store; preferences go to the test-host suite only and are restored after.
//
// One test per process because, once the accessibility client is attached,
// AppKit stops the main run loop between tests, and the async test main then
// exits with status 0 before the next test runs — a short run that looks like
// a pass. `FRUGALBAR_INTERACTION` names the one test to run:
//
//   for t in settings popover chart; do
//     FRUGALBAR_RENDER_DIR=$PWD/.build/ui-renders FRUGALBAR_INTERACTION=$t \
//       swift test -c debug --filter UXInteractionTests
//   done
//
// and each run must end with its "Test run with" summary line.
private let selectedInteraction = ProcessInfo.processInfo.environment["FRUGALBAR_INTERACTION"]

@Suite("UX interactions", .serialized,
       .enabled(if: selectedInteraction != nil
                && ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"] != nil))
@MainActor
struct UXInteractionTests {
    private struct FixtureProvider: QuotaProvider {
        let snapshot: QuotaSnapshot
        var vendorId: VendorIdentifier { snapshot.vendorId }
        var displayName: String { snapshot.displayName }
        var category: MetricCategory { snapshot.category }
        var instanceID: String { snapshot.id }
        func fetchSnapshot() async throws -> QuotaSnapshot { snapshot }
    }

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRUGALBAR_RENDER_DIR"]!)
    }

    /// The accessibility server only answers once the app has launched, and
    /// SwiftUI builds its tree only for a connected client.
    private static let launched: Void = {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }()

    init() {
        Self.launched
    }

    // MARK: - Settings: the real workspace move buttons

    @Test("pressing the real move buttons reorders the workspaces, and a separate process reads the new order",
          .enabled(if: selectedInteraction == "settings"))
    func settingsMoveButtonsPersist() async throws {
        try #require(AXIsProcessTrusted(), "the test runner needs accessibility permission")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = CredentialStore.preferences
        #expect(defaults !== UserDefaults.standard)
        let key = OpenCodeGoWorkspaceStore.defaultsKey
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let alpha = OpenCodeGoWorkspace(id: "ix-alpha", name: "Go Alpha")
        let beta = OpenCodeGoWorkspace(id: "ix-beta", name: "Go Beta")
        let gamma = OpenCodeGoWorkspace(id: "ix-gamma", name: "Go Gamma")
        OpenCodeGoWorkspaceStore.set([alpha, beta, gamma])

        let (window, host) = try present(
            SettingsView(store: nil, initialPane: .workspaces, readsCredentials: false)
                .frame(width: 760, height: 620))

        #expect(axPress("Move Go Gamma up"))
        #expect(axPress("Move Go Alpha down"))

        let expected = [gamma, alpha, beta].map(\.instanceID)
        #expect(OpenCodeGoWorkspaceStore.resolved().map(\.instanceID) == expected)
        // The buttons' own enablement follows the new order.
        #expect(axEnabled("Move Go Gamma up") == false)
        #expect(axEnabled("Move Go Beta down") == false)
        #expect(axEnabled("Move Go Alpha up") == true)
        try save(host, name: "interaction-settings-after-moves")

        // A separate process reads the stored preference, as the next launch
        // would, and the production decoder resolves it to the same order with
        // every identity intact.
        defaults.synchronize()
        let exported = try run("/usr/bin/defaults", ["export", CredentialStore.preferencesSuiteName(isTestHost: true), "-"])
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: exported, format: nil) as? [String: Any])
        let suiteName = "frugalbar.tests.relaunch.\(UUID().uuidString)"
        let relaunch = try #require(UserDefaults(suiteName: suiteName))
        defer { relaunch.removePersistentDomain(forName: suiteName) }
        relaunch.set(try #require(plist[key] as? Data), forKey: key)
        let reread = OpenCodeGoWorkspaceStore.resolved(in: relaunch)
        #expect(reread.map(\.instanceID) == expected)
        #expect(reread.map(\.credentialLabel) == [gamma, alpha, beta].map(\.credentialLabel))
        print("UX-INTERACTION settings move buttons -> \(reread.map(\.name)); read back by /usr/bin/defaults")
        dismiss(window)
    }

    // MARK: - Popover: #92's row buttons and Escape

    @Test("a popover row is a button that opens its detail, and its close button closes it",
          .enabled(if: selectedInteraction == "popover"))
    func popoverRowAndEscape() async throws {
        try #require(AXIsProcessTrusted(), "the test runner needs accessibility permission")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let reset = now.addingTimeInterval(3 * 86_400)
        let claude = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: 0.4, displayDetails: nil), status: .measured(.none),
            resetsAt: reset, lastUpdated: now, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.4, label: "WK", resetsAt: reset, windowLength: 7 * 86_400))
        let store = QuotaStore(manager: QuotaManager(
            providerFactory: { [FixtureProvider(snapshot: claude)] },
            displayPreferences: { ProviderDisplayPreferences(ordering: .automatic) }))
        await store.load()

        let (window, host) = try present(
            PopoverRootView(store: store, onOpenSettings: {}, availableHeightProvider: { 900 }))
        let close = "Close Claude details"
        #expect(axFind { $0 == close } == false)

        // Tab reaches a button only under Full Keyboard Access, a system
        // setting this run does not change; a stray Space could also land on
        // the footer's Quit button and end the run. So the row is pressed as
        // VoiceOver presses it, and the setting is recorded.
        print("UX-INTERACTION full keyboard access: \(NSApp.isFullKeyboardAccessEnabled)")
        #expect(axPress { $0.hasPrefix("Claude") }, "the row is a pressable button")
        #expect(axFind { $0 == close }, "the detail opened")
        try save(host, name: "interaction-popover-detail-open")

        // Escape is the inspector's exit command (#92). Recorded, not
        // asserted: in a hosted window it does not reach `onExitCommand`,
        // here or on main at b3a8959 with this same test, so the harness
        // cannot speak for it either way. The close button can be checked.
        try sendKeys([(53, "\u{1B}")], to: window)
        print("UX-INTERACTION popover Escape closed detail: \(!axFind { $0 == close })")
        if axFind({ $0 == close }) {
            #expect(axPress(close), "the close button is pressable")
        }
        #expect(axFind { $0 == close } == false, "the detail closed")
        try save(host, name: "interaction-popover-detail-closed")
        dismiss(window)
    }

    // MARK: - Chart: VoiceOver's adjust action

    @Test("the chart's adjust action selects a reading, and its value reads it with the second it was taken",
          .enabled(if: selectedInteraction == "chart"))
    func chartAdjustAction() async throws {
        try #require(AXIsProcessTrusted(), "the test runner needs accessibility permission")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let records = (0..<48).map { i in
            QuotaHistoryStore.ReadingRecord(
                vendor: "claude", barLabel: "WK", measuredAt: now.addingTimeInterval(-Double(47 - i) * 1_800),
                fraction: 0.2 + Double(i) * 0.01, isBlocked: false, confidence: .measured, urgency: .none,
                resetsAt: nil, windowLength: 7 * 86_400, elapsedOnly: false)
        }
        let segments = HistoryPresentation.segments(from: records)
        let (window, host) = try present(
            QuotaTimelineChart(segments: segments, timeRange: .last24Hours)
                .padding(14).frame(width: 760, height: 300).background(Theme.card))

        let label = "Quota timeline, \(HistoryPresentation.TimeRange.last24Hours.title)"
        let before = axValue(label)
        #expect(axAction(label, kAXIncrementAction))
        let after = axValue(label)
        print("UX-INTERACTION chart adjust: before=\(before ?? "nil") after=\(after ?? "nil")")
        // The newest poll: 67% used.
        #expect(after?.contains("67 percent used") == true)
        #expect(after != before)
        try save(host, name: "interaction-chart-adjust")

        // A mouse-moved event delivered to the window only; the real cursor
        // never moves. Recorded, not asserted: whether AppKit routes a
        // synthetic event into SwiftUI's hover tracking is not ours to vouch for.
        // Escape clears the selection, so the value is the summary again.
        try sendKeys([(53, "\u{1B}")], to: window)
        #expect(axValue(label) == before)
        window.acceptsMouseMovedEvents = true
        for x in [host.bounds.midX - 20, host.bounds.midX] {
            if let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: x, y: host.bounds.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(event)
            }
            spinMainRunLoop(seconds: 0.1)
        }
        let hovered = axValue(label)
        print("UX-INTERACTION chart synthetic hover value: \(hovered ?? "nil")")
        dismiss(window)
    }

    // MARK: - Accessibility client

    /// Runs `work` against this process's accessibility tree. In-process,
    /// the client call is served on the calling thread, so it runs on the
    /// main thread, where SwiftUI performs the button's action.
    private func withAXClient<T>(_ work: (AXUIElement) -> T) -> T {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
        let result = work(app)
        spinMainRunLoop(seconds: 0.3)
        return result
    }

    private func axFind(_ match: (String) -> Bool) -> Bool {
        withAXClient { app in Self.element(in: app, where: match) != nil }
    }

    private func axPress(_ label: String) -> Bool {
        axAction(label, kAXPressAction)
    }

    private func axPress(_ match: (String) -> Bool) -> Bool {
        withAXClient { app in
            guard let element = Self.element(in: app, where: match) else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }

    private func axAction(_ label: String, _ action: String) -> Bool {
        withAXClient { app in
            guard let element = Self.element(in: app, where: { $0 == label }) else { return false }
            return AXUIElementPerformAction(element, action as CFString) == .success
        }
    }

    private func axEnabled(_ label: String) -> Bool? {
        withAXClient { app in
            guard let element = Self.element(in: app, where: { $0 == label }) else { return nil }
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
            return value as? Bool
        }
    }

    private func axValue(_ label: String) -> String? {
        withAXClient { app in
            guard let element = Self.element(in: app, where: { $0 == label }) else { return nil }
            // An adjustable element states its reading as the value
            // description; a plain one as its value.
            for attribute in ["AXValueDescription", kAXValueAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty {
                    return text
                }
            }
            return nil
        }
    }

    /// Breadth-first by accessibility label (AXDescription) or title.
    private static func element(in root: AXUIElement, where match: (String) -> Bool) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 5_000 {
            let element = queue.removeFirst()
            visited += 1
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let text = value as? String, match(text) {
                    return element
                }
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            queue += (children as? [AXUIElement]) ?? []
        }
        return nil
    }

    // MARK: - Helpers

    /// Nested run-loop turns, not `Task.sleep`: a stop of the main run loop
    /// that reached the async test main's own loop would end the process.
    private func spinMainRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Hides the window and lets any stop it causes land on a nested loop.
    private func dismiss(_ window: NSWindow) {
        window.orderOut(nil)
        spinMainRunLoop(seconds: 0.5)
    }

    /// Every test hands its window to `dismiss`, never `close()`.
    private func present<V: View>(_ view: V) throws -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Away from the real pointer: a window that opens under it receives
        // genuine hover, and a chart would start with a reading selected.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let x = pointer.x < visible.midX ? visible.maxX - window.frame.width : visible.minX
            let y = pointer.y < visible.midY ? visible.maxY - window.frame.height : visible.minY
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        #expect(!window.frame.contains(NSEvent.mouseLocation), "the window opened under the pointer")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        spinMainRunLoop(seconds: 0.4)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func sendKeys(_ keys: [(UInt16, String)], to window: NSWindow) throws {
        for (code, characters) in keys {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
                window.sendEvent(event)
            }
            spinMainRunLoop(seconds: 0.25)
        }
    }

    private func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }

    private func save(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

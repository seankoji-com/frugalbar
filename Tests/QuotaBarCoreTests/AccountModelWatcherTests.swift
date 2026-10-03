import Testing
import Foundation
@testable import QuotaBarCore

@Suite("AccountModelWatcher")
struct AccountModelWatcherTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, name: String? = nil) -> AccountModelRecord {
        AccountModelRecord(vendorId: .openai, modelId: id, name: name,
                           firstSeen: now.addingTimeInterval(-86_400), lastSeen: now.addingTimeInterval(-3600))
    }

    /// Without the seed rule, turning the feature on would announce every
    /// model the account already had.
    @Test("the first list for a vendor seeds silently")
    func seedIsSilent() {
        let diff = AccountModelWatcher.diff(
            vendor: .openai, known: [:],
            current: [AccountModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"), AccountModel(id: "gpt-6.1-luna")],
            now: now)
        #expect(diff.events.isEmpty)
        #expect(diff.records.map(\.modelId) == ["gpt-6.1-sol", "gpt-6.1-luna"])
        #expect(diff.records.allSatisfy { $0.firstSeen == now && $0.lastSeen == now })
    }

    @Test("a model new to the list is announced once, by name, keyed on its id")
    func newModelAnnounced() throws {
        let diff = AccountModelWatcher.diff(
            vendor: .openai,
            known: ["gpt-6.1-sol": record("gpt-6.1-sol", name: "GPT-6.1 Sol")],
            current: [AccountModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
                      AccountModel(id: "gpt-6.2", name: "GPT-6.2"),
                      AccountModel(id: "gpt-6.2", name: "GPT-6.2")],
            now: now)
        let event = try #require(diff.events.first)
        #expect(diff.events.count == 1)
        #expect(event.id == "new_model|openai|account|gpt-6.2")
        #expect(event.title == "GPT-6.2 now available in Codex")
        #expect(event.detail == "Model id gpt-6.2")
        #expect(event.source == .accountModels)
        #expect(event.isSurfaced)
        // firstSeen carried forward for the known model.
        #expect(diff.records.first { $0.modelId == "gpt-6.1-sol" }?.firstSeen == now.addingTimeInterval(-86_400))
    }

    @Test("a model without a display name is announced by its id")
    func unnamedModel() {
        let diff = AccountModelWatcher.diff(
            vendor: .copilot, known: ["a": record("a")],
            current: [AccountModel(id: "a"), AccountModel(id: "claude-opus-5.5", name: "  ")], now: now)
        #expect(diff.events.map(\.title) == ["claude-opus-5.5 now available in GitHub Copilot"])
        #expect(diff.events.first?.detail == nil)
    }

    @Test("a model that left the list and came back is not new")
    func returningModelSilent() {
        let diff = AccountModelWatcher.diff(
            vendor: .openai,
            known: ["a": record("a"), "b": record("b")],
            current: [AccountModel(id: "b")], now: now)
        #expect(diff.events.isEmpty)
        let back = AccountModelWatcher.diff(
            vendor: .openai,
            known: ["a": record("a"), "b": record("b")],
            current: [AccountModel(id: "a"), AccountModel(id: "b")], now: now)
        #expect(back.events.isEmpty)
    }
}

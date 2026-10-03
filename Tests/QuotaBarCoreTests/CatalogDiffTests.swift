import Testing
import Foundation
@testable import QuotaBarCore

@Suite("CatalogDiff")
struct CatalogDiffTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_700_000_000)

    private func price(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    private func entry(_ id: String, name: String? = nil, created: Date? = nil,
                       prompt: String? = "0.000003", completion: String? = "0.000015") -> CatalogEntry {
        CatalogEntry(id: id, name: name ?? id, created: created,
                     promptPrice: prompt.map(price), completionPrice: completion.map(price))
    }

    private func record(_ id: String, vendor: VendorIdentifier = .claude,
                        prompt: String? = "0.000003", completion: String? = "0.000015") -> CatalogModelRecord {
        CatalogModelRecord(modelId: id, vendorId: vendor, name: id, createdAt: nil,
                           promptPrice: prompt.map(price), completionPrice: completion.map(price),
                           firstSeen: earlier, lastSeen: earlier)
    }

    /// Regression guard: without the seed rule, the first launch announces
    /// every tracked model already in the catalog.
    @Test("the first poll seeds every tracked model and announces none")
    func seedRunSilent() {
        let (events, records) = CatalogDiff.compute(
            previous: [:],
            current: [entry("anthropic/claude-opus-5-5"), entry("openai/gpt-6"), entry("meta-llama/llama-5")],
            now: now)
        #expect(events.isEmpty)
        #expect(records.map(\.modelId) == ["anthropic/claude-opus-5-5", "openai/gpt-6"])
        #expect(records.allSatisfy { $0.firstSeen == now && $0.lastSeen == now })
    }

    @Test("a model not seen before is announced with its catalog date, prices and link")
    func newModel() throws {
        let created = Date(timeIntervalSince1970: 1_799_990_000)
        let (events, _) = CatalogDiff.compute(
            previous: ["anthropic/claude-opus-5-5": record("anthropic/claude-opus-5-5")],
            current: [entry("anthropic/claude-opus-5-5"),
                      entry("anthropic/claude-sonnet-5-5", name: "Anthropic: Claude Sonnet 5.5",
                            created: created, prompt: "0.000002", completion: "0.00001")],
            now: now)
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.kind == .newModel)
        #expect(event.vendorId == .claude)
        #expect(event.title == "Anthropic: Claude Sonnet 5.5 listed")
        #expect(event.detail == "Prompt $2.00 / completion $10.00 per million tokens")
        #expect(event.occurredAt == created)
        #expect(event.observedAt == now)
        #expect(event.source == .openRouterCatalog)
        #expect(event.url == URL(string: "https://openrouter.ai/anthropic/claude-sonnet-5-5"))
        #expect(event.id == AIEvent.makeID(kind: .newModel, vendorId: .claude,
                                           components: ["anthropic/claude-sonnet-5-5"]))
    }

    @Test("a new model with no creation date falls back to now and omits a missing price side")
    func newModelPartialFacts() throws {
        let (events, _) = CatalogDiff.compute(
            previous: ["x-ai/grok-5": record("x-ai/grok-5", vendor: .grok)],
            current: [entry("x-ai/grok-5"), entry("x-ai/grok-6", prompt: nil, completion: "0.000015")],
            now: now)
        let event = try #require(events.first)
        #expect(event.vendorId == .grok)
        #expect(event.occurredAt == now)
        #expect(event.detail == "Completion $15.00 per million tokens")
    }

    @Test("a price change is detected exactly in Decimal and names only the changed side")
    func priceChange() throws {
        let (events, records) = CatalogDiff.compute(
            previous: ["openai/gpt-6": record("openai/gpt-6", vendor: .openai,
                                              prompt: "0.0000025", completion: "0.00001")],
            current: [entry("openai/gpt-6", name: "OpenAI: GPT-6", prompt: "0.000002", completion: "0.00001")],
            now: now)
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.kind == .priceChange)
        #expect(event.title == "OpenAI: GPT-6 price changed")
        #expect(event.detail == "Prompt $2.50 → $2.00 per M tokens")
        #expect(event.id == AIEvent.makeID(kind: .priceChange, vendorId: .openai,
                                           components: ["openai/gpt-6", "0.000002", "0.00001"]))
        #expect(records.first?.promptPrice == price("0.000002"))
        #expect(records.first?.firstSeen == earlier)
        #expect(records.first?.lastSeen == now)
    }

    /// The same decimal string must never read as a change. Through Double,
    /// representations of one price can differ; through Decimal they cannot.
    @Test("an identical price written the same way is not a change")
    func unchangedPriceSilent() {
        let (events, _) = CatalogDiff.compute(
            previous: ["google/gemini-4-pro": record("google/gemini-4-pro", vendor: .gemini,
                                                     prompt: "0.0000001", completion: "0.0000003")],
            current: [entry("google/gemini-4-pro", prompt: "0.0000001", completion: "0.0000003")],
            now: now)
        #expect(events.isEmpty)
    }

    @Test("a price appearing or vanishing is recorded silently")
    func unknownSideSilent() {
        let (events, records) = CatalogDiff.compute(
            previous: ["openai/gpt-6": record("openai/gpt-6", vendor: .openai, prompt: nil)],
            current: [entry("openai/gpt-6", prompt: "0.000002")],
            now: now)
        #expect(events.isEmpty)
        #expect(records.first?.promptPrice == price("0.000002"))
    }

    @Test("variant ids are stored but never announced")
    func variantsIgnored() {
        let (events, records) = CatalogDiff.compute(
            previous: ["anthropic/claude-opus-5-5": record("anthropic/claude-opus-5-5"),
                       "openai/gpt-6:batch": record("openai/gpt-6:batch", vendor: .openai, prompt: "0.000001")],
            current: [entry("anthropic/claude-opus-5-5"),
                      entry("anthropic/claude-opus-5-5:thinking"),
                      entry("google/gemini-4-flash:free", prompt: "0", completion: "0"),
                      entry("openai/gpt-6:batch", prompt: "0.0000005")],
            now: now)
        #expect(events.isEmpty)
        #expect(Set(records.map(\.modelId)) == [
            "anthropic/claude-opus-5-5", "anthropic/claude-opus-5-5:thinking",
            "google/gemini-4-flash:free", "openai/gpt-6:batch",
        ])
    }

    @Test("untracked vendor prefixes are neither stored nor announced")
    func unknownPrefixIgnored() {
        let (events, records) = CatalogDiff.compute(
            previous: ["anthropic/claude-opus-5-5": record("anthropic/claude-opus-5-5")],
            current: [entry("anthropic/claude-opus-5-5"), entry("mistralai/mistral-large-3"),
                      entry("openrouter/auto"), entry("deepseek/deepseek-v4")],
            now: now)
        #expect(events.isEmpty)
        #expect(records.map(\.modelId) == ["anthropic/claude-opus-5-5"])
    }

    @Test("prefix mapping covers exactly the tracked vendors")
    func prefixMapping() {
        #expect(CatalogDiff.vendor(forModelId: "anthropic/x") == .claude)
        #expect(CatalogDiff.vendor(forModelId: "openai/x") == .openai)
        #expect(CatalogDiff.vendor(forModelId: "google/x") == .gemini)
        #expect(CatalogDiff.vendor(forModelId: "x-ai/x") == .grok)
        #expect(CatalogDiff.vendor(forModelId: "meta-llama/x") == nil)
        #expect(CatalogDiff.vendor(forModelId: "anthropicx/x") == nil)
    }

    @Test("per-million formatting rounds in Decimal to two places")
    func perMillionFormatting() {
        #expect(CatalogDiff.perMillion(price("0.000003")) == "$3.00")
        #expect(CatalogDiff.perMillion(price("0.00000015")) == "$0.15")
        #expect(CatalogDiff.perMillion(price("0.0000001234")) == "$0.12")
        #expect(CatalogDiff.perMillion(price("0.000075")) == "$75.00")
        #expect(CatalogDiff.perMillion(price("0")) == "$0.00")
    }

    @Test("catalog JSON parses ids, names, dates and decimal prices; junk is nil")
    func parseCatalog() throws {
        let json = #"""
        {"data":[
          {"id":"anthropic/claude-opus-5-5","name":"Anthropic: Claude Opus 5.5","created":1790000000,
           "pricing":{"prompt":"0.000005","completion":"0.000025"}},
          {"id":"openai/gpt-6","name":"OpenAI: GPT-6","pricing":{"prompt":"","completion":"n/a"}}
        ]}
        """#
        let entries = try #require(OpenRouterCatalogWatcher.parse(Data(json.utf8)))
        #expect(entries.count == 2)
        #expect(entries[0].created == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(entries[0].promptPrice == price("0.000005"))
        #expect(entries[1].created == nil)
        #expect(entries[1].promptPrice == nil)
        #expect(entries[1].completionPrice == nil)
        #expect(OpenRouterCatalogWatcher.parse(Data("<html>".utf8)) == nil)
    }
}

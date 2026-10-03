import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("Provider order editing")
struct ProviderOrderEditingTests {

    private let order: [VendorIdentifier] = [.claude, .openai, .gemini]

    @Test("moving swaps with the neighbour")
    func moves() {
        #expect(ProviderOrderEditing.move(.openai, by: -1, in: order) == [.openai, .claude, .gemini])
        #expect(ProviderOrderEditing.move(.openai, by: 1, in: order) == [.claude, .gemini, .openai])
    }

    @Test("a move past either end changes nothing")
    func edges() {
        #expect(ProviderOrderEditing.move(.claude, by: -1, in: order) == order)
        #expect(ProviderOrderEditing.move(.gemini, by: 1, in: order) == order)
    }

    @Test("a vendor not in the list changes nothing")
    func unknown() {
        #expect(ProviderOrderEditing.move(.kiro, by: 1, in: order) == order)
    }

    @Test("showing and hiding toggle membership")
    func visibility() {
        #expect(ProviderOrderEditing.setShown(false, .grok, hidden: []) == [.grok])
        #expect(ProviderOrderEditing.setShown(true, .grok, hidden: [.grok, .kiro]) == [.kiro])
        #expect(ProviderOrderEditing.setShown(true, .grok, hidden: []) == [])
    }
}

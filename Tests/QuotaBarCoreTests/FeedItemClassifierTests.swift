import Testing
import Foundation
@testable import QuotaBarCore

@Suite("FeedItemClassifier")
struct FeedItemClassifierTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let title: String
        let summary: String
        let expected: AIEventKind?
        var testDescription: String { title }
    }

    static let cases: [Case] = [
        // Real titles from the vendor feeds.
        Case(title: "A model guide for the GPT-6 family", summary: "", expected: .newModel),
        Case(title: "Chatham scales its capital markets expertise with OpenAI", summary: "", expected: nil),
        Case(title: "Gemini 4 Argon: our next era of frontier intelligence", summary: "", expected: .newModel),
        Case(title: "Introducing SynthID Bio", summary: "Built on Gemini, SynthID Bio watermarks…", expected: nil),
        Case(title: "The latest AI news we announced in September 2026", summary: "Gemini, Flash and more", expected: nil),
        Case(title: "Anthropic invests $100 million to train 10,000 engineers", summary: "Claude partners", expected: nil),
        // Announcements.
        Case(title: "Introducing Claude Sonnet 5.5", summary: "", expected: .newModel),
        Case(title: "Meet Grok 5", summary: "", expected: .newModel),
        Case(title: "o5-mini is now available in the API", summary: "", expected: .newModel),
        Case(title: "Launching Gemini 4 Flash", summary: "", expected: .newModel),
        Case(title: "Announcing new models for developers", summary: "", expected: nil),
        // Product posts name a family but no versioned model: never a release.
        Case(title: "Introducing Gemini in Chrome", summary: "", expected: nil),
        Case(title: "Introducing Claude for Financial Services", summary: "", expected: nil),
        Case(title: "Claude Code now available in Slack", summary: "", expected: nil),
        Case(title: "Meet the new Gemini app", summary: "", expected: nil),
        Case(title: "Launching Flash flood forecasting", summary: "", expected: nil),
        Case(title: "Introducing GPT-6.1 Sol", summary: "", expected: .newModel),
        Case(title: "Grok 4.7 is now available", summary: "", expected: .newModel),
        // A family name without an announcement is not a release.
        Case(title: "How we evaluate Claude for safety", summary: "", expected: nil),
        // Word boundaries: no family hidden inside other words.
        Case(title: "Introducing our operations team in Tokyo", summary: "", expected: nil),
        Case(title: "Launching progress dashboards", summary: "", expected: nil),
        // Pricing.
        Case(title: "Lower pricing for GPT-6 mini", summary: "", expected: .priceChange),
        Case(title: "Claude Opus 5.5 is now 50% off in batch", summary: "", expected: .priceChange),
        Case(title: "Batch API: 50% off every request", summary: "", expected: .priceChange),
        Case(title: "Higher rate limits for Pro subscribers", summary: "", expected: .priceChange),
        Case(title: "Rate limits increased for the API", summary: "", expected: .priceChange),
        Case(title: "New pricing", summary: "Updated prices for the Gemini API", expected: .priceChange),
        Case(title: "The price of progress in robotics research", summary: "an essay", expected: nil),
    ]

    @Test("classifies conservatively", arguments: cases)
    func classify(_ c: Case) {
        #expect(FeedItemClassifier.classify(title: c.title, summary: c.summary) == c.expected)
    }
}

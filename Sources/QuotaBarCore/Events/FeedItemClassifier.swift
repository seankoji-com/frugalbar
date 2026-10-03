import Foundation

/// Decides whether a vendor-feed item announces a model or a price change.
///
/// Conservative on purpose. A vendor news feed is mostly partnerships, case
/// studies, research and policy, and a false "New model" banner costs more
/// than a missed one: the user stops trusting the banners, and the OpenRouter
/// catalog catches most real releases anyway. So:
///
/// - A **new model** needs an announcement phrase *and* a versioned model
///   name ("Claude Sonnet 5.5", "GPT-6", "Gemini 4", "Grok 5", "o5"), both in
///   the **title**. A family name alone is not enough: "Introducing Gemini in
///   Chrome", "Introducing Claude for Financial Services" and "Meet the new
///   Gemini app" are product posts, and a vendor blog publishes several a
///   week. Summaries are too noisy to qualify on: a partnership post's
///   summary routinely names the model the partner uses, and "Introducing
///   SynthID Bio" built on Gemini is still not a Gemini release.
/// - A **price change** needs a pricing phrase in the title, plus some sign
///   in the title or summary that it is about a model, a plan or the API.
///   Money alone is not pricing — "Anthropic invests $100 million" mentions a
///   sum, not a price.
/// - Matching is case-insensitive and on word boundaries, so "operations"
///   does not contain "o3" and "progress" does not contain "pro".
public enum FeedItemClassifier {

    /// Phrases that announce something. Matched as whole words/phrases.
    static let announcementPatterns = [
        "introduc(?:ing|es)",
        "announc(?:ing|es)",
        "launch(?:ing|es|ed)?",
        "now available",
        "meet",
        "new models?",
        "our next",
        "model guide",
    ]

    /// Model-family names. "pro" is deliberately absent: it only ever
    /// qualifies alongside one of these, and then it adds nothing. Used as
    /// pricing context; a *release* needs `versionedModelPatterns`.
    static let familyPatterns = [
        "claude", "sonnet", "opus", "haiku",
        "gpt", "o[0-9]",
        "gemini", "flash",
        "grok",
    ]

    /// A model name with a version number attached — what a release title
    /// carries and a product post does not: "Sonnet 5.5", "GPT-6", "Gemini
    /// 4", "Grok 4.7", "o5". Matched on word boundaries, so "operations"
    /// never yields "o3".
    static let versionedModelPatterns = [
        #"(?:claude|sonnet|opus|haiku|gpt|gemini|flash|grok)[ -]?v?\d"#,
        "o[0-9]",
    ]

    static let pricingPatterns = [
        "pric(?:e|es|ed|ing)",
        "cheaper",
        "cost reductions?",
        "reduced costs?",
        "lower costs?",
    ]

    /// Pricing-adjacent phrases that do not fit a single word boundary.
    ///
    /// Rate-limit and usage-limit increases are deliberately not here. They
    /// are allowance news, not price news, and recording one as a "Price
    /// change" would be a different fact from the one the vendor announced.
    static let pricingRegexes = [
        // "50% off"
        #"\d+\s*%\s*off\b"#,
    ]

    /// What makes a pricing phrase about a model, plan or the API rather
    /// than, say, the price of a partner's product.
    static let pricingContextPatterns = familyPatterns + [
        "api", "plans?", "subscriptions?", "tiers?", "tokens?", "models?",
        "plus", "pro", "max", "team", "enterprise", "chatgpt", "codex",
    ]

    public static func classify(title: String, summary: String) -> AIEventKind? {
        if matchesAny(announcementPatterns, in: title), matchesAny(versionedModelPatterns, in: title) {
            return .newModel
        }
        let isPricing = matchesAny(pricingPatterns, in: title)
            || pricingRegexes.contains { matches(regex: $0, in: title) }
        if isPricing, matchesAny(pricingContextPatterns, in: title + " " + summary) {
            return .priceChange
        }
        return nil
    }

    private static func matchesAny(_ words: [String], in text: String) -> Bool {
        words.contains { matches(regex: #"\b"# + "(?:\($0))" + #"\b"#, in: text) }
    }

    private static func matches(regex: String, in text: String) -> Bool {
        text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

import Foundation

/// One item from an RSS 2.0 or Atom feed, normalised.
public struct FeedItem: Sendable, Equatable {
    /// The feed's own identity for the item: RSS `guid`, else Atom `id`, else
    /// the link. This is the deduplication key, so it is never derived from
    /// the title — a reworded headline must not read as a new post.
    public let id: String
    public let title: String
    /// Plain text: tags stripped, entities decoded, whitespace collapsed.
    public let summary: String
    public let link: URL?
    public let published: Date?

    public init(id: String, title: String, summary: String, link: URL?, published: Date?) {
        self.id = id
        self.title = title
        self.summary = summary
        self.link = link
        self.published = published
    }
}

/// Parses RSS 2.0 and Atom with Foundation's `XMLParser`.
///
/// Lenient by design: a missing field is nil or empty, CDATA is text, and an
/// item without any stable identity (no guid, id, or link) is dropped rather
/// than keyed on something that could change. A document that is not XML at
/// all yields whatever items were complete before the error — usually none.
public enum FeedParser {

    public static func parse(_ data: Data) -> [FeedItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    // MARK: - Dates

    /// RFC 822 / RFC 1123 as RSS feeds actually write it, including the
    /// common deviations (named zones, no seconds, no weekday).
    static func parseRFC822(_ text: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parseISO8601(trimmed) ?? parseRFC822(trimmed)
    }

    // MARK: - Text

    /// Strips tags, decodes the entities feeds actually use, and collapses
    /// whitespace. Not an HTML renderer: the result is a one-line caption.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"), ("&mdash;", "\u{2014}"),
            ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}"),
        ]
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = decodeNumericEntities(text)
        // `&amp;` last, so "&amp;lt;" becomes the literal "&lt;" it encodes.
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#"),
              let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        else { return text }
        var result = ""
        var cursor = text.startIndex
        let nsText = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard let whole = Range(match.range, in: text),
                  let body = Range(match.range(at: 1), in: text)
            else { continue }
            result += text[cursor..<whole.lowerBound]
            let code = text[body]
            let value = code.hasPrefix("x")
                ? UInt32(code.dropFirst(), radix: 16)
                : UInt32(code, radix: 10)
            if let value, let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += text[whole]
            }
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [FeedItem] = []

        private struct Draft {
            var guid: String?
            var atomID: String?
            var link: String?
            var hasAlternateLink = false
            var title: String?
            var summary: String?
            var published: String?
            var updated: String?
        }

        private var draft: Draft?
        /// Depth of the element stack *inside* the current item, so a nested
        /// element (an Atom `author/name`, say) is not read as a field.
        private var depth = 0
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes: [String: String] = [:]
        ) {
            if elementName == "item" || elementName == "entry" {
                draft = Draft()
                depth = 0
                return
            }
            guard draft != nil else { return }
            depth += 1
            text = ""
            // Atom carries the link as an attribute. Prefer the alternate
            // (human-readable) link; take the first link otherwise.
            if depth == 1, elementName == "link", let href = attributes["href"], !href.isEmpty {
                let isAlternate = (attributes["rel"] ?? "alternate") == "alternate"
                if isAlternate, draft?.hasAlternateLink == false {
                    draft?.link = href
                    draft?.hasAlternateLink = true
                } else if draft?.link == nil {
                    draft?.link = href
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard draft != nil else { return }
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard draft != nil else { return }
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard var current = draft else { return }
            if elementName == "item" || elementName == "entry" {
                finish(current)
                draft = nil
                return
            }
            defer { depth -= 1; text = "" }
            guard depth == 1 else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            switch elementName {
            case "guid":                  current.guid = value
            case "id":                    current.atomID = value
            case "link":                  if current.link == nil { current.link = value }
            case "title":                 current.title = value
            case "description", "summary":
                current.summary = value
            case "content", "content:encoded":
                if current.summary == nil { current.summary = value }
            case "pubDate", "published", "dc:date":
                current.published = value
            case "updated":               current.updated = value
            default:                      break
            }
            draft = current
        }

        private func finish(_ draft: Draft) {
            guard let id = draft.guid ?? draft.atomID ?? draft.link else { return }
            let title = FeedParser.plainText(draft.title ?? "")
            items.append(FeedItem(
                id: id,
                title: title,
                summary: FeedParser.plainText(draft.summary ?? ""),
                link: draft.link.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                published: (draft.published ?? draft.updated).flatMap(FeedParser.parseDate)
            ))
        }
    }
}

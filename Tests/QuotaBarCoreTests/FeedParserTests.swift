import Testing
import Foundation
@testable import QuotaBarCore

@Suite("FeedParser")
struct FeedParserTests {

    static let rss = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>OpenAI News</title>
        <link>https://openai.com/news</link>
        <atom:link href="https://openai.com/news/rss.xml" rel="self"/>
        <item>
          <title><![CDATA[A model guide for the GPT-6 family]]></title>
          <description><![CDATA[<p>Which <b>GPT-6</b> model fits your task &amp; budget.</p>]]></description>
          <link>https://openai.com/index/gpt-6-model-guide</link>
          <guid isPermaLink="false">gpt-6-model-guide</guid>
          <category>Product</category>
          <pubDate>Thu, 01 Oct 2026 17:00:00 GMT</pubDate>
        </item>
        <item>
          <title>Chatham scales its capital markets expertise with OpenAI</title>
          <link>https://openai.com/index/chatham</link>
          <pubDate>Wed, 30 Sep 2026 09:30:00 +0000</pubDate>
        </item>
        <item>
          <title>Item with nothing to identify it</title>
        </item>
      </channel>
    </rss>
    """#

    static let atom = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Google DeepMind</title>
      <id>urn:deepmind:blog</id>
      <updated>2026-10-02T12:00:00Z</updated>
      <entry>
        <id>urn:deepmind:gemini-4-argon</id>
        <title>Gemini 4 Argon: our next era of frontier intelligence</title>
        <link rel="related" href="https://example.com/related"/>
        <link rel="alternate" type="text/html" href="https://deepmind.google/blog/gemini-4-argon/"/>
        <author><name>Gemini Team</name></author>
        <summary type="html">&lt;p&gt;Our most capable model yet.&lt;/p&gt;</summary>
        <published>2026-10-02T10:15:30.500Z</published>
        <updated>2026-10-02T11:00:00Z</updated>
      </entry>
      <entry>
        <id>urn:deepmind:synthid-bio</id>
        <title>Introducing SynthID Bio</title>
        <link href="https://deepmind.google/blog/synthid-bio/"/>
        <updated>2026-09-29T08:00:00Z</updated>
      </entry>
    </feed>
    """#

    @Test("RSS items parse with guid, CDATA title, stripped description, link and RFC 822 date")
    func parsesRSS() throws {
        let items = FeedParser.parse(Data(Self.rss.utf8))
        #expect(items.count == 2)
        let first = try #require(items.first)
        #expect(first.id == "gpt-6-model-guide")
        #expect(first.title == "A model guide for the GPT-6 family")
        #expect(first.summary == "Which GPT-6 model fits your task & budget.")
        #expect(first.link == URL(string: "https://openai.com/index/gpt-6-model-guide"))
        #expect(first.published == FeedParser.parseISO8601("2026-10-01T17:00:00Z"))

        // No guid: the link is the identity.
        #expect(items[1].id == "https://openai.com/index/chatham")
        #expect(items[1].summary == "")
        #expect(items[1].published == FeedParser.parseISO8601("2026-09-30T09:30:00Z"))
    }

    @Test("Atom entries parse with id, alternate link, decoded summary, published over updated")
    func parsesAtom() throws {
        let items = FeedParser.parse(Data(Self.atom.utf8))
        #expect(items.count == 2)
        let first = try #require(items.first)
        #expect(first.id == "urn:deepmind:gemini-4-argon")
        #expect(first.title == "Gemini 4 Argon: our next era of frontier intelligence")
        #expect(first.link == URL(string: "https://deepmind.google/blog/gemini-4-argon/"))
        #expect(first.summary == "Our most capable model yet.")
        #expect(first.published == Date(timeIntervalSince1970: 1_790_936_130.5))

        #expect(items[1].link == URL(string: "https://deepmind.google/blog/synthid-bio/"))
        #expect(items[1].published == FeedParser.parseISO8601("2026-09-29T08:00:00Z"))
        #expect(items[1].summary == "")
    }

    @Test("non-XML input yields no items rather than crashing")
    func garbage() {
        #expect(FeedParser.parse(Data("not xml at all".utf8)).isEmpty)
        #expect(FeedParser.parse(Data()).isEmpty)
    }

    @Test("RFC 822 variants and ISO 8601 variants parse")
    func dates() {
        let expected = Date(timeIntervalSince1970: 1_791_032_400) // 2026-10-03T13:00:00Z
        #expect(FeedParser.parseDate("Sat, 03 Oct 2026 13:00:00 GMT") == expected)
        #expect(FeedParser.parseDate("Sat, 3 Oct 2026 13:00:00 +0000") == expected)
        #expect(FeedParser.parseDate("Sat, 03 Oct 2026 23:00:00 +1000") == expected)
        #expect(FeedParser.parseDate("03 Oct 2026 13:00:00 +0000") == expected)
        #expect(FeedParser.parseDate("2026-10-03T13:00:00Z") == expected)
        #expect(FeedParser.parseDate("2026-10-03T13:00:00.000Z") == expected)
        #expect(FeedParser.parseDate("") == nil)
        #expect(FeedParser.parseDate("yesterday") == nil)
    }

    @Test("plain text strips tags and decodes entities, including numeric ones")
    func plainText() {
        #expect(FeedParser.plainText("<p>Hello&nbsp;<i>world</i></p>\n\n  again") == "Hello world again")
        #expect(FeedParser.plainText("It&#8217;s &#x2014; &quot;fine&quot; &amp;lt;") == "It\u{2019}s \u{2014} \"fine\" &lt;")
    }
}

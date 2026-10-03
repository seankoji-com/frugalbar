import Testing
import Foundation
@testable import QuotaBarCore

/// Counts fetches per feed so a test can assert a stub was (or was not) hit.
final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func hit(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

func makeIsolatedEventStore() -> QuotaHistoryStore {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FrugalBarTests-\(UUID().uuidString)", isDirectory: true)
    return QuotaHistoryStore(databaseURL: tempDir.appendingPathComponent("events.sqlite3"), isTestHost: true)
}

@Suite("VendorFeedWatcher")
struct VendorFeedWatcherTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let openaiFeed = VendorFeed(
        name: "openai-news", url: URL(string: "https://example.invalid/openai.xml")!,
        vendorId: .openai, isOfficial: true)
    private let anthropicFeed = VendorFeed(
        name: "anthropic-news", url: URL(string: "https://example.invalid/anthropic.xml")!,
        vendorId: .claude, isOfficial: false)

    private func item(_ id: String, _ title: String, daysAgo: Double?) -> FeedItem {
        FeedItem(id: id, title: title, summary: "summary \(id)",
                 link: URL(string: "https://example.invalid/\(id)"),
                 published: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    @Test("first run keeps only the last week, marks everything seen, and builds feed events")
    func firstRunCutoff() async throws {
        let store = makeIsolatedEventStore()
        let log = FetchLog()
        let items = [
            item("recent", "Introducing GPT-6", daysAgo: 1),
            item("old", "Introducing GPT-5", daysAgo: 30),
            item("undated", "Introducing GPT-4o", daysAgo: nil),
            item("chatter", "Chatham scales its capital markets expertise with OpenAI", daysAgo: 1),
        ]
        let feed = openaiFeed
        let watcher = VendorFeedWatcher(feeds: [feed]) { f in
            log.hit(f.name)
            return items
        }
        let events = await watcher.poll(store: store, now: now)

        #expect(log.count("openai-news") == 1)
        #expect(events.map(\.title) == ["Introducing GPT-6"])
        let event = try #require(events.first)
        #expect(event.kind == .newModel)
        #expect(event.vendorId == .openai)
        #expect(event.source == .vendorFeed(name: "openai-news"))
        #expect(event.occurredAt == now.addingTimeInterval(-86_400))
        #expect(event.observedAt == now)
        #expect(event.url == URL(string: "https://example.invalid/recent"))
        #expect(event.detail == "summary recent")
        #expect(event.id == AIEvent.makeID(kind: .newModel, vendorId: .openai, components: ["recent"]))

        let seen = try await store.seenFeedItemIDs(feed: "openai-news")
        #expect(seen == ["recent", "old", "undated", "chatter"])
    }

    @Test("later runs skip seen ids and accept any age")
    func seenSkipped() async throws {
        let store = makeIsolatedEventStore()
        try await store.markFeedItemsSeen(feed: "openai-news", ids: ["known"], at: now)
        let feed = openaiFeed
        let watcher = VendorFeedWatcher(feeds: [feed]) { _ in
            [self.item("known", "Introducing GPT-6", daysAgo: 0),
             self.item("late", "Meet GPT-6 mini", daysAgo: 20)]
        }
        let events = await watcher.poll(store: store, now: now)
        #expect(events.map(\.title) == ["Meet GPT-6 mini"])
    }

    @Test("one failing feed does not block the others")
    func failureIsolated() async throws {
        let store = makeIsolatedEventStore()
        let log = FetchLog()
        let feeds = [openaiFeed, anthropicFeed]
        let watcher = VendorFeedWatcher(feeds: feeds) { f in
            log.hit(f.name)
            if f.name == "openai-news" { return nil }
            return [FeedItem(id: "sonnet", title: "Introducing Claude Sonnet 5.5", summary: "",
                             link: nil, published: self.now)]
        }
        let events = await watcher.poll(store: store, now: now)
        #expect(log.count("openai-news") == 1)
        #expect(log.count("anthropic-news") == 1)
        #expect(events.map(\.vendorId) == [.claude])
        #expect(try await store.seenFeedItemIDs(feed: "openai-news").isEmpty)
    }

    @Test("the unofficial feed says so in its source caption")
    func unofficialCaption() {
        #expect(AIEventSource.vendorFeed(name: "anthropic-news").label
                == "From the anthropic-news feed (unofficial scrape)")
        #expect(AIEventSource.vendorFeed(name: "openai-news").label == "From the openai-news feed")
        #expect(VendorFeed.all.filter { !$0.isOfficial }.map(\.name) == ["anthropic-news"])
        #expect(!VendorFeed.all.contains { $0.vendorId == .grok })
    }

    @Test("the live fetch checks status before parsing and is stubbed, not real")
    func liveFetchChecksStatus() async throws {
        let log = FetchLog()
        let ok = try await withEventStub({ request in
            log.hit(request.url?.host ?? "")
            return (200, Data(FeedParserTests.rss.utf8))
        }) {
            await VendorFeedWatcher.liveFetch(self.openaiFeed)
        }
        #expect(ok?.count == 2)
        let notFound = try await withEventStub({ request in
            log.hit(request.url?.host ?? "")
            return (404, Data(FeedParserTests.rss.utf8))
        }) {
            await VendorFeedWatcher.liveFetch(self.openaiFeed)
        }
        #expect(notFound == nil)
        #expect(log.count("example.invalid") == 2)
    }
}

// MARK: - URLProtocol stub for the live fetchers

final class EventHTTPStub: URLProtocol {
    typealias Responder = @Sendable (URLRequest) -> (Int, Data)
    nonisolated(unsafe) private static var responder: Responder?
    private static let lock = NSLock()

    static func install(_ responder: Responder?) { lock.withLock { self.responder = responder } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let responder = Self.lock.withLock { Self.responder }
        guard let responder, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, body) = responder(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialises use of the shared stub responder across suites.
let eventStubGate = AsyncGate()

actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

func withEventStub<T: Sendable>(
    _ responder: @escaping EventHTTPStub.Responder,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    await eventStubGate.acquire()
    EventHTTPStub.install(responder)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [EventHTTPStub.self]
    let session = URLSession(configuration: config)
    do {
        let result = try await QuotaHTTP.$session.withValue(session) { try await operation() }
        session.finishTasksAndInvalidate()
        EventHTTPStub.install(nil)
        await eventStubGate.release()
        return result
    } catch {
        session.finishTasksAndInvalidate()
        EventHTTPStub.install(nil)
        await eventStubGate.release()
        throw error
    }
}

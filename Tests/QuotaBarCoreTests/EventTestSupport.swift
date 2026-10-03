import Foundation
@testable import QuotaBarCore

// Shared support for the AI-event suites: an isolated store, a fetch counter,
// and a URLProtocol stub for the live fetchers.

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

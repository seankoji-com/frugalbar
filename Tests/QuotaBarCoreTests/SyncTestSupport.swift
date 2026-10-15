import Foundation
import Synchronization
@testable import QuotaBarCore

// Sync tests never reach the network: Google is `FakeGoogle`, time is
// `FakeSyncClock`, and the Keychain is `InMemorySyncSecrets`. Every token,
// code and client value here is an obvious fake.

enum SyncFakes {
    static let configuration = SyncClientConfiguration(
        clientID: "fake-client-id.apps.example.test", clientSecret: "fake-client-secret-for-tests")
    static let refreshToken = "fake-refresh-token-for-tests"
    static let account = SyncAccount(permissionId: "perm-owner-01", email: "owner@example.test")
    static let otherAccount = SyncAccount(permissionId: "perm-other-02", email: "someone.else@example.test")
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    static func snapshot(
        _ id: String = "claude",
        used: Double = 0.4,
        measuredAt: Date = start,
        status: ProviderStatus = .healthy
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id, vendorId: .claude, displayName: "Claude", category: .aiSubscriptions,
            metric: .percentage(usedFraction: used, displayDetails: nil), status: status, resetsAt: nil,
            lastUpdated: measuredAt, auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: used, label: "5H"), row2: nil)
    }

    static func source(_ snapshots: [QuotaSnapshot] = [snapshot()]) -> SyncExportSource {
        SyncExportSource(snapshots: snapshots)
    }
}

/// Wall-clock time that moves only when a test says so. Sleepers resume when
/// `advance` passes their deadline, or throw when cancelled.
final class FakeSyncClock: SyncClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    init(_ start: Date = SyncFakes.start) { current = start }

    func now() -> Date { lock.withLock { current } }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let sleeper = sleepers.removeValue(forKey: id) {
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelled.insert(id)
                lock.unlock()
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        set(now().addingTimeInterval(seconds))
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        let due = sleepers.filter { $0.value.deadline <= date }
        for id in due.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for sleeper in due.values { sleeper.continuation.resume() }
    }
}

final class InMemorySyncSecrets: SyncSecretStore {
    private let items = Mutex<[String: String]>([:])
    /// When set, writes "succeed" but read back nothing.
    let dropsWrites: Bool

    init(dropsWrites: Bool = false, initial: [String: String] = [:]) {
        self.dropsWrites = dropsWrites
        items.withLock { $0 = initial }
    }

    func read(_ account: String) throws -> String? { items.withLock { $0[account] } }
    func write(_ value: String, account: String) throws {
        guard !dropsWrites else { return }
        items.withLock { $0[account] = value }
    }
    func delete(_ account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
}

/// Google's token endpoint and Drive's app-data folder, in memory.
actor FakeGoogle: SyncTransport {
    struct File {
        var id: String
        var createdTime: Date
        var modifiedTime: Date
        var publisherId: String?
        var content: Data
    }

    enum UploadMode {
        case normal
        /// Never answers until cancelled; nothing is committed.
        case hang
        /// Commits, then never answers until cancelled.
        case commitThenHang
        case status(Int)
        /// Commits, then answers 200 with a body that has no file id.
        case commitMalformed
    }

    let clock: FakeSyncClock
    private(set) var files: [String: File] = [:]
    private(set) var requests: [SyncHTTPRequest] = []
    private var nextId = 1

    var pageSize = 100
    var invalidPageTokens = 0
    /// The `Date` header is `clock.now() + serverOffset`, or absent when nil.
    var serverOffset: TimeInterval? = 0
    /// Overrides `serverOffset` on `files.get` metadata responses only.
    var metadataServerOffset: TimeInterval?? = .none
    /// Thrown by the token endpoint instead of answering.
    var tokenFailure: URLError?
    var uploadModes: [UploadMode] = []
    /// Token-endpoint answers to give before the default success.
    var tokenResponses: [SyncHTTPResponse] = []
    var tokenRequests = 0
    /// The next N verification reads find older bytes: a late write landed.
    var staleReads = 0
    /// The next N `files.get` metadata reads are held until `releaseAll`.
    var metadataHolds = 0
    var aboutAccount = SyncFakes.account
    private var held: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var heldCancelled: Set<UUID> = []

    init(clock: FakeSyncClock) { self.clock = clock }

    func configure(_ change: @Sendable (isolated FakeGoogle) -> Void) { change(self) }

    // MARK: Inspection

    var uploads: [SyncHTTPRequest] { requests.filter { $0.url.path.hasPrefix("/upload/") } }
    var heldCount: Int { held.count }
    var driveRequests: [SyncHTTPRequest] { requests.filter { $0.url.host == "www.googleapis.com" } }

    @discardableResult
    func seed(publisherId: String?, created: Date, modified: Date? = nil, content: Data = Data("{}".utf8)) -> String {
        let id = "file-\(nextId)"
        nextId += 1
        files[id] = File(id: id, createdTime: created, modifiedTime: modified ?? created, publisherId: publisherId, content: content)
        return id
    }

    func content(of id: String) -> Data? { files[id]?.content }

    func setPublisherId(_ publisherId: String?, of id: String, modified: Date? = nil) {
        files[id]?.publisherId = publisherId
        if let modified { files[id]?.modifiedTime = modified }
    }

    /// Lets every held upload carry on as if the network answered.
    func releaseAll() {
        let continuations = held.values
        held.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    /// The uploaded document bytes, in order.
    func uploadedContents() -> [Data] { uploads.map { Self.parseMultipart($0).1 } }

    /// The uploaded documents, parsed, in order.
    nonisolated func uploadedDocuments() async -> [[String: Any]] {
        await uploadedContents().compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    func uploadedPublisherIds() -> [String?] { uploads.map { Self.parseMultipart($0).0 } }

    // MARK: Transport

    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        requests.append(request)
        if request.url.host == "oauth2.googleapis.com" {
            if let tokenFailure { tokenRequests += 1; throw tokenFailure }
            return token(request)
        }
        let path = request.url.path
        let query = request.queryItems
        switch (request.method, path) {
        case ("GET", "/drive/v3/files"):
            return list(query)
        case ("GET", "/drive/v3/about"):
            let body = #"{"user":{"permissionId":"\#(aboutAccount.permissionId)","emailAddress":"\#(aboutAccount.email)"}}"#
            return respond(200, body)
        case ("POST", "/upload/drive/v3/files"):
            return try await upload(request, fileId: nil)
        case ("PATCH", _) where path.hasPrefix("/upload/drive/v3/files/"):
            return try await upload(request, fileId: String(path.dropFirst("/upload/drive/v3/files/".count)))
        case ("GET", _) where path.hasPrefix("/drive/v3/files/"):
            let id = String(path.dropFirst("/drive/v3/files/".count))
            guard var file = files[id] else { return respond(404, "{}") }
            if query["alt"] == "media" {
                if staleReads > 0 {
                    staleReads -= 1
                    file.content = Data(#"{"stale":true}"#.utf8)
                    files[id] = file
                }
                return respond(200, file.content)
            }
            if metadataHolds > 0 {
                metadataHolds -= 1
                try await hold()
            }
            let properties = file.publisherId.map { #"{"publisherId":"\#($0)"}"# } ?? "{}"
            let body = #"{"appProperties":\#(properties),"modifiedTime":"\#(Self.rfc3339(file.modifiedTime))"}"#
            if case .some(let offset) = metadataServerOffset { return respond(200, Data(body.utf8), offset: offset) }
            return respond(200, body)
        case ("DELETE", _) where path.hasPrefix("/drive/v3/files/"):
            let id = String(path.dropFirst("/drive/v3/files/".count))
            return files.removeValue(forKey: id) == nil ? respond(404, "{}") : respond(204, "")
        default:
            return respond(400, "{}")
        }
    }

    private func token(_ request: SyncHTTPRequest) -> SyncHTTPResponse {
        tokenRequests += 1
        if !tokenResponses.isEmpty { return tokenResponses.removeFirst() }
        let form = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
        let refresh = form.contains("grant_type=authorization_code")
            ? #","refresh_token":"\#(SyncFakes.refreshToken)""# : ""
        return respond(200, #"{"access_token":"fake-access-token","expires_in":3600\#(refresh)}"#)
    }

    private func list(_ query: [String: String]) -> SyncHTTPResponse {
        if query["pageToken"] != nil, invalidPageTokens > 0 {
            invalidPageTokens -= 1
            return respond(400, #"{"error":{"errors":[{"reason":"invalid","location":"pageToken"}]}}"#)
        }
        let all = files.values.sorted { $0.createdTime != $1.createdTime ? $0.createdTime < $1.createdTime : $0.id < $1.id }
        let start = Int(query["pageToken"] ?? "0") ?? 0
        let page = all.dropFirst(start).prefix(pageSize)
        let next = start + page.count < all.count ? #","nextPageToken":"\#(start + page.count)""# : ""
        let entries = page.map { file -> String in
            let properties = file.publisherId.map { #","appProperties":{"publisherId":"\#($0)"}"# } ?? ""
            return #"{"id":"\#(file.id)","createdTime":"\#(Self.rfc3339(file.createdTime))"\#(properties)}"#
        }
        return respond(200, #"{"files":[\#(entries.joined(separator: ","))]\#(next)}"#)
    }

    private func upload(_ request: SyncHTTPRequest, fileId: String?) async throws -> SyncHTTPResponse {
        let mode = uploadModes.isEmpty ? .normal : uploadModes.removeFirst()
        if case .status(let status) = mode { return respond(status, "{}") }
        if case .hang = mode { try await hold() }
        let (publisherId, content) = Self.parseMultipart(request)
        let id: String
        if let fileId {
            guard var file = files[fileId] else { return respond(404, "{}") }
            file.content = content
            file.publisherId = publisherId ?? file.publisherId
            file.modifiedTime = clock.now()
            files[fileId] = file
            id = fileId
        } else {
            id = seed(publisherId: publisherId, created: clock.now(), content: content)
        }
        if case .commitThenHang = mode { try await hold() }
        if case .commitMalformed = mode { return respond(200, "<html></html>") }
        return respond(200, #"{"id":"\#(id)"}"#)
    }

    private func hold() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if heldCancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    held[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelHold(id) }
        }
    }

    private func cancelHold(_ id: UUID) {
        if let continuation = held.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            heldCancelled.insert(id)
        }
    }

    private func respond(_ status: Int, _ body: String) -> SyncHTTPResponse {
        respond(status, Data(body.utf8))
    }

    private func respond(_ status: Int, _ body: Data) -> SyncHTTPResponse {
        respond(status, body, offset: serverOffset)
    }

    private func respond(_ status: Int, _ body: Data, offset: TimeInterval?) -> SyncHTTPResponse {
        var headers: [String: String] = [:]
        if let serverOffset = offset {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            headers["Date"] = formatter.string(from: clock.now().addingTimeInterval(serverOffset))
        }
        return SyncHTTPResponse(status: status, headers: headers, body: body)
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The `publisherId` and content of a multipart upload.
    static func parseMultipart(_ request: SyncHTTPRequest) -> (String?, Data) {
        guard let type = request.headers["Content-Type"], let range = type.range(of: "boundary="),
              let body = request.body else { return (nil, Data()) }
        let boundary = Data("--\(type[range.upperBound...])".utf8)
        let separator = Data("\r\n\r\n".utf8)
        var parts: [Data] = []
        var cursor = body.startIndex
        while let found = body.range(of: boundary, in: cursor..<body.endIndex) {
            if found.lowerBound > cursor { parts.append(body[cursor..<found.lowerBound]) }
            cursor = found.upperBound
        }
        let payloads = parts.compactMap { part -> Data? in
            guard let header = part.range(of: separator) else { return nil }
            var payload = part[header.upperBound...]
            if payload.suffix(2) == Data("\r\n".utf8) { payload = payload.dropLast(2) }
            return Data(payload)
        }
        guard payloads.count == 2 else { return (nil, Data()) }
        let metadata = (try? JSONSerialization.jsonObject(with: payloads[0])) as? [String: Any]
        let publisherId = (metadata?["appProperties"] as? [String: String])?["publisherId"]
        return (publisherId, payloads[1])
    }
}

/// The sync state file, in memory, whose writes and reads can be made to fail.
final class FlakySyncStateStore: SyncStateStore {
    private struct Value {
        var saved = SyncPersistentState()
        var failing = false
        /// Writes that still succeed before `failing` takes over.
        var writesBeforeFailing = 0
        var loadFails = false
        var saves = 0
    }
    struct WriteFailed: Error {}
    struct ReadFailed: Error {}
    private let value = Mutex(Value())

    func load() throws -> SyncPersistentState {
        try value.withLock { value in
            if value.loadFails { throw ReadFailed() }
            return value.saved
        }
    }
    func save(_ state: SyncPersistentState) throws {
        try value.withLock { value in
            if value.failing {
                guard value.writesBeforeFailing > 0 else { throw WriteFailed() }
                value.writesBeforeFailing -= 1
            }
            value.saved = state
            value.saves += 1
        }
    }
    /// Every later write throws, and the file keeps what it held.
    func failWrites(_ failing: Bool = true) { value.withLock { $0.failing = failing; $0.writesBeforeFailing = 0 } }
    /// The next `count` writes succeed, then every one throws.
    func failWrites(after count: Int) { value.withLock { $0.failing = true; $0.writesBeforeFailing = count } }
    /// Reads throw while the record stays as it was, like a file that
    /// exists but can't be read or decoded.
    func failLoads(_ failing: Bool = true) { value.withLock { $0.loadFails = failing } }
    /// Successful writes so far.
    var saves: Int { value.withLock { $0.saves } }
    /// What the file holds, read past any load failure.
    var saved: SyncPersistentState { value.withLock { $0.saved } }
}

/// A fresh publisher, signed in and active, over `google`.
struct SyncHarness {
    let clock: FakeSyncClock
    let google: FakeGoogle
    let secrets: InMemorySyncSecrets
    let store: FlakySyncStateStore
    let publisher: SyncPublisher

    init(
        clock: FakeSyncClock = FakeSyncClock(),
        secrets: InMemorySyncSecrets? = nil,
        store: FlakySyncStateStore = FlakySyncStateStore(),
        google: FakeGoogle? = nil
    ) {
        self.clock = clock
        self.google = google ?? FakeGoogle(clock: clock)
        self.secrets = secrets ?? InMemorySyncSecrets(initial: [SyncSecretAccount.refreshToken: SyncFakes.refreshToken])
        self.store = store
        self.publisher = SyncPublisher(
            configuration: SyncFakes.configuration, transport: self.google, secrets: self.secrets,
            stateStore: store, clock: clock, label: { "Test Mac" })
    }

    /// A publisher over the same Keychain, state file and Drive: a relaunch.
    func relaunched() -> SyncHarness {
        SyncHarness(clock: clock, secrets: secrets, store: store, google: google)
    }

    static func active() async throws -> SyncHarness {
        let harness = SyncHarness()
        try await harness.publisher.activate(account: SyncFakes.account)
        return harness
    }

    /// Ticks while the publisher has work due now.
    func drain() async {
        for _ in 0..<10 {
            guard let due = await publisher.nextWakeup(), due <= clock.now() else { return }
            await publisher.tick()
        }
    }

    /// Advances in steps, ticking whenever work comes due; returns the clock
    /// time of every upload.
    @discardableResult
    func run(for seconds: TimeInterval, step: TimeInterval = 10) async -> [Date] {
        var times: [Date] = []
        let end = clock.now().addingTimeInterval(seconds)
        while clock.now() < end {
            let before = await google.uploads.count
            await drain()
            if await google.uploads.count > before { times.append(clock.now()) }
            clock.advance(by: step)
        }
        return times
    }
}

/// Polls until `condition` holds, for at most two seconds of real time.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

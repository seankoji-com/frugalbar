import CryptoKit
import Foundation

/// One `snapshot.json` in the app-data folder.
struct SyncDriveFile: Sendable, Equatable {
    let id: String
    let createdTime: Date
    let publisherId: String?
}

enum SyncDriveError: Error, Equatable, Sendable {
    case http(status: Int)
    case notFound
    case invalidPageToken
    /// The listing hit an invalid page token again after its one restart.
    case invalidPageTokenAfterRestart
    case malformed
    /// Drive answered 401 to a freshly refreshed token too.
    case unauthorized
}

/// What discovery found: the canonical file and every other copy.
struct SyncDiscovery: Sendable, Equatable {
    let canonical: SyncDriveFile?
    let duplicates: [SyncDriveFile]
    /// The listing's last `Date` header: the clock sample when there is no
    /// file yet to read metadata from.
    let serverDate: Date?
    var all: [SyncDriveFile] { (canonical.map { [$0] } ?? []) + duplicates }
}

/// `files.get(fields=appProperties,modifiedTime)` and its `Date` header.
struct SyncFileMetadata: Sendable, Equatable {
    let publisherId: String?
    let modifiedTime: Date?
    let serverDate: Date?
}

/// Drive v3 over REST, confined to the app-data folder (D§2.2.C). Every call
/// carries a bearer token from `SyncAccessTokens`; a 401 drops the cached
/// token and retries once.
struct SyncDriveClient: Sendable {
    static let apiBase = "https://www.googleapis.com/drive/v3"
    static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    static let fileName = "snapshot.json"
    static let query = "name='snapshot.json' and trashed=false"
    static let listFields = "nextPageToken,files(id,createdTime,appProperties)"
    static let publisherIdKey = "publisherId"

    let transport: any SyncTransport
    let tokens: SyncAccessTokens
    let clock: any SyncClock

    // MARK: Requests

    static func url(_ base: String, _ path: String, _ query: [(String, String)]) -> URL {
        URL(string: base + path + (query.isEmpty ? "" : "?" + SyncFormEncoding.encode(query)))!
    }

    /// Sends with a bearer token and the 20 s timeout. A 401 invalidates the
    /// token and retries once; a second 401 is `unauthorized`.
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        for attempt in 0..<2 {
            var authorized = request
            authorized.headers["Authorization"] = "Bearer \(try await tokens.accessToken())"
            let transport = self.transport
            let signed = authorized
            let response = try await withSyncTimeout(seconds: SyncPublisher.requestTimeout, clock: clock) {
                try await transport.send(signed)
            }
            guard response.status == 401 else { return response }
            await tokens.invalidate()
            if attempt == 1 { break }
        }
        throw SyncDriveError.unauthorized
    }

    static func check(_ response: SyncHTTPResponse) throws {
        guard (200...299).contains(response.status) else {
            throw response.status == 404 ? SyncDriveError.notFound : SyncDriveError.http(status: response.status)
        }
    }

    // MARK: Discovery (REQ-MAC-FILE a)

    func listPage(pageToken: String?) async throws -> (files: [SyncDriveFile], next: String?, serverDate: Date?) {
        var query: [(String, String)] = [
            ("spaces", "appDataFolder"),
            ("q", Self.query),
            ("orderBy", "createdTime"),
            ("fields", Self.listFields),
            ("pageSize", "100"),
        ]
        if let pageToken { query.append(("pageToken", pageToken)) }
        let response = try await send(SyncHTTPRequest(method: "GET", url: Self.url(Self.apiBase, "/files", query)))
        if response.status == 400, pageToken != nil { throw SyncDriveError.invalidPageToken }
        try Self.check(response)
        struct Body: Decodable {
            struct File: Decodable {
                let id: String
                let createdTime: String
                let appProperties: [String: String]?
            }
            let nextPageToken: String?
            let files: [File]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: response.body) else { throw SyncDriveError.malformed }
        let files = try (body.files ?? []).map { file -> SyncDriveFile in
            guard let created = Self.parseRFC3339(file.createdTime) else { throw SyncDriveError.malformed }
            return SyncDriveFile(id: file.id, createdTime: created, publisherId: file.appProperties?[Self.publisherIdKey])
        }
        let next = body.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        return (files, next, SyncHTTPDate.parse(response.header("date")))
    }

    /// Reads every page. An invalid page token restarts the listing once;
    /// a second one fails the run.
    func discover() async throws -> SyncDiscovery {
        var restarted = false
        while true {
            var files: [SyncDriveFile] = []
            var token: String?
            var serverDate: Date?
            do {
                repeat {
                    let page = try await listPage(pageToken: token)
                    files += page.files
                    token = page.next
                    serverDate = page.serverDate
                } while token != nil
                let selection = Self.select(files)
                return SyncDiscovery(canonical: selection.canonical, duplicates: selection.duplicates, serverDate: serverDate)
            } catch SyncDriveError.invalidPageToken {
                if restarted { throw SyncDriveError.invalidPageTokenAfterRestart }
                restarted = true
            }
        }
    }

    /// The oldest `createdTime` is canonical, ties broken by lexicographic
    /// `id`. A file listed on two pages counts once.
    static func select(_ files: [SyncDriveFile]) -> (canonical: SyncDriveFile?, duplicates: [SyncDriveFile]) {
        var seen = Set<String>()
        let sorted = files.filter { seen.insert($0.id).inserted }.sorted {
            $0.createdTime != $1.createdTime ? $0.createdTime < $1.createdTime : $0.id < $1.id
        }
        return (sorted.first, Array(sorted.dropFirst()))
    }

    // MARK: Files

    func metadata(fileId: String) async throws -> SyncFileMetadata {
        let url = Self.url(Self.apiBase, "/files/\(fileId)", [("fields", "appProperties,modifiedTime")])
        let response = try await send(SyncHTTPRequest(method: "GET", url: url))
        try Self.check(response)
        struct Body: Decodable {
            let appProperties: [String: String]?
            let modifiedTime: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: response.body) else { throw SyncDriveError.malformed }
        return SyncFileMetadata(
            publisherId: body.appProperties?[Self.publisherIdKey],
            modifiedTime: body.modifiedTime.flatMap(Self.parseRFC3339),
            serverDate: SyncHTTPDate.parse(response.header("date"))
        )
    }

    func createRequest(content: Data, publisherId: String) -> SyncHTTPRequest {
        let metadata: [String: Any] = [
            "name": Self.fileName,
            "parents": ["appDataFolder"],
            "mimeType": "application/json",
            "appProperties": [Self.publisherIdKey: publisherId],
        ]
        return uploadRequest(method: "POST", path: "/files", metadata: metadata, content: content)
    }

    func updateRequest(fileId: String, content: Data, publisherId: String) -> SyncHTTPRequest {
        let metadata: [String: Any] = ["appProperties": [Self.publisherIdKey: publisherId]]
        return uploadRequest(method: "PATCH", path: "/files/\(fileId)", metadata: metadata, content: content)
    }

    private func uploadRequest(method: String, path: String, metadata: [String: Any], content: Data) -> SyncHTTPRequest {
        let boundary = "frugalbar-\(SyncOAuth.randomToken(byteCount: 12))"
        let json = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data("{}".utf8)
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(json)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let url = Self.url(Self.uploadBase, path, [("uploadType", "multipart"), ("fields", "id")])
        return SyncHTTPRequest(
            method: method, url: url,
            headers: ["Content-Type": "multipart/related; boundary=\(boundary)"], body: body)
    }

    /// Sends an upload and returns the file id Drive reports.
    func upload(_ request: SyncHTTPRequest) async throws -> String {
        let response = try await send(request)
        try Self.check(response)
        struct Body: Decodable { let id: String }
        guard let id = (try? JSONDecoder().decode(Body.self, from: response.body))?.id else { throw SyncDriveError.malformed }
        return id
    }

    func download(fileId: String) async throws -> Data {
        let response = try await send(SyncHTTPRequest(
            method: "GET", url: Self.url(Self.apiBase, "/files/\(fileId)", [("alt", "media")])))
        try Self.check(response)
        return response.body
    }

    /// A 404 is success: the file is already gone.
    func delete(fileId: String) async throws {
        let response = try await send(SyncHTTPRequest(method: "DELETE", url: Self.url(Self.apiBase, "/files/\(fileId)", [])))
        guard response.status != 404 else { return }
        try Self.check(response)
    }

    /// `about.get`: the account's stable `permissionId` (the identity) and
    /// its email address (for display only).
    func account() async throws -> SyncAccount {
        let url = Self.url(Self.apiBase, "/about", [("fields", "user(emailAddress,permissionId)")])
        let response = try await send(SyncHTTPRequest(method: "GET", url: url))
        try Self.check(response)
        struct Body: Decodable {
            struct User: Decodable {
                let permissionId: String?
                let emailAddress: String?
            }
            let user: User?
        }
        guard let user = (try? JSONDecoder().decode(Body.self, from: response.body))?.user,
              let permissionId = user.permissionId, !permissionId.isEmpty,
              let email = user.emailAddress, !email.isEmpty
        else { throw SyncDriveError.malformed }
        return SyncAccount(permissionId: permissionId, email: email)
    }

    static func parseRFC3339(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The Google account a session publishes to. `permissionId` is the
/// identity; the email is persisted only to name the account on screen.
public struct SyncAccount: Codable, Sendable, Equatable {
    public let permissionId: String
    public let email: String

    public init(permissionId: String, email: String) {
        self.permissionId = permissionId
        self.email = email
    }
}

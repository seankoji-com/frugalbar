import Foundation
import Testing
@testable import QuotaBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// The identity boundary itself: a published value becomes a stable,
/// domain-separated fingerprint, and the ledger has no column for the value.
@Suite("Identity fingerprint")
struct IdentityFingerprintTests {

    private let account = "acct-unit-9f21"
    private let otherAccount = "acct-unit-9f22"
    private let workspace = "ws-unit-0c14"

    @Test("the same published value fingerprints to the same stored form")
    func stable() throws {
        let first = try #require(IdentityFingerprint.published(account, in: .account))
        let second = try #require(IdentityFingerprint.published(account, in: .account))
        #expect(first == second)
        #expect(first.stored == second.stored)
        #expect(first.stored.hasPrefix("fbfp1.account."))
        #expect(first.stored.count == "fbfp1.account.".count + 64)
        #expect(first.stored == first.stored.lowercased())
    }

    @Test("a different value and a different domain never share a fingerprint")
    func domainSeparation() throws {
        let asAccount = try #require(IdentityFingerprint.published(account, in: .account))
        let asWorkspace = try #require(IdentityFingerprint.published(account, in: .workspace))
        let other = try #require(IdentityFingerprint.published(otherAccount, in: .account))
        // The same string in two domains is two identities.
        #expect(asAccount != asWorkspace)
        #expect(asAccount.digest != asWorkspace.digest)
        #expect(asAccount.stored.hasPrefix("fbfp1.account."))
        #expect(asWorkspace.stored.hasPrefix("fbfp1.workspace."))
        // Two values in one domain are two identities.
        #expect(asAccount != other)
    }

    @Test("no published value is recoverable from the stored form")
    func doesNotRetainTheValue() throws {
        for domain in IdentityFingerprint.Domain.allCases {
            let fingerprint = try #require(IdentityFingerprint.published(workspace, in: domain))
            #expect(!fingerprint.stored.contains(workspace))
            #expect(!fingerprint.description.contains(workspace))
            #expect(fingerprint.stored.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))
                    || $0 == "." || $0 == "-" || $0 == "_")
            })
        }
    }

    @Test("an unpublished identity is nil, never an empty or default fingerprint")
    func unpublishedIsNil() {
        #expect(IdentityFingerprint.published(nil, in: .account) == nil)
        #expect(IdentityFingerprint.published("", in: .account) == nil)
        #expect(IdentityFingerprint.published("", in: .workspace) == nil)
        #expect(IdentityFingerprint.published("   ", in: .account) == nil)
        #expect(IdentityFingerprint.published("\n\t", in: .workspace) == nil)
    }

    @Test("a published value with content is hashed exactly, without normalisation")
    func publishedValueIsNotNormalised() throws {
        let spaced = try #require(IdentityFingerprint.published(" acct-1", in: .account))
        let trimmed = try #require(IdentityFingerprint.published("acct-1", in: .account))
        let upper = try #require(IdentityFingerprint.published("ACCT-1", in: .account))
        #expect(spaced != trimmed)
        #expect(upper != trimmed)
    }

    @Test("the stored form round-trips, and only for its own domain")
    func storedRoundTrip() throws {
        let fingerprint = try #require(IdentityFingerprint.published(account, in: .account))
        #expect(IdentityFingerprint(stored: fingerprint.stored, expecting: .account) == fingerprint)
        #expect(IdentityFingerprint(stored: fingerprint.stored, expecting: .workspace) == nil)
    }

    @Test("a stored value that is not a fingerprint is not read as an identity")
    func malformedStoredValueIsRejected() throws {
        let raw = account
        let uppercase = try #require(IdentityFingerprint.published(account, in: .account))
            .digest.uppercased()
        for stored in [
            raw,
            "fbfp1.account.not-a-digest",
            "fbfp1.account.\(uppercase)",
            "fbfp2.account.\(try #require(IdentityFingerprint.published(account, in: .account)).digest)",
            "fbfp1.workspace.\(try #require(IdentityFingerprint.published(account, in: .account)).digest)",
        ] {
            #expect(IdentityFingerprint(stored: stored, expecting: .account) == nil,
                    "\(stored) must not be read as an account identity")
        }
    }

    @Test("a target fingerprints its published input and needs an account or workspace")
    func targetCorrelation() throws {
        #expect(!AttributionBillingTarget().isCorrelated)
        #expect(!AttributionBillingTarget(billingProvider: "litellm").isCorrelated)
        let byAccount = AttributionBillingTarget(accountId: account)
        #expect(byAccount.isCorrelated)
        #expect(byAccount.accountHash == IdentityFingerprint.published(account, in: .account))
        #expect(AttributionBillingTarget(accountId: "").isCorrelated == false)
        #expect(AttributionBillingTarget(accountId: account)
            != AttributionBillingTarget(accountId: otherAccount))
    }
}

/// The ledger's own shape and read-back: there is no column for a published
/// account or workspace id, and what comes back is the fingerprint.
@Suite("Identity ledger columns")
struct IdentityLedgerColumnTests {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if canImport(SQLite3)
    private func columnNames(_ url: URL, table: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw HistoryDatabaseError.cannotOpen(path: url.path, code: -1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) { names.append(String(cString: name)) }
        }
        return names
    }
    #endif

    @Test("the ledger has fingerprint columns and no raw identity columns")
    func ledgerHasNoRawIdentityColumn() async throws {
        #if canImport(SQLite3)
        let dir = try makeTempDir("identity-columns")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuotaHistoryStore(
            databaseURL: dir.appendingPathComponent("history.sqlite3"), isTestHost: true)
        let account = "acct-columns-51ab"
        let workspace = "ws-columns-77de"
        try await store.recordActivities([
            ActivityRecord(
                source: "opencode", recordId: "columns-1", sessionId: "columns-session",
                projectPath: "/repo/columns", observedAt: Date(timeIntervalSince1970: 1_792_480_000),
                inputTokens: 90, outputTokens: 10, totalTokens: 100,
                publishedProvider: "litellm",
                accountHash: IdentityFingerprint.published(account, in: .account),
                workspaceHash: IdentityFingerprint.published(workspace, in: .workspace)),
        ])

        let names = try columnNames(store.databaseURL, table: "activity_request")
        #expect(names.contains("account_hash"))
        #expect(names.contains("workspace_hash"))
        #expect(names.contains("published_provider"))
        #expect(!names.contains("account_id"))
        #expect(!names.contains("workspace_id"))
        #expect(!names.contains("billing_provider"))

        let fetched = try await store.fetchActivities()
        let record = try #require(fetched.first)
        #expect(record.publishedProvider == "litellm")
        #expect(record.accountHash == IdentityFingerprint.published(account, in: .account))
        #expect(record.workspaceHash == IdentityFingerprint.published(workspace, in: .workspace))

        // The view the app reads exposes exactly the stored forms.
        let viewNames = try columnNames(store.databaseURL, table: "activity_unified")
        #expect(viewNames.contains("account_hash"))
        #expect(!viewNames.contains("account_id"))
        #endif
    }
}

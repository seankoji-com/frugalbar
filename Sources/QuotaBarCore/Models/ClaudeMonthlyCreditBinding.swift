import Foundation

/// Which Claude account row, if any, the linked Console organisation's monthly
/// credit belongs to.
///
/// The billing web session and the OAuth rows are separate sign-ins. A row is
/// identified by its OAuth profile's account and organisation UUIDs
/// (`ClaudeAccountProfile.instanceID`). The credit's identity is the signed-in
/// web account's UUID paired with the organisation its own billing query names
/// (`organization_uuid`), never another organisation the account belongs to.
/// The credit is attached only when exactly one row has that identity, so it
/// can never land on an arbitrary row. Email, nickname and row order are not
/// evidence of equivalence.
public enum ClaudeMonthlyCreditBinding: Equatable, Sendable {
    /// The credit belongs to this row.
    case bound(accountID: String)
    /// The web session has not published which account is signed in.
    case webAccountUnknown
    /// The signed-in claude.ai account is none of the accounts FrugalBar reads.
    case noMatchingAccount
    /// More than one row belongs to the signed-in account, and the billing
    /// page does not say which of its organisations it shows.
    case ambiguous

    public struct Row: Equatable, Sendable {
        public let accountID: String
        public let identity: String?
        public init(accountID: String, identity: String?) {
            self.accountID = accountID
            self.identity = identity
        }
    }

    public static func resolve(webIdentities: Set<String>?, rows: [Row]) -> Self {
        guard let webIdentities, !webIdentities.isEmpty else { return .webAccountUnknown }
        let matches = Set(rows.filter { $0.identity.map(webIdentities.contains) == true }.map(\.accountID))
        switch matches.count {
        case 0: return .noMatchingAccount
        case 1: return .bound(accountID: matches.first!)
        default: return .ambiguous
        }
    }

    /// The identities a signed-in web account could have as an OAuth row: one
    /// per organisation it belongs to. Built exactly as discovery builds a
    /// row's identity, so equal UUIDs give equal strings. Invalid UUIDs are
    /// dropped rather than hashed into an identity nothing could match.
    public static func webIdentities(accountUUID: String, organizationUUIDs: [String]) -> Set<String> {
        guard UUID(uuidString: accountUUID) != nil else { return [] }
        return Set(organizationUUIDs.filter { UUID(uuidString: $0) != nil }.map {
            ClaudeAccount.instanceID(identity: "account|\(accountUUID.lowercased())|\($0.lowercased())")
        })
    }

    /// What the page's `/api/account` read established.
    public enum WebAccountRead: Equatable, Sendable {
        case account(String)
        /// 401/403: the web session is no longer signed in.
        case signedOut
        /// Timed out, failed, or answered in a shape we do not recognise.
        case unknown
    }

    /// Decodes the session's `{status, account}` projection of `/api/account`.
    public static func webAccount(fromProjection text: String?) -> WebAccountRead {
        guard let data = text?.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = body["status"] as? Int else { return .unknown }
        if status == 401 || status == 403 { return .signedOut }
        guard (200..<300).contains(status), let account = body["account"] as? String,
              UUID(uuidString: account) != nil else { return .unknown }
        return .account(account)
    }

    /// The shown Claude account rows and their verified identities, as the
    /// last discovery stored them. Empty when Claude has no named rows.
    public static func storedRows(defaults: UserDefaults = CredentialStore.preferences) -> [Row] {
        ClaudeAccountDiscovery.storedCreditRows(defaults: defaults)
    }

    /// Settings' explanation of where the credit is drawn, or why it is not.
    public func explanation(accountName: (String) -> String?) -> String {
        switch self {
        case .bound(let id):
            return "Shown under \(accountName(id) ?? "the matching Claude account"), the account signed in here."
        case .webAccountUnknown:
            return "Not shown yet: the billing page has not said which Claude account is signed in."
        case .noMatchingAccount:
            return "Not shown: the account and organisation open on this billing page match none of the Claude accounts FrugalBar reads, so the credit has no row to belong to."
        case .ambiguous:
            return "Not shown: several Claude rows belong to the account signed in here, and the billing page does not say which organisation it shows."
        }
    }
}

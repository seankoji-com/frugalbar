import CryptoKit
import Foundation

/// A stable fingerprint of an identity a source published for a request.
///
/// A CLI may say which account or workspace a request billed through
/// (`creator_account_id` in a Codex rollout, `accountID`/`workspaceID` in an
/// OpenCode message). Those values name somebody's subscription, and the ledger
/// only ever needs to tell two of them apart — never to read one back. So what
/// reaches storage is a domain-separated SHA-256 of the exact published value:
///
///     fbfp1.<account|workspace>.<64 lowercase hex>
///
/// Same value in the same domain yields the same fingerprint, which is what
/// keeps attribution matching across a restart, a reopen and a re-ingestion.
/// The domain is part of the hashed preimage, so one string can never produce
/// the same stored value as an account and as a workspace. A different value
/// yields a different fingerprint, so two accounts of one provider, and two
/// workspaces of one account, never match each other.
///
/// This is a pseudonym, not encryption: there is no key, no keychain item and
/// no per-install secret, because a required credential to read one's own
/// history would be a worse trade than the pseudonym. The input is a
/// vendor-issued opaque id, never a password or an API key — no credential is
/// accepted by this type's only public constructor path.
public struct IdentityFingerprint: Sendable, Hashable, Equatable, CustomStringConvertible {

    /// Which published identity a fingerprint belongs to.
    public enum Domain: String, Sendable, Hashable, CaseIterable {
        case account
        case workspace
    }

    /// Version tag of the stored form. Part of the preimage, so a future change
    /// of scheme is a new namespace rather than a silent reinterpretation of
    /// existing rows.
    public static let scheme = "fbfp1"

    public let domain: Domain
    /// Lowercase hexadecimal SHA-256 digest.
    public let digest: String

    private init(domain: Domain, digest: String) {
        self.domain = domain
        self.digest = digest
    }

    /// The persisted form.
    public var stored: String { "\(Self.scheme).\(domain.rawValue).\(digest)" }

    public var description: String { stored }

    /// Fingerprints a value the source published.
    ///
    /// `nil` when the source published nothing: an absent, empty or
    /// whitespace-only value is an unpublished identity, and inventing one for
    /// it would attribute usage to an account the source never named. A value
    /// with content is hashed exactly as published — no trimming, no case
    /// folding — because the published id is opaque and normalising it would
    /// make two different identities compare equal.
    public static func published(_ value: String?, in domain: Domain) -> IdentityFingerprint? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return IdentityFingerprint(domain: domain, digest: digest(of: value, in: domain))
    }

    /// Reads back a stored fingerprint. Anything that is not a fingerprint of
    /// the expected domain is rejected: a stored value this type cannot parse
    /// is not an identity to match on, and reading it as one would either match
    /// a raw published id or silently compare an account against a workspace.
    public init?(stored: String, expecting domain: Domain) {
        let parts = stored.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == Substring(Self.scheme),
              parts[1] == Substring(domain.rawValue) else { return nil }
        let digest = String(parts[2])
        guard digest.count == 64,
              digest.allSatisfy(\.isHexDigit),
              digest == digest.lowercased() else { return nil }
        self.init(domain: domain, digest: digest)
    }

    /// The one place a published value is turned into a digest.
    ///
    /// `SHA256.hash` is the declassification boundary: the exact published value
    /// and the domain tag go in, and only the digest leaves. Nothing else about
    /// the value is retained — not its length, not a prefix, not its case.
    private static func digest(of value: String, in domain: Domain) -> String {
        let preimage = Data("\(scheme)\u{0}\(domain.rawValue)\u{0}\(value)".utf8)
        return SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
    }
}

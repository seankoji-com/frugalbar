import Foundation

/// The Google Desktop OAuth client the Mac signs in to Drive as.
///
/// Never committed. A release build has the values stamped into
/// `stampedClientID` / `stampedClientSecret` by `release.yml`, from Actions
/// secrets, the same way it stamps the version into `AppInfo`. A source build
/// reads `FRUGALBAR_GOOGLE_SYNC_CLIENT_ID` and
/// `FRUGALBAR_GOOGLE_SYNC_CLIENT_SECRET` from its environment. With neither,
/// there is no client: the sync setting is hidden and nothing ever contacts
/// Google.
public struct SyncClientConfiguration: Sendable, Equatable, CustomStringConvertible {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static let clientIDEnvironmentKey = "FRUGALBAR_GOOGLE_SYNC_CLIENT_ID"
    public static let clientSecretEnvironmentKey = "FRUGALBAR_GOOGLE_SYNC_CLIENT_SECRET"

    /// Substituted by the release workflow. Left intact, they mean "not
    /// stamped" and the environment is consulted instead.
    private static let stampedClientID = "__FRUGALBAR_SYNC_CLIENT_ID__"
    private static let stampedClientSecret = "__FRUGALBAR_SYNC_CLIENT_SECRET__"

    /// Placeholder sentinel, spelled without the marker so the workflow's
    /// substitution cannot rewrite the check along with the values.
    static let unstampedPrefix = "__"

    /// The stamped pair wins when both are stamped; otherwise both values must
    /// come from the environment. Half a client is no client.
    static func resolve(
        stampedID: String,
        stampedSecret: String,
        environment: [String: String]
    ) -> SyncClientConfiguration? {
        func usable(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, !trimmed.hasPrefix(unstampedPrefix)
            else { return nil }
            return trimmed
        }
        if let id = usable(stampedID), let secret = usable(stampedSecret) {
            return SyncClientConfiguration(clientID: id, clientSecret: secret)
        }
        if let id = usable(environment[clientIDEnvironmentKey]),
           let secret = usable(environment[clientSecretEnvironmentKey]) {
            return SyncClientConfiguration(clientID: id, clientSecret: secret)
        }
        return nil
    }

    /// This build's client, or nil when sync is unavailable.
    public static var current: SyncClientConfiguration? {
        resolve(
            stampedID: stampedClientID,
            stampedSecret: stampedClientSecret,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Never prints either value.
    public var description: String { "SyncClientConfiguration(redacted)" }
}

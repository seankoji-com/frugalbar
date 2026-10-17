import Foundation

/// The material part of a snapshot document (D§2.2.D): what, when it
/// changes, is worth publishing before the next heartbeat.
///
/// Material: the provider set and order, names and plan names, status kind
/// and reason, every window field, `tightestWindowId`, `primary`,
/// `apiCredits`, whether `lastPollFailure` is present and its reason, the
/// set of event ids, and `notificationPrefs`. Also `measuredAtTrusted` and
/// `providersOmitted`: a reading the phone must stop trusting, or a provider
/// that stopped fitting, should not wait for the heartbeat.
///
/// Not material: `measuredAt`, `lastAttemptAt`, `lastPollFailure.at`,
/// `publishedAt` and the clock sample. Event text is not material either;
/// only the set of ids is.
enum SyncMaterial {
    /// A canonical encoding of the material fields, or nil for a document
    /// that does not parse.
    static func key(_ document: Data) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else { return nil }
        let providers = (root["providers"] as? [[String: Any]] ?? []).map { provider -> [String: Any] in
            var material = provider
            material.removeValue(forKey: "measuredAt")
            material.removeValue(forKey: "lastAttemptAt")
            if var failure = material["lastPollFailure"] as? [String: Any] {
                failure.removeValue(forKey: "at")
                material["lastPollFailure"] = failure
            }
            return material
        }
        let eventIDs = (root["events"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
        let material: [String: Any] = [
            "providers": providers,
            "providersOmitted": root["providersOmitted"] ?? NSNull(),
            "eventIds": eventIDs,
            "notificationPrefs": root["notificationPrefs"] ?? NSNull(),
        ]
        return try? JSONSerialization.data(withJSONObject: material, options: [.sortedKeys])
    }
}

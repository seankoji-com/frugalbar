import Foundation

/// Identity the app can state about itself.
///
/// A release ships a bare executable renamed to `frugalbar`, not a `.app`, so
/// `Bundle.main` carries no name, version or icon — which is why the standard
/// About panel came up blank. Everything an About window needs lives here
/// instead of being read out of a bundle that does not exist.
public enum AppInfo {

    public static let name = "FrugalBar"

    public static let repositoryURL = URL(string: "https://github.com/seankoji-com/frugalbar")!
    public static let issuesURL = URL(string: "https://github.com/seankoji-com/frugalbar/issues")!

    public static let copyright = "© 2026 Sean Carey · MIT licence"

    public static let tagline = """
        Tracks how much headroom you have left across AI subscriptions, API \
        spend caps, and developer rate limits.
        """

    /// The one claim this app makes about itself that is worth repeating here:
    /// it is the reason several rows show a status instead of a percentage.
    public static let principle = """
        Never fabricates a quota. Where a vendor publishes no usage API, the \
        row says so rather than showing a number nobody measured.
        """

    /// Substituted by the release workflow, which is the only place that knows
    /// the tag being cut. Left intact, it means this is a local build — and a
    /// local build says so rather than claiming a version nobody released.
    private static let stampedVersion = "__VERSION__"

    /// Placeholder sentinel, spelled without the marker so the workflow's
    /// substitution cannot rewrite the check along with the value.
    static let unstampedPrefix = "__"

    static let developmentLabel = "development build"

    /// The stamp wins when present: it is the tag actually released. A bundle's
    /// version is only consulted if this is ever packaged as a real `.app`,
    /// which no current build path does.
    static func resolveVersion(stamped: String, bundleShortVersion: String?) -> String {
        if !stamped.hasPrefix(unstampedPrefix) { return stamped }
        if let short = bundleShortVersion, !short.isEmpty { return short }
        return developmentLabel
    }

    /// "Version 1.4.2", but never "Version development build" — that reads as
    /// a bug in the About window rather than as an honest label.
    static func versionDisplay(for resolved: String) -> String {
        resolved == developmentLabel ? resolved : "Version \(resolved)"
    }

    public static var version: String {
        resolveVersion(
            stamped: stampedVersion,
            bundleShortVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

    public static var versionDisplay: String { versionDisplay(for: version) }
}

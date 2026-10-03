import Testing
import Foundation
@testable import QuotaBarCore

/// The About window states the app's identity, and a release ships a bare
/// executable — so none of this can be read back out of `Bundle.main`.
@Suite("AppInfo")
struct AppInfoTests {

    @Test("a stamped build reports the tag the workflow cut")
    func stampedWins() {
        #expect(AppInfo.resolveVersion(stamped: "1.4.2", bundleShortVersion: nil) == "1.4.2")
        // Even against a bundle: the stamp is the version actually released.
        #expect(AppInfo.resolveVersion(stamped: "1.4.2", bundleShortVersion: "9.9.9") == "1.4.2")
    }

    @Test("an unstamped build says so rather than showing the placeholder")
    func unstampedIsLabelled() {
        // The failure this guards: shipping "__VERSION__" to a user's screen.
        let resolved = AppInfo.resolveVersion(stamped: "__VERSION__", bundleShortVersion: nil)
        #expect(resolved == AppInfo.developmentLabel)
        #expect(!resolved.contains("__"))
    }

    @Test("a bundle version is the fallback when nothing was stamped")
    func bundleIsFallback() {
        #expect(AppInfo.resolveVersion(stamped: "__VERSION__", bundleShortVersion: "2.0.1") == "2.0.1")
        #expect(AppInfo.resolveVersion(stamped: "__VERSION__", bundleShortVersion: "") == AppInfo.developmentLabel)
    }

    @Test("a real version is prefixed, a development build is not")
    func displayFormatting() {
        #expect(AppInfo.versionDisplay(for: "1.4.2") == "Version 1.4.2")
        // "Version development build" reads as a bug, not as a label.
        #expect(AppInfo.versionDisplay(for: AppInfo.developmentLabel) == AppInfo.developmentLabel)
    }

    @Test("this build never shows the raw placeholder")
    func liveValueIsPresentable() {
        #expect(!AppInfo.version.contains("__VERSION__"))
        #expect(!AppInfo.versionDisplay.isEmpty)
    }

    @Test("the app states its own name, not the executable's")
    func identity() {
        // The binary is `frugalbar` and the SPM product is `QuotaBar`; neither
        // is what the About window should call the app.
        #expect(AppInfo.name == "FrugalBar")
        #expect(AppInfo.repositoryURL.host == "github.com")
        #expect(AppInfo.issuesURL.absoluteString.hasSuffix("/issues"))
        #expect(AppInfo.releasesURL.absoluteString.hasSuffix("/releases"))
    }

    // MARK: Footer token

    @Test("the footer token is a 'v' prefix for a release and 'dev' for a local build")
    func compactVersion() {
        #expect(AppInfo.compactVersion(for: "1.4.2") == "v1.4.2")
        // "vdevelopment build" would read as a bug in the footer.
        #expect(AppInfo.compactVersion(for: AppInfo.developmentLabel) == "dev")
        #expect(!AppInfo.compactVersion.contains("__"))
        #expect(!AppInfo.compactVersion.contains(" "))
    }

    // MARK: User agent

    @Test("the user agent names the app and the running version")
    func userAgentNamesAppAndVersion() {
        #expect(AppInfo.userAgent(for: "1.4.2") == "FrugalBar/1.4.2")
        #expect(AppInfo.userAgent(for: AppInfo.developmentLabel) == "FrugalBar/dev")
    }

    /// An HTTP product token cannot carry whitespace; a spaced label on the
    /// wire would be two tokens, the second of them meaningless.
    @Test("the user agent never contains whitespace or the placeholder")
    func userAgentIsOneToken() {
        #expect(AppInfo.userAgent(for: "1.4.2 beta") == "FrugalBar/1.4.2-beta")
        #expect(AppInfo.userAgent(for: "   ") == "FrugalBar/dev")
        let live = AppInfo.userAgent
        #expect(live.hasPrefix("FrugalBar/"))
        #expect(live.rangeOfCharacter(from: .whitespacesAndNewlines) == nil)
        #expect(!live.contains("__"))
    }
}

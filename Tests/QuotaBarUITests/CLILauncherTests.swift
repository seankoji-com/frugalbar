import Testing
import Foundation
import QuotaBarCore
@testable import QuotaBarUI

@Suite("CLILauncher")
struct CLILauncherTests {

    @Test("each vendor maps to the agent you would actually open for it", arguments: [
        (VendorIdentifier.claude, "claude"),
        (.gemini, "agy"),
        (.openai, "codex"),
        (.opencode, "opencode"),
        // No first-party terminal agent; OpenCode drives both as a backend.
        (.copilot, "opencode"),
        (.openrouter, "opencode"),
    ])
    func vendorCommands(vendor: VendorIdentifier, expected: String) {
        #expect(CLILauncher.command(for: vendor) == expected)
    }

    @Test("GitHub API limits open nothing — they are telemetry, not a tool")
    func githubHasNoCommand() {
        #expect(CLILauncher.command(for: .githubRest) == nil)
        #expect(CLILauncher.command(for: .githubGraphql) == nil)
    }

    @Test("the window survives the agent exiting")
    func scriptKeepsTheWindowOpen() {
        let script = CLILauncher.shellScript(command: "claude", shell: "/bin/zsh")
        #expect(script == "claude; exec /bin/zsh -l")
    }

    @Test("the login shell is honoured so Homebrew is on PATH")
    func loginShellComesFromTheEnvironment() {
        // FrugalBar is a GUI app: launchd hands it a PATH without /opt/homebrew,
        // so the command has to be resolved by a login shell, not by us.
        let shell = CLILauncher.loginShell
        #expect(shell.hasPrefix("/"))
        #expect(!shell.isEmpty)
    }

    @Test("quoting closes and reopens around an embedded single quote")
    func quotingHandlesApostrophes() {
        #expect(CLILauncher.shellQuoted("plain") == "'plain'")
        #expect(CLILauncher.shellQuoted("it's") == "'it'\\''s'")
    }
}


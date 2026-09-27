import Foundation
import Testing
@testable import QuotaBarCore

/// The default transcript directories must follow the CLIs' own overrides,
/// or a user with a relocated config sees no activity history at all.
@Suite("Activity directory resolution")
struct ActivityDirectoryTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test("Claude honours CLAUDE_CONFIG_DIR over both default locations")
    func claudeConfigDirWins() {
        let url = ClaudeCodeAdapter.defaultProjectsDirectory(
            environment: ["CLAUDE_CONFIG_DIR": "/opt/claude-config"], home: home, fileExists: { _ in true }
        )
        #expect(url.path == "/opt/claude-config/projects")
    }

    @Test("Claude prefers ~/.config/claude when it has a projects directory")
    func claudeXDGWhenPresent() {
        let url = ClaudeCodeAdapter.defaultProjectsDirectory(
            environment: [:], home: home, fileExists: { $0.path == "/Users/tester/.config/claude/projects" }
        )
        #expect(url.path == "/Users/tester/.config/claude/projects")
    }

    @Test("Claude falls back to ~/.claude, ignoring an empty CLAUDE_CONFIG_DIR")
    func claudeLegacyFallback() {
        let url = ClaudeCodeAdapter.defaultProjectsDirectory(
            environment: ["CLAUDE_CONFIG_DIR": " "], home: home, fileExists: { _ in false }
        )
        #expect(url.path == "/Users/tester/.claude/projects")
    }

    @Test("Codex honours CODEX_HOME")
    func codexHome() {
        let url = CodexAdapter.defaultSessionsDirectory(
            environment: ["CODEX_HOME": "/opt/codex"], home: home, fileExists: { _ in true }
        )
        #expect(url.path == "/opt/codex/sessions")
    }

    @Test("Codex defaults to ~/.codex")
    func codexDefault() {
        let url = CodexAdapter.defaultSessionsDirectory(environment: [:], home: home, fileExists: { _ in true })
        #expect(url.path == "/Users/tester/.codex/sessions")
    }

    /// A stale override must not hide the transcripts at the default
    /// location: it falls through when it has no `projects` directory.
    @Test("Claude falls through a CLAUDE_CONFIG_DIR with no projects directory")
    func claudeStaleConfigDirFallsThrough() {
        let url = ClaudeCodeAdapter.defaultProjectsDirectory(
            environment: ["CLAUDE_CONFIG_DIR": "/opt/empty"], home: home,
            fileExists: { $0.path == "/Users/tester/.config/claude/projects" }
        )
        #expect(url.path == "/Users/tester/.config/claude/projects")

        let legacy = ClaudeCodeAdapter.defaultProjectsDirectory(
            environment: ["CLAUDE_CONFIG_DIR": "/opt/empty"], home: home, fileExists: { _ in false }
        )
        #expect(legacy.path == "/Users/tester/.claude/projects")
    }

    @Test("Codex falls back to ~/.codex when CODEX_HOME has no sessions directory")
    func codexStaleHomeFallsThrough() {
        let url = CodexAdapter.defaultSessionsDirectory(
            environment: ["CODEX_HOME": "/opt/empty"], home: home, fileExists: { _ in false }
        )
        #expect(url.path == "/Users/tester/.codex/sessions")
    }

    /// `~` and relative values resolve against the injected home, never the
    /// process's real home or its working directory (`/` from Finder).
    @Test("Overrides resolve ~ and relative paths against the injected home")
    func overridesResolveAgainstInjectedHome() {
        let exists: (URL) -> Bool = { $0.path.hasPrefix("/Users/tester/") }
        #expect(ClaudeCodeAdapter.defaultProjectsDirectory(
            environment: ["CLAUDE_CONFIG_DIR": "~/claude-config"], home: home, fileExists: exists
        ).path == "/Users/tester/claude-config/projects")
        #expect(ClaudeCodeAdapter.defaultProjectsDirectory(
            environment: ["CLAUDE_CONFIG_DIR": "claude-config"], home: home, fileExists: exists
        ).path == "/Users/tester/claude-config/projects")
        #expect(CodexAdapter.defaultSessionsDirectory(
            environment: ["CODEX_HOME": "~/codex"], home: home, fileExists: exists
        ).path == "/Users/tester/codex/sessions")
        #expect(CodexAdapter.defaultSessionsDirectory(
            environment: ["CODEX_HOME": "codex"], home: home, fileExists: exists
        ).path == "/Users/tester/codex/sessions")
        #expect(CLIConfigLocations.resolve("~", home: home).path == "/Users/tester")
        #expect(CLIConfigLocations.resolve("/abs/dir", home: home).path == "/abs/dir")
    }

    /// Credential discovery uses the same resolver, probing for the credential
    /// file rather than the transcript directory.
    @Test("Credential lookups honour the overrides and probe for their own file")
    func credentialLookupsShareTheResolver() {
        let claude = CLIConfigLocations.claudeRoot(
            containing: ".credentials.json", environment: ["CLAUDE_CONFIG_DIR": "/opt/claude"], home: home,
            fileExists: { $0.path == "/opt/claude/.credentials.json" }
        )
        #expect(claude.path == "/opt/claude")
        let codex = CLIConfigLocations.codexRoot(
            containing: "auth.json", environment: ["CODEX_HOME": "/opt/codex"], home: home,
            fileExists: { $0.path == "/opt/codex/auth.json" }
        )
        #expect(codex.path == "/opt/codex")
        let codexDefault = CLIConfigLocations.codexRoot(
            containing: "auth.json", environment: ["CODEX_HOME": "/opt/codex"], home: home,
            fileExists: { _ in false }
        )
        #expect(codexDefault.path == "/Users/tester/.codex")
    }
}

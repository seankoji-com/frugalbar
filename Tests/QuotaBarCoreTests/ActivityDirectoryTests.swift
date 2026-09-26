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
        let url = CodexAdapter.defaultSessionsDirectory(environment: ["CODEX_HOME": "/opt/codex"], home: home)
        #expect(url.path == "/opt/codex/sessions")
    }

    @Test("Codex defaults to ~/.codex")
    func codexDefault() {
        let url = CodexAdapter.defaultSessionsDirectory(environment: [:], home: home)
        #expect(url.path == "/Users/tester/.codex/sessions")
    }
}

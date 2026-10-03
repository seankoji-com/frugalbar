import Foundation

/// Where the Claude Code and Codex CLIs keep their state, honouring their own
/// relocation variables (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
///
/// Activity ingestion and credential discovery both resolve through here, so
/// they cannot disagree about which directory a relocated CLI is using.
///
/// Every candidate is probed for the file or directory the caller actually
/// needs (`containing`), and a candidate without it is skipped. A stale
/// override — a variable left pointing at an empty or half-migrated directory
/// — then falls back to the default location instead of hiding everything.
///
/// An app launched from Finder or at login does not inherit shell variables,
/// so the overrides only apply when FrugalBar is started from a shell.
enum CLIConfigLocations {
    typealias FileExists = (URL) -> Bool

    /// Claude Code's config root: `$CLAUDE_CONFIG_DIR`, then
    /// `~/.config/claude` (newer installs), then the legacy `~/.claude`, which
    /// is returned even when absent as the final default.
    static func claudeRoot(
        containing probe: String,
        environment: [String: String],
        home: URL,
        fileExists: FileExists
    ) -> URL {
        let configured = override("CLAUDE_CONFIG_DIR", environment: environment, home: home)
        let candidates = [configured, home.appendingPathComponent(".config/claude", isDirectory: true)]
            .compactMap { $0 }
        let root = candidates.first { fileExists($0.appendingPathComponent(probe)) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        if let configured, root != configured { logSkipped("CLAUDE_CONFIG_DIR", probe, root) }
        return root
    }

    /// Codex's home: `$CODEX_HOME` when it holds `probe`, else `~/.codex`.
    static func codexRoot(
        containing probe: String,
        environment: [String: String],
        home: URL,
        fileExists: FileExists
    ) -> URL {
        let fallback = home.appendingPathComponent(".codex", isDirectory: true)
        guard let configured = override("CODEX_HOME", environment: environment, home: home) else { return fallback }
        if fileExists(configured.appendingPathComponent(probe)) { return configured }
        logSkipped("CODEX_HOME", probe, fallback)
        return fallback
    }

    /// The Cline CLI/SDK data directory: `$CLINE_DATA_DIR`, then
    /// `$CLINE_DIR/data`, when either holds `probe`; else `~/.cline/data`.
    /// Mirrors `resolveClineDataDir()` in cline's
    /// `sdk/packages/shared/src/storage/paths.ts`.
    static func clineDataRoot(
        containing probe: String,
        environment: [String: String],
        home: URL,
        fileExists: FileExists
    ) -> URL {
        let fallback = home.appendingPathComponent(".cline/data", isDirectory: true)
        let candidates = [
            override("CLINE_DATA_DIR", environment: environment, home: home),
            override("CLINE_DIR", environment: environment, home: home)?
                .appendingPathComponent("data", isDirectory: true),
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return fallback }
        if let root = candidates.first(where: { fileExists($0.appendingPathComponent(probe)) }) {
            return root
        }
        logSkipped("CLINE_DATA_DIR or CLINE_DIR", probe, fallback)
        return fallback
    }

    /// The same lookups against this process's environment and filesystem.
    static func liveClaudeRoot(containing probe: String) -> URL {
        claudeRoot(containing: probe, environment: ProcessInfo.processInfo.environment,
                   home: liveHome, fileExists: liveFileExists)
    }

    static func liveCodexRoot(containing probe: String) -> URL {
        codexRoot(containing: probe, environment: ProcessInfo.processInfo.environment,
                  home: liveHome, fileExists: liveFileExists)
    }

    /// Resolves an override value against `home`, never against the process:
    /// `~` and `~/…` expand to `home`, and a relative path is anchored at
    /// `home` rather than at the working directory, which is `/` for an app
    /// launched from Finder or at login. `~user/…` names another account's
    /// home and is left to Foundation.
    static func resolve(_ value: String, home: URL) -> URL {
        if value == "~" { return home }
        if value.hasPrefix("~/") {
            return home.appendingPathComponent(String(value.dropFirst(2)), isDirectory: true)
        }
        if value.hasPrefix("~") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
        return home.appendingPathComponent(value, isDirectory: true)
    }

    private static func override(_ name: String, environment: [String: String], home: URL) -> URL? {
        guard let raw = environment[name]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return resolve(raw, home: home)
    }

    /// A set-but-unusable override is otherwise invisible: the user sees the
    /// default location's data (or none) with no hint why.
    private static func logSkipped(_ name: String, _ probe: String, _ chosen: URL) {
        NSLog("frugalbar: %@ has no %@; using %@", name, probe, chosen.path)
    }

    static func liveClineDataRoot(containing probe: String) -> URL {
        clineDataRoot(containing: probe, environment: ProcessInfo.processInfo.environment,
                      home: liveHome, fileExists: liveFileExists)
    }

    private static var liveHome: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static func liveFileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

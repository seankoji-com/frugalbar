import Foundation
import AppKit
import QuotaBarCore

/// Opens the coding agent the advice card is recommending.
///
/// FrugalBar is a GUI app, so its `PATH` is whatever `launchd` handed it —
/// `/usr/bin:/bin:/usr/sbin:/sbin`, with no Homebrew on it. Every command below
/// lives in `/opt/homebrew/bin`, so the launch goes through a login shell and
/// lets that shell resolve the name, rather than hardcoding an install prefix
/// that is wrong on Intel Macs and wrong again for anyone using MacPorts.
public enum CLILauncher {

    /// The agent to reach for per vendor.
    ///
    /// Copilot and OpenRouter have no first-party terminal agent of their own,
    /// so both route through OpenCode, which can drive either as a backend.
    /// nil means there is nothing to launch — the GitHub API limits are
    /// telemetry about a service, not a tool you open.
    public static func command(for vendor: VendorIdentifier) -> String? {
        switch vendor {
        case .claude:                       "claude"
        case .gemini:                       "agy"
        case .openai:                       "codex"
        case .opencode:                     "opencode"
        case .copilot:                      "opencode"
        case .openrouter:                   "opencode"
        case .githubRest, .githubGraphql:   nil
        }
    }

    /// What the terminal is asked to run.
    ///
    /// The trailing `exec` replaces the shell with a fresh login shell when the
    /// agent exits, so the window stays open on whatever it printed on the way
    /// out. Without it a crashed CLI closes its own window before it can be
    /// read.
    static func shellScript(command: String, shell: String) -> String {
        "\(command); exec \(shell) -l"
    }

    static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static let weztermBundleID = "com.github.wez.wezterm"

    /// Launches the agent for `vendor`. Silently does nothing when that vendor
    /// has no agent to launch.
    @MainActor
    public static func launch(for vendor: VendorIdentifier) {
        guard let command = command(for: vendor) else { return }
        launch(command: command)
    }

    @MainActor
    public static func launch(command: String) {
        let shell = loginShell
        let script = shellScript(command: command, shell: shell)

        if let wezterm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: weztermBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            // A new instance every time, so clicking the button while WezTerm
            // is already open still produces a window rather than just
            // focusing the existing one.
            config.createsNewApplicationInstance = true
            config.arguments = ["start", "--", shell, "-lc", script]
            NSWorkspace.shared.openApplication(at: wezterm, configuration: config)
            return
        }

        openInTerminal(script: script, shell: shell)
    }

    /// Fallback for a machine without WezTerm. Terminal.app takes no command
    /// argument, but it does run an executable `.command` file that is opened
    /// with it, so the script goes to disk first.
    @MainActor
    private static func openInTerminal(script: String, shell: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("frugalbar-launch-\(UUID().uuidString).command")
        let contents = "#!/bin/sh\nexec \(shell) -lc \(shellQuoted(script))\n"

        do {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path
            )
        } catch {
            return
        }

        NSWorkspace.shared.open(
            [file], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Single-quote for `sh`, closing and reopening around any embedded quote.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

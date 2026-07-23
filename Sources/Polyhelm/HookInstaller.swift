import AppKit
import Foundation

/// Wires Polyhelm into Claude Code by installing a forwarding hook script and
/// registering it in `~/.claude/settings.json`.
///
/// This edits a file the user owns, so it never runs unprompted: the UI asks
/// first, and the previous settings are copied aside before any write.
enum HookInstaller {
    static var supportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".polyhelm")
    }
    static var scriptURL: URL { supportDirectory.appendingPathComponent("hook.sh") }
    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }

    /// Events forwarded fire-and-forget, purely to track session state.
    private static let lifecycleEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "Notification", "Stop", "SubagentStop", "SessionEnd"
    ]

    /// True when our hook entries are already present in settings.json.
    @MainActor
    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = parsed["hooks"] as? [String: Any]
        else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("polyhelm") == true
                }
            }
        }
    }

    @MainActor
    static func presentInstall() {
        let approvals = Settings.shared.notchApprovals
        let alert = NSAlert()
        alert.messageText = isInstalled ? "Update Claude Code hooks?" : "Install Claude Code hooks?"
        alert.informativeText = """
        Polyhelm will:

        • write \(scriptURL.path)
        • add hook entries to \(settingsURL.path)

        Your current settings.json is backed up alongside it first.

        Notch approvals are currently \(approvals ? "ON" : "OFF")\
        \(approvals ? " — tool calls will block in the terminal until you decide here." : ".") \
        Toggle it from the menu bar and the hooks rewrite themselves.
        """
        alert.addButton(withTitle: isInstalled ? "Update" : "Install")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(showingSuccess: true)
    }

    /// Rewrites the hook entries to match current settings. Silent by default so
    /// flipping the approvals toggle doesn't throw a dialog every time.
    @MainActor
    static func apply(showingSuccess: Bool = false) {
        do {
            try install(routeApprovals: Settings.shared.notchApprovals)
            guard showingSuccess else { return }
            let done = NSAlert()
            done.messageText = "Hooks installed"
            done.informativeText = "Start a new Claude Code session — it will appear in the notch."
            done.runModal()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not write hooks"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .critical
            failure.runModal()
        }
    }

    /// Strips every Polyhelm entry back out, leaving the rest of settings.json alone.
    @MainActor
    static func presentUninstall() {
        let alert = NSAlert()
        alert.messageText = "Remove Polyhelm hooks?"
        alert.informativeText = """
        Every Polyhelm entry is removed from \(settingsURL.path). \
        Your other hooks and settings are left untouched, and a backup is written first.
        """
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? removeFromSettings()
    }

    static func install(routeApprovals: Bool) throws {
        try FileManager.default.createDirectory(at: supportDirectory,
                                                withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: scriptURL.path)
        try mergeSettings(routeApprovals: routeApprovals)
    }

    private static func mergeSettings(routeApprovals: Bool) throws {
        var settings = try loadWithBackup()
        var hooks = stripOurEntries(from: settings["hooks"] as? [String: Any] ?? [:])

        for event in lifecycleEvents {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            var entry: [String: Any] = [
                "hooks": [["type": "command",
                           "command": "\(scriptURL.path) event",
                           "timeout": 5]]
            ]
            // Only tool events are matcher-scoped; the rest reject the key.
            if event == "PreToolUse" { entry["matcher"] = "*" }
            matchers.append(entry)
            hooks[event] = matchers
        }

        if routeApprovals {
            var matchers = hooks["PreToolUse"] as? [[String: Any]] ?? []
            matchers.append([
                "matcher": "*",
                "hooks": [["type": "command",
                           "command": "\(scriptURL.path) permission",
                           "timeout": 60]]
            ])
            hooks["PreToolUse"] = matchers
        }

        settings["hooks"] = hooks
        try write(settings)
    }

    private static func removeFromSettings() throws {
        var settings = try loadWithBackup()
        var hooks = stripOurEntries(from: settings["hooks"] as? [String: Any] ?? [:])
        // Drop events left with no hooks at all rather than leaving empty arrays.
        for (event, value) in hooks where (value as? [[String: Any]])?.isEmpty ?? false {
            hooks.removeValue(forKey: event)
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try write(settings)
    }

    /// Reads settings.json, writing a timestamped backup of whatever was there.
    private static func loadWithBackup() throws -> [String: Any] {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: settingsURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.polyhelm-backup-\(stamp).json")
        try? data.write(to: backup)
        return parsed
    }

    /// Removes every hook entry pointing at our script, leaving the user's alone.
    private static func stripOurEntries(from hooks: [String: Any]) -> [String: Any] {
        var hooks = hooks
        for (event, value) in hooks {
            guard var matchers = value as? [[String: Any]] else { continue }
            matchers.removeAll { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("polyhelm") == true
                }
            }
            hooks[event] = matchers
        }
        return hooks
    }

    private static func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// The forwarding script. Kept dependency-light: jq ships with macOS, and the
    /// script fails open — if Polyhelm is not running, curl fails and Claude Code
    /// continues exactly as it would without hooks.
    private static let script = """
    #!/bin/bash
    # Polyhelm hook — forwards Claude Code events to the notch UI.
    # Usage: hook.sh event | hook.sh permission
    # Fails open: any error here must never block or break a Claude Code session.

    set -o pipefail
    MODE="${1:-event}"
    PORT=\(AppInfo.port)
    ENDPOINT="http://127.0.0.1:$PORT"

    payload=$(cat)
    [ -z "$payload" ] && exit 0

    command -v jq >/dev/null 2>&1 || exit 0

    # stdin is the payload, so `tty` can't help. Ask ps for our own controlling
    # terminal — it is inherited from Claude Code, so it names the right tab.
    # Falls back to the parent's. "s004" becomes "/dev/ttys004";
    # "??" (no controlling tty, e.g. the Claude Code desktop app) becomes empty.
    tty_name=$(ps -o tty= -p "$$" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$tty_name" ] || [ "$tty_name" = "??" ]; then
      tty_name=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -n "$tty_name" ] && [ "$tty_name" != "??" ]; then
      case "$tty_name" in
        /dev/*) TTY_PATH="$tty_name" ;;
        tty*)   TTY_PATH="/dev/$tty_name" ;;
        *)      TTY_PATH="/dev/tty$tty_name" ;;
      esac
    else
      TTY_PATH=""
    fi

    env_json=$(jq -n \\
      --arg TERM_PROGRAM "${TERM_PROGRAM:-}" \\
      --arg ITERM_SESSION_ID "${ITERM_SESSION_ID:-}" \\
      --arg TERM_SESSION_ID "${TERM_SESSION_ID:-}" \\
      --arg WEZTERM_PANE "${WEZTERM_PANE:-}" \\
      --arg KITTY_WINDOW_ID "${KITTY_WINDOW_ID:-}" \\
      --arg TMUX_PANE "${TMUX_PANE:-}" \\
      --arg TMUX "${TMUX:-}" \\
      --arg TTY "$TTY_PATH" \\
      --arg PPID "${PPID:-}" \\
      --arg AGENT "${POLYHELM_AGENT:-Claude Code}" \\
      '$ARGS.named')

    body=$(printf '%s' "$payload" | jq -c --argjson e "$env_json" '. + {_env: $e}' 2>/dev/null)
    [ -z "$body" ] && exit 0

    if [ "$MODE" = "permission" ]; then
      # Blocks until the user decides in the notch, or the app times out and
      # returns an empty object — which hands the prompt back to the terminal.
      response=$(printf '%s' "$body" \\
        | curl -sS -m 58 -X POST "$ENDPOINT/permission" \\
               -H 'Content-Type: application/json' --data-binary @- 2>/dev/null)
      if [ -n "$response" ]; then
        printf '%s' "$response"
      fi
      exit 0
    fi

    printf '%s' "$body" \\
      | curl -sS -m 2 -X POST "$ENDPOINT/event" \\
             -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1
    exit 0
    """
}

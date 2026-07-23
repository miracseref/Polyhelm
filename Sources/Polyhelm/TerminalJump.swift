import AppKit
import Foundation

/// Focuses the exact terminal surface a session is running in.
///
/// Strategy per emulator, best-effort and always with a fallback to simply
/// activating the app — a wrong-tab focus still beats no focus at all.
enum TerminalJump {
    static func focus(_ terminal: TerminalRef?) {
        guard let terminal else { return }

        // A GUI-app session (Conductor) has no terminal surface — the most we can
        // do, and it is genuinely useful, is bring its app to the front.
        if let bundleID = terminal.desktopApp, !terminal.canType {
            activate(bundleID: bundleID)
            return
        }

        // Inside tmux the pane switch is what actually matters; do it first so
        // the correct pane is already selected when the window comes forward.
        if let pane = terminal.tmuxPane {
            shell("/usr/bin/env", ["tmux", "switch-client", "-t", pane])
            shell("/usr/bin/env", ["tmux", "select-pane", "-t", pane])
        }

        switch (terminal.app ?? "").lowercased() {
        case let app where app.contains("iterm"):
            focusITerm(terminal)
        case let app where app.contains("apple_terminal"):
            focusAppleTerminal(terminal)
        case let app where app.contains("wezterm"):
            if let pane = terminal.weztermPane {
                shell("/usr/bin/env", ["wezterm", "cli", "activate-pane", "--pane-id", pane])
            }
            activate(bundleFragment: "wezterm")
        case let app where app.contains("ghostty"):
            activate(bundleFragment: "ghostty")
        case let app where app.contains("warp"):
            activate(bundleFragment: "warp")
        case let app where app.contains("kitty"):
            if let window = terminal.kittyWindow {
                shell("/usr/bin/env", ["kitty", "@", "focus-window", "--match", "id:\(window)"])
            }
            activate(bundleFragment: "kitty")
        case let app where app.contains("alacritty"):
            activate(bundleFragment: "alacritty")
        case let app where app.contains("hyper"):
            activate(bundleFragment: "hyper")
        case let app where app.contains("vscode"):
            activate(bundleFragment: "code")
        case let app where app.contains("zed"):
            activate(bundleFragment: "zed")
        default:
            // Unknown emulator — front whatever owns the process if we know it.
            if let pid = terminal.pid,
               let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
            }
        }
    }

    // MARK: - Sending text

    /// Types `message` into the session's terminal and presses return.
    ///
    /// There is no back channel into a running Claude Code process, so this drives
    /// the terminal exactly as a human would. Every path below passes the text as
    /// a single escaped argument — it is never concatenated into a shell command,
    /// so characters like `;` and backticks are typed, not executed.
    static func send(_ message: String, to terminal: TerminalRef) {
        guard terminal.isAddressable else { return }

        // tmux owns the keyboard inside a pane, so it wins over the host emulator.
        if let pane = terminal.tmuxPane {
            // `--` stops send-keys reading the message as flags; the literal text
            // and the Enter key are separate arguments.
            shell("/usr/bin/env", ["tmux", "send-keys", "-t", pane, "--", message])
            shell("/usr/bin/env", ["tmux", "send-keys", "-t", pane, "Enter"])
            focus(terminal)
            return
        }

        switch (terminal.app ?? "").lowercased() {
        case let app where app.contains("iterm"):
            sendITerm(message, terminal)
        case let app where app.contains("apple_terminal"):
            sendAppleTerminal(message, terminal)
        case let app where app.contains("wezterm"):
            if let pane = terminal.weztermPane {
                shell("/usr/bin/env", ["wezterm", "cli", "send-text", "--pane-id", pane,
                                       "--no-paste", message + "\n"])
            }
            focus(terminal)
        case let app where app.contains("kitty"):
            if let window = terminal.kittyWindow {
                shell("/usr/bin/env", ["kitty", "@", "send-text",
                                       "--match", "id:\(window)", message + "\n"])
            }
            focus(terminal)
        default:
            // No scripting interface we can rely on — put the user in front of the
            // session with the text on the clipboard so it is one paste away.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
            focus(terminal)
        }
    }

    private static func sendITerm(_ message: String, _ terminal: TerminalRef) {
        let predicate = itermPredicate(terminal)
        guard !predicate.isEmpty else { return }
        runAppleScript("""
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if \(predicate) then
                    select w
                    select t
                    select s
                    tell s to write text "\(escape(message))"
                    return
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        """)
    }

    private static func sendAppleTerminal(_ message: String, _ terminal: TerminalRef) {
        guard let tty = terminal.tty else { return }
        // `do script … in tab` types into that tab rather than opening a window.
        runAppleScript("""
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) as string is "\(escape(tty))" then
                  set selected tab of w to t
                  set index of w to 1
                  do script "\(escape(message))" in t
                  return
                end if
              end try
            end repeat
          end repeat
        end tell
        """)
    }

    // MARK: - Emulator specifics

    /// Matches on `tty` first — it survives iTerm restoring a session with a new
    /// id — then falls back to the UUID half of `ITERM_SESSION_ID` (`w0t2p1:UUID`).
    private static func focusITerm(_ terminal: TerminalRef) {
        guard !itermPredicate(terminal).isEmpty else {
            activate(bundleFragment: "iterm"); return
        }

        let script = """
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if \(itermPredicate(terminal)) then
                    select w
                    select t
                    select s
                    return
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        """
        runAppleScript(script)
    }

    /// Terminal.app tabs expose their `tty`, so match on the device path the
    /// session actually runs on. (`TERM_SESSION_ID` has no addressable equivalent
    /// in Terminal's AppleScript dictionary — matching on it never worked.)
    private static func focusAppleTerminal(_ terminal: TerminalRef) {
        guard let tty = terminal.tty else {
            activate(bundleFragment: "terminal"); return
        }
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) as string is "\(escape(tty))" then
                  set selected tab of w to t
                  set index of w to 1
                  return
                end if
              end try
            end repeat
          end repeat
        end tell
        """
        runAppleScript(script)
    }

    /// Matches an iTerm session by tty first — it survives iTerm restoring a
    /// session with a new id — then by the UUID half of `ITERM_SESSION_ID`.
    private static func itermPredicate(_ terminal: TerminalRef) -> String {
        var tests: [String] = []
        if let tty = terminal.tty {
            tests.append("(tty of s) as string is \"\(escape(tty))\"")
        }
        if let raw = terminal.itermSession {
            let uuid = raw.contains(":") ? String(raw.split(separator: ":").last!) : raw
            tests.append("(id of s) contains \"\(escape(uuid))\"")
        }
        return tests.joined(separator: " or ")
    }

    /// AppleScript string literals only need quotes and backslashes escaped.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Primitives

    private static func activate(bundleFragment: String) {
        let match = NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier ?? "").lowercased().contains(bundleFragment)
                || ($0.localizedName ?? "").lowercased().contains(bundleFragment)
        }
        match?.activate(options: [.activateAllWindows])
    }

    /// Fronts an app by exact bundle id, launching it if it isn't running.
    private static func activate(bundleID: String) {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("Polyhelm: AppleScript failed — \(error)") }
        }
    }

    @discardableResult
    private static func shell(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }
}

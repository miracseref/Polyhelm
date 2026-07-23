import Foundation
import SwiftUI

/// Lifecycle state of a single agent session, derived from the hook events it emits.
enum SessionState: String {
    case working
    case needsInput
    case idle
    case done
    case error

    var tint: Color {
        switch self {
        case .working:   return Color(red: 0.35, green: 0.72, blue: 1.00)
        case .needsInput: return Color(red: 1.00, green: 0.75, blue: 0.20)
        case .idle:      return Color(white: 0.55)
        case .done:      return Color(red: 0.35, green: 0.86, blue: 0.53)
        case .error:     return Color(red: 1.00, green: 0.38, blue: 0.38)
        }
    }

    var label: String {
        switch self {
        case .working:    return "Working"
        case .needsInput: return "Needs you"
        case .idle:       return "Idle"
        case .done:       return "Done"
        case .error:      return "Error"
        }
    }

    /// Sessions the user has to act on sort to the top and drive the collapsed pill.
    var urgency: Int {
        switch self {
        case .needsInput: return 0
        case .error:      return 1
        case .working:    return 2
        case .done:       return 3
        case .idle:       return 4
        }
    }
}

/// Where a session is running, captured from the hook process environment so we can
/// focus the exact tab / split / tmux pane it lives in.
struct TerminalRef: Equatable {
    var app: String?          // TERM_PROGRAM, e.g. "iTerm.app", "ghostty", "Apple_Terminal"
    var itermSession: String? // ITERM_SESSION_ID
    var termSession: String?  // TERM_SESSION_ID (Terminal.app)
    var weztermPane: String?  // WEZTERM_PANE
    var kittyWindow: String?  // KITTY_WINDOW_ID
    var tmuxPane: String?     // TMUX_PANE
    var tmuxSocket: String?   // TMUX
    /// Controlling terminal device, e.g. `/dev/ttys004`. The most reliable anchor
    /// there is — Terminal.app and iTerm2 both expose it per tab.
    var tty: String?
    var pid: Int32?           // Claude Code's own pid, as a last-resort anchor
    /// Bundle id of a GUI app that owns this session (e.g. `com.conductor.app`).
    /// Such a session can be brought to the front, but there is no terminal
    /// surface to type keystrokes into.
    var desktopApp: String?

    /// Human name of the owning app, for the jump affordance — the app that hosts
    /// the session, which is not necessarily the agent running in it (a Claude
    /// Code session can live inside Conductor).
    var desktopAppName: String? {
        switch desktopApp {
        case "com.conductor.app":              return "Conductor"
        case "com.anthropic.claudefordesktop": return "Claude"
        case .some(let id):                    return id
        case nil:                              return nil
        }
    }

    /// Is there anywhere to jump to? A GUI-app session counts — we can front its
    /// window even though it has no terminal. Only sessions with truly nowhere to
    /// go (the Claude Code app before it declared one) return false.
    var isAddressable: Bool {
        app != nil || tty != nil || tmuxPane != nil || desktopApp != nil
    }

    /// Can we deliver keystrokes? Only a real terminal emulator qualifies — a
    /// desktop app like Conductor can be focused but never typed into, so its
    /// rows show a jump arrow yet no answer box or compose target.
    var canType: Bool { app != nil || tty != nil || tmuxPane != nil }
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    var agent: String
    var cwd: String
    var state: SessionState
    var detail: String
    var terminal: TerminalRef
    var updatedAt: Date
    var startedAt: Date
    /// A better human label than the cwd basename, when a harness knows one —
    /// Conductor's branch, say, instead of its worktree codename. Nil falls back
    /// to `project`.
    var title: String? = nil

    /// Directory basename — what the user actually recognizes a session by.
    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "~" : name
    }

    /// What the row shows in bold: the harness-supplied label if there is one.
    var displayName: String { title ?? project }

    static func == (a: AgentSession, b: AgentSession) -> Bool {
        a.id == b.id && a.state == b.state && a.detail == b.detail && a.updatedAt == b.updatedAt
    }
}

/// A blocked PreToolUse call waiting on a human decision.
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let agent: String
    let project: String
    let toolName: String
    /// Single-line human summary of the tool input (the command, the path, the URL…).
    let summary: String
    /// Full pretty-printed input, revealed on demand.
    let detail: String
    let createdAt: Date
    let expiresAt: Date

    static func == (a: PermissionRequest, b: PermissionRequest) -> Bool { a.id == b.id }
}

enum PermissionDecision: String {
    case allow
    case deny
    /// Fall through to Claude Code's own prompt in the terminal.
    case ask
}

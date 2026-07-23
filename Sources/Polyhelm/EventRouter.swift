import Foundation

/// Translates raw Claude Code hook payloads into session/permission mutations.
///
/// The hook script forwards the event JSON verbatim on stdin and adds a `_env`
/// object carrying the terminal coordinates of the process that fired it.
@MainActor
struct EventRouter {
    let store: SessionStore

    func handle(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        switch request.path {
        case "/health":
            respond(HTTPResponse(status: 200, json: ["ok": true, "version": AppInfo.version]))
        case "/sessions":
            // Read-only introspection — makes hook wiring debuggable from a shell.
            respond(HTTPResponse(status: 200, json: [
                "sessions": store.sorted.map { session in
                    [
                        "id": session.id,
                        "project": session.project,
                        "cwd": session.cwd,
                        "state": session.state.rawValue,
                        "detail": session.detail,
                        "terminal": session.terminal.app ?? "",
                        "updatedAt": ISO8601DateFormatter().string(from: session.updatedAt)
                    ]
                },
                "pending": store.pending.map { ["tool": $0.toolName, "summary": $0.summary] }
            ]))
        case "/usage":
            respond(HTTPResponse(status: 200, json: [
                "reports": store.usage.reports.map { report -> [String: Any] in
                    var row: [String: Any] = ["agent": report.brand.displayName]
                    if let quota = report.quota {
                        row["quota"] = [
                            "usedPercent": quota.usedPercent,
                            "window": quota.windowLabel,
                            "plan": quota.planType ?? "",
                            "resetsAt": quota.resetsAt.map {
                                ISO8601DateFormatter().string(from: $0)
                            } ?? ""
                        ]
                    }
                    if let measured = report.measured {
                        row["measured"] = [
                            "messages": measured.messages,
                            "input": measured.inputTokens,
                            "output": measured.outputTokens,
                            "cacheRead": measured.cacheReadTokens
                        ]
                    }
                    if let note = report.note { row["note"] = note }
                    return row
                }
            ]))
        case "/event":
            handleEvent(request.json)
            respond(.ok)
        case "/permission":
            handlePermission(request.json, respond: respond)
        default:
            respond(.error(404, "no route for \(request.path)"))
        }
    }

    // MARK: - Lifecycle events

    private func handleEvent(_ payload: [String: Any]) {
        let event = payload["hook_event_name"] as? String ?? ""
        let sessionID = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? NSHomeDirectory()

        // Conductor spawns Claude Code inside its own worktrees. If the user also
        // installed our hooks, those agents would surface twice — once here as a
        // bare row named after the worktree codename, and once (richly, with the
        // branch and model) via the Conductor watcher. Let the watcher own them.
        if ConductorSessionWatcher.owns(cwd: cwd) { return }

        let env = payload["_env"] as? [String: Any] ?? [:]
        let agent = env["AGENT"] as? String ?? "Claude Code"
        let terminal = Self.resolvedTerminal(env, cwd: cwd, agent: agent)

        switch event {
        case "SessionStart":
            store.upsert(id: sessionID, agent: agent, cwd: cwd, terminal: terminal,
                         state: .idle, detail: "Session started")

        case "UserPromptSubmit":
            let prompt = (payload["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            store.upsert(id: sessionID, agent: agent, cwd: cwd, terminal: terminal,
                         state: .working, detail: Self.firstLine(prompt, fallback: "Thinking…"))

        case "PreToolUse":
            let tool = payload["tool_name"] as? String ?? "tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            store.upsert(id: sessionID, agent: agent, cwd: cwd, terminal: terminal,
                         state: .working, detail: Self.summarize(tool: tool, input: input))

        case "Notification":
            // Claude Code emits this when it is blocked on the human — permission
            // prompts it could not route through a hook, and idle-timeout nudges.
            let message = payload["message"] as? String ?? "Needs your attention"
            store.upsert(id: sessionID, agent: agent, cwd: cwd, terminal: terminal,
                         state: .needsInput, detail: Self.firstLine(message, fallback: "Needs your attention"))

        case "Stop", "SubagentStop":
            store.upsert(id: sessionID, agent: agent, cwd: cwd, terminal: terminal,
                         state: .done, detail: "Waiting for your next message")

        case "SessionEnd":
            store.remove(id: sessionID)

        default:
            break
        }
    }

    // MARK: - Blocking permission requests

    private func handlePermission(_ payload: [String: Any], respond: @escaping (HTTPResponse) -> Void) {
        let sessionID = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? NSHomeDirectory()
        let tool = payload["tool_name"] as? String ?? "tool"
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let env = payload["_env"] as? [String: Any] ?? [:]
        let agent = env["AGENT"] as? String ?? "Claude Code"
        let terminal = Self.resolvedTerminal(env, cwd: cwd, agent: agent)
        // Capped by Settings well inside the hook's `curl -m 58`, so a decision
        // always beats the wire. `_timeout` is an override for testing.
        let timeout = (payload["_timeout"] as? Double) ?? Settings.shared.approvalTimeout

        store.upsert(id: sessionID, agent: agent, cwd: cwd, terminal: terminal,
                     state: .needsInput, detail: "\(tool) — awaiting approval")

        let pretty = (try? JSONSerialization.data(withJSONObject: input,
                                                  options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let request = PermissionRequest(
            id: UUID().uuidString,
            sessionID: sessionID,
            agent: agent,
            project: (cwd as NSString).lastPathComponent,
            toolName: tool,
            summary: Self.summarize(tool: tool, input: input),
            detail: pretty,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(timeout)
        )

        store.enqueue(request) { decision, note in
            switch decision {
            case .ask:
                // Empty output = "no opinion"; Claude Code falls back to its own
                // in-terminal prompt, so a timeout is never a silent block.
                respond(HTTPResponse(status: 200, json: [:]))
            case .allow, .deny:
                respond(HTTPResponse(status: 200, json: [
                    "hookSpecificOutput": [
                        "hookEventName": "PreToolUse",
                        "permissionDecision": decision.rawValue,
                        "permissionDecisionReason": note ?? "\(decision == .allow ? "Approved" : "Denied") from Polyhelm"
                    ]
                ]))
            }
        }
    }

    // MARK: - Helpers

    /// The Claude desktop app runs `claude` with no controlling terminal, so a
    /// Claude Code session that reports no terminal env at all is almost certainly
    /// it. Hand it the app as a jump target instead of a dead "no terminal" glyph.
    /// (Conductor's worktree agents are terminal-less too, but the watcher owns
    /// those and gives them the Conductor app, so they never reach here.)
    private static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    private static func resolvedTerminal(_ env: [String: Any],
                                         cwd: String, agent: String) -> TerminalRef {
        var ref = terminal(from: env)
        if !ref.canType,
           AgentBrand.infer(from: agent) == .claudeCode,
           !ConductorSessionWatcher.owns(cwd: cwd) {
            ref.desktopApp = claudeDesktopBundleID
        }
        return ref
    }

    private static func terminal(from env: [String: Any]) -> TerminalRef {
        func str(_ key: String) -> String? {
            guard let value = env[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return TerminalRef(app: str("TERM_PROGRAM"),
                           itermSession: str("ITERM_SESSION_ID"),
                           termSession: str("TERM_SESSION_ID"),
                           weztermPane: str("WEZTERM_PANE"),
                           kittyWindow: str("KITTY_WINDOW_ID"),
                           tmuxPane: str("TMUX_PANE"),
                           tmuxSocket: str("TMUX"),
                           tty: str("TTY"),
                           pid: str("PPID").flatMap { Int32($0) })
    }

    private static func firstLine(_ text: String, fallback: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return fallback }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// Turns a tool call into the one line a human needs to judge it.
    static func summarize(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return firstLine(input["command"] as? String ?? "", fallback: "shell command")
        case "Read", "Write", "Edit", "NotebookEdit":
            let path = input["file_path"] as? String ?? ""
            return "\(tool) \(abbreviate(path))"
        case "WebFetch":
            return "Fetch \(input["url"] as? String ?? "")"
        case "WebSearch":
            return "Search “\(input["query"] as? String ?? "")”"
        case "Glob", "Grep":
            return "\(tool) \(input["pattern"] as? String ?? "")"
        case "Task":
            return firstLine(input["description"] as? String ?? "", fallback: "Subagent task")
        default:
            return tool
        }
    }

    /// `/Users/me/Documents/FR/Sources/App.swift` → `~/Documents/FR/…/App.swift`
    private static func abbreviate(_ path: String) -> String {
        var display = path
        let home = NSHomeDirectory()
        if display.hasPrefix(home) { display = "~" + display.dropFirst(home.count) }
        let parts = display.split(separator: "/")
        guard parts.count > 4 else { return display }
        return parts.prefix(2).joined(separator: "/") + "/…/" + parts.suffix(1).joined()
    }
}

enum AppInfo {
    static let version = "1.0.0"
    static let port: UInt16 = 8787
}

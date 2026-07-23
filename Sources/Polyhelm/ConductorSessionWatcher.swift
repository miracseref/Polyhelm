import Foundation
import SQLite3

/// Surfaces Conductor workspaces in the island by reading its state database.
///
/// Conductor runs Claude Code and Codex agents inside git worktrees under
/// `~/conductor/workspaces/`, and — like Codex, and unlike Claude Code — it has
/// no hook system to push us events. What it does have is a single SQLite
/// database that is the app's own source of truth: one row per session carrying
/// the status, model, context fill, and title, joined to the workspace that owns
/// it for the branch and repo.
///
/// This opens that database **read-only** and polls it. It never writes, never
/// takes a write lock, and never touches Conductor's files any other way — the
/// same contract the Codex watcher keeps with its rollout logs. SQLite's WAL mode
/// lets a read-only connection run concurrently with Conductor's own writes.
@MainActor
final class ConductorSessionWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private let queue = DispatchQueue(label: "polyhelm.conductorwatch", qos: .utility)
    private var isScanning = false

    /// Sessions untouched for this long are assumed idle and drop off the island —
    /// Conductor keeps hundreds of archived workspaces, so the notch only ever
    /// shows what you are actively working in.
    private let activeWindow: TimeInterval = 30 * 60
    /// Ids we own, so a poll can retire ones that went quiet without disturbing
    /// anything the hook pipeline or the Codex watcher created.
    nonisolated static let idPrefix = "conductor:"

    /// `~/Library/Application Support/com.conductor.app/conductor.db`.
    nonisolated static var databaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.conductor.app/conductor.db")
    }

    /// True when a worktree path belongs to Conductor. The hook pipeline uses this
    /// to stand aside: if Claude Code hooks are installed, the agents Conductor
    /// spawns would otherwise show up twice — once here, richly, and once as a
    /// bare "Claude Code" row named after the worktree codename.
    nonisolated static func owns(cwd: String) -> Bool {
        cwd.contains("/conductor/workspaces/")
    }

    init(store: SessionStore) {
        self.store = store
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    deinit { timer?.invalidate() }

    func poll() {
        guard !isScanning else { return }
        let db = Self.databaseURL
        guard FileManager.default.fileExists(atPath: db.path) else { return }

        isScanning = true
        let cutoff = Date().addingTimeInterval(-activeWindow)
        queue.async { [weak self] in
            let found = Self.scan(db: db, since: cutoff)
            Task { @MainActor in
                guard let self else { return }
                self.store.syncWatched(prefix: Self.idPrefix, sessions: found)
                self.isScanning = false
            }
        }
    }

    /// Diagnostic: runs the real scan with an arbitrary window and prints it.
    /// Calls the same `scan` the live poll uses, so it proves the shipping path.
    nonisolated static func dump(minutes: Double) {
        let db = databaseURL
        guard FileManager.default.fileExists(atPath: db.path) else {
            print("no Conductor database on this Mac (\(db.path))"); return
        }
        let found = scan(db: db, since: Date().addingTimeInterval(-minutes * 60))
        print("window: last \(Int(minutes)) min — \(found.count) active workspace(s)")
        for session in found.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let name = (session.displayName).padding(toLength: 26, withPad: " ", startingAt: 0)
            let state = session.state.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(name)\(state)\(session.detail.prefix(60))")
        }
    }

    // MARK: - Reading

    nonisolated private static func scan(db: URL, since cutoff: Date) -> [AgentSession] {
        var handle: OpaquePointer?
        // Open the file itself read-only — no URI, so a space in the path (there
        // is one, in "Application Support") needs no encoding. A read-only
        // connection cannot take a write lock, so this can never block Conductor
        // or corrupt its file; WAL mode lets it read while Conductor writes.
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)

        // One row per active workspace, keyed on the session Conductor currently
        // has open in it. Archived workspaces are excluded; the cutoff drops
        // anything you have not touched recently.
        let sql = """
        SELECT s.id, s.status, s.agent_type, s.model, s.title,
               s.context_used_percent, s.unread_count, s.is_compacting, s.updated_at,
               w.workspace_name, w.branch, w.workspace_path, w.derived_status, r.name
        FROM workspaces w
        JOIN sessions s ON s.id = w.active_session_id
        LEFT JOIN repos r ON r.id = w.repository_id
        WHERE w.state != 'archived'
          AND s.is_hidden = 0
          AND s.updated_at >= ?
        ORDER BY s.updated_at DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        // SQLite stores `datetime('now')` as UTC "yyyy-MM-dd HH:mm:ss"; comparing
        // and parsing both in UTC keeps the window honest across time zones.
        let stamps = DateFormatter()
        stamps.locale = Locale(identifier: "en_US_POSIX")
        stamps.timeZone = TimeZone(identifier: "UTC")
        stamps.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlite3_bind_text(stmt, 1, stamps.string(from: cutoff), -1, SQLITE_TRANSIENT)

        var sessions: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? {
                guard let c = sqlite3_column_text(stmt, i) else { return nil }
                let s = String(cString: c)
                return s.isEmpty ? nil : s
            }
            guard let id = text(0) else { continue }

            let status = (text(1) ?? "idle").lowercased()
            let agentType = text(2) ?? "claude"
            let model = text(3)
            let sessionTitle = text(4)
            let ctx = sqlite3_column_double(stmt, 5)
            let unread = sqlite3_column_int(stmt, 6)
            let compacting = sqlite3_column_int(stmt, 7) == 1
            let updatedText = text(8)
            let workspaceName = text(9)
            let branch = text(10)
            let workspacePath = text(11)
            let derived = (text(12) ?? "").lowercased()
            let repo = text(13)

            let updated = updatedText.flatMap { stamps.date(from: $0) } ?? Date()
            let state = mapState(status: status, derived: derived,
                                 unread: Int(unread), compacting: compacting)

            // Bold label: the branch is what a human reads a workspace by; the
            // codename directory is a last resort.
            let label = branch ?? workspaceName ?? repo
                ?? workspacePath.map { ($0 as NSString).lastPathComponent }

            var parts: [String] = []
            if let sessionTitle, state != .working { parts.append(sessionTitle) }
            if let model { parts.append(model) }
            if ctx >= 1 { parts.append("\(Int(ctx.rounded()))% ctx") }
            let detail = compacting ? "Compacting context…" : parts.joined(separator: "  ·  ")

            // These are ordinary Claude Code / Codex agents that happen to run
            // inside Conductor — brand them as what they actually are, not as a
            // harness of their own. Only the jump target (the app below) is
            // Conductor-specific.
            let agent = agentType == "codex" ? "Codex" : "Claude Code"

            sessions.append(AgentSession(
                id: idPrefix + id,
                agent: agent,
                cwd: workspacePath ?? NSHomeDirectory(),
                state: state,
                detail: detail,
                // No terminal to type into, but the workspace lives in the
                // Conductor app — so the row can still bring it to the front.
                terminal: TerminalRef(desktopApp: "com.conductor.app"),
                updatedAt: updated,
                startedAt: updated,
                title: label
            ))
        }
        return sessions
    }

    /// Conductor's session status vocabulary (running/active/idle/error/…),
    /// folded onto the five states the island draws.
    nonisolated private static func mapState(status: String, derived: String,
                                             unread: Int, compacting: Bool) -> SessionState {
        if status == "error" { return .error }
        if compacting { return .working }
        switch status {
        case "running", "active", "processing", "generating", "executing",
             "working", "thinking", "streaming", "queued", "waiting":
            // Anything mid-turn reads as working. "waiting"/"queued" are folded in
            // here on purpose: their exact semantics aren't documented, and a
            // false "needs you" (sound + amber pill) is worse than a false
            // "working" — the real act-on-me signal is unread output, below.
            return .working
        default:
            // Idle: finished and waiting on you. A workspace with unread agent
            // output is worth a glance, so it sorts as freshly done rather than
            // sinking to the bottom as plain idle.
            if unread > 0 || derived == "done" { return .done }
            return .idle
        }
    }
}

/// `sqlite3_bind_text` needs SQLITE_TRANSIENT so SQLite copies the string rather
/// than holding our pointer past the call. The macro isn't imported into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

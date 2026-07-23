import Foundation

/// Surfaces Codex sessions in the island by watching its rollout logs.
///
/// Codex has no hook system, so unlike Claude Code it cannot push events to us.
/// It does append a JSONL rollout per session under `~/.codex/sessions/`, which
/// carries everything the UI needs: the working directory, the model, and
/// `task_started` / `task_complete` events that bracket each turn.
///
/// Read-only and poll-based. Nothing here writes to Codex's files.
@MainActor
final class CodexSessionWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private let queue = DispatchQueue(label: "polyhelm.codexwatch", qos: .utility)
    private var isScanning = false
    private let cache = RolloutCache()

    /// Sessions untouched for this long are assumed finished and drop off.
    private let activeWindow: TimeInterval = 30 * 60
    /// Ids we own, so a poll can retire ones that ended without stepping on
    /// anything the hook pipeline created.
    nonisolated static let idPrefix = "codex:"

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
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return }

        isScanning = true
        let cutoff = Date().addingTimeInterval(-activeWindow)
        let cache = self.cache

        queue.async { [weak self] in
            let found = Self.scan(root: root, since: cutoff, cache: cache)
            Task { @MainActor in
                guard let self else { return }
                self.store.syncWatched(prefix: Self.idPrefix, sessions: found)
                self.isScanning = false
            }
        }
    }

    /// Diagnostic: runs the real scan with an arbitrary window and prints it.
    /// Deliberately calls the same `scan` the live poll uses, so this proves the
    /// shipping code path rather than a lookalike.
    nonisolated static func dump(minutes: Double) {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else {
            print("no ~/.codex/sessions on this Mac"); return
        }
        let found = scan(root: root,
                         since: Date().addingTimeInterval(-minutes * 60),
                         cache: RolloutCache())
        print("window: last \(Int(minutes)) min — \(found.count) session(s)")
        for session in found.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let project = session.project.padding(toLength: 20, withPad: " ", startingAt: 0)
            let state = session.state.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(project)\(state)\(session.detail.prefix(60))")
        }
    }

    // MARK: - Parsing

    nonisolated private static func scan(root: URL,
                                         since cutoff: Date,
                                         cache: RolloutCache) -> [AgentSession] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var sessions: [AgentSession] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, modified >= cutoff else { continue }

            // Rollouts are append-only, so an unchanged mtime means our previous
            // parse still holds.
            if let hit = cache.entries[url.path], hit.modified == modified {
                sessions.append(hit.session)
                continue
            }
            guard let session = parse(url, modified: modified) else { continue }
            cache.entries[url.path] = RolloutCache.Entry(modified: modified, session: session)
            sessions.append(session)
        }
        cache.prune(olderThan: cutoff)
        return sessions
    }

    nonisolated private static func parse(_ url: URL, modified: Date) -> AgentSession? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var cwd: String?
        var model: String?
        var lastPrompt: String?
        var lastEvent: String?
        var sawStart = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any]
            else { continue }

            switch record["type"] as? String {
            case "session_meta":
                cwd = payload["cwd"] as? String ?? cwd
            case "turn_context":
                cwd = payload["cwd"] as? String ?? cwd
                model = payload["model"] as? String ?? model
            case "event_msg":
                let kind = payload["type"] as? String ?? ""
                switch kind {
                case "user_message":
                    lastPrompt = payload["message"] as? String ?? lastPrompt
                    lastEvent = kind
                case "task_started":
                    sawStart = true
                    lastEvent = kind
                case "task_complete", "error":
                    lastEvent = kind
                case "agent_message":
                    lastEvent = kind
                default:
                    break
                }
            default:
                break
            }
        }

        guard let cwd else { return nil }

        // A Codex agent running inside Conductor writes a rollout here too, but the
        // Conductor watcher already surfaces it with richer state (branch, context
        // fill). Skip it so it doesn't show up twice.
        if ConductorSessionWatcher.owns(cwd: cwd) { return nil }

        // A turn that started and never completed is still running — unless the
        // file has gone quiet, in which case the process most likely died.
        let quiet = Date().timeIntervalSince(modified) > 90
        let state: SessionState
        switch lastEvent {
        case "error":            state = .error
        case "task_complete":    state = .done
        case "task_started", "agent_message", "user_message":
            state = (sawStart && !quiet) ? .working : .done
        default:                 state = .idle
        }

        let detail: String
        switch state {
        case .working:
            detail = lastPrompt.map { firstLine($0) } ?? "Working…"
        case .error:
            detail = "Turn ended with an error"
        default:
            detail = "Waiting for your next message"
        }

        return AgentSession(
            id: idPrefix + url.deletingPathExtension().lastPathComponent,
            agent: "Codex",
            cwd: cwd,
            state: state,
            detail: model.map { "\(detail)  ·  \($0)" } ?? detail,
            // Codex records no tty, so there is nothing to jump to or type into.
            // The UI already handles that by hiding those affordances.
            terminal: TerminalRef(),
            updatedAt: modified,
            startedAt: modified
        )
    }

    /// Pulls the human's actual instruction out of a `user_message`.
    ///
    /// Codex prepends injected context to these — Chrome tab dumps, environment
    /// blocks, markdown headings — so naively taking the first line yields
    /// "# Chrome tabs:" rather than anything the user typed.
    nonisolated private static func firstLine(_ text: String) -> String {
        let contextual: (String) -> Bool = { line in
            line.hasPrefix("#") || line.hasPrefix("<") || line.hasPrefix("-")
                || line.hasPrefix("```") || line.hasPrefix("|")
        }
        let candidate = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !contextual($0) && $0.count > 3 }

        guard let candidate else { return "Working…" }
        return candidate.count > 90 ? String(candidate.prefix(89)) + "…" : candidate
    }
}

/// Parsed rollouts keyed by path. Confined to the watcher's queue.
private final class RolloutCache: @unchecked Sendable {
    struct Entry {
        var modified: Date
        var session: AgentSession
    }
    var entries: [String: Entry] = [:]

    func prune(olderThan cutoff: Date) {
        entries = entries.filter { $0.value.modified >= cutoff }
    }
}

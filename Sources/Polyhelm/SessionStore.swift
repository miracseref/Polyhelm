import Foundation
import SwiftUI

/// Single source of truth for the notch UI. Everything mutates on the main actor;
/// the HTTP server hops here before touching it.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var pending: [PermissionRequest] = []
    @Published var isExpanded = false
    /// Which session the prompt bar targets. Nil falls back to the top row.
    @Published var selectedSession: String?
    /// True while there is an unsent draft, so hover-out can't discard it.
    @Published var isComposing = false

    enum Tab: String, CaseIterable { case sessions, usage }
    /// Which page the expanded panel is showing. A real tab rather than a
    /// popover — popovers are unreliable from a borderless non-key panel.
    @Published var tab: Tab = .sessions
    /// Shared across the header chip and the popover; one scanner, not several.
    let usage = UsageTracker()

    /// Continuations for hooks currently blocked waiting on a decision.
    private var waiters: [String: (PermissionDecision, String?) -> Void] = [:]
    private var sweepTimer: Timer?

    /// A session with no events for this long is presumed finished and drops off the list.
    private let staleAfter: TimeInterval = 60 * 60

    init() {
        // 1s granularity keeps permission timeouts inside the hook's curl window.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
    }

    var sorted: [AgentSession] {
        sessions.sorted {
            $0.state.urgency != $1.state.urgency
                ? $0.state.urgency < $1.state.urgency
                : $0.updatedAt > $1.updatedAt
        }
    }

    var attentionCount: Int {
        sessions.filter { $0.state == .needsInput || $0.state == .error }.count + pending.count
    }

    /// Drives the collapsed pill: whatever is most urgent right now.
    var headline: SessionState? {
        if !pending.isEmpty { return .needsInput }
        return sorted.first?.state
    }

    // MARK: - Session mutation

    func upsert(id: String,
                agent: String,
                cwd: String,
                terminal: TerminalRef,
                state: SessionState,
                detail: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            let previous = sessions[index].state
            sessions[index].state = state
            sessions[index].detail = detail
            sessions[index].cwd = cwd
            sessions[index].updatedAt = Date()
            // Keep terminal coordinates from the first sighting; later hooks may run
            // detached from the tty and report nothing.
            if terminal.app != nil { sessions[index].terminal = terminal }
            if previous != state { Chiptune.shared.play(for: state) }
        } else {
            sessions.append(AgentSession(id: id,
                                         agent: agent,
                                         cwd: cwd,
                                         state: state,
                                         detail: detail,
                                         terminal: terminal,
                                         updatedAt: Date(),
                                         startedAt: Date()))
            Chiptune.shared.play(for: state)
        }
    }

    func remove(id: String) {
        sessions.removeAll { $0.id == id }
        // Release any hook still blocked on this session before dropping it,
        // otherwise its curl sits there until the wire times out.
        for request in pending where request.sessionID == id {
            resolve(request.id, .ask, note: nil)
        }
    }

    /// Replaces the set of sessions owned by a watcher (as opposed to pushed by
    /// hooks), leaving every other session untouched.
    ///
    /// Upserts rather than rebuilding so rows keep their identity across polls —
    /// wiping and re-adding would restart animations every few seconds.
    func syncWatched(prefix: String, sessions incoming: [AgentSession]) {
        let live = Set(incoming.map(\.id))
        for session in incoming {
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                guard sessions[index] != session else { continue }
                let previous = sessions[index].state
                sessions[index] = session
                if previous != session.state { Chiptune.shared.play(for: session.state) }
            } else {
                sessions.append(session)
                Chiptune.shared.play(for: session.state)
            }
        }
        sessions.removeAll { $0.id.hasPrefix(prefix) && !live.contains($0.id) }
    }

    /// Manual dismissal for a session whose process died without a SessionEnd.
    func dismiss(id: String) {
        remove(id: id)
        if selectedSession == id { selectedSession = nil }
    }

    /// Reflect a prompt sent from the notch immediately, rather than waiting for
    /// the round trip through UserPromptSubmit.
    func noteSent(to id: String, message: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].state = .working
        sessions[index].detail = message.count > 90
            ? String(message.prefix(89)) + "…"
            : message
        sessions[index].updatedAt = Date()
    }

    private func sweep() {
        // Only touch @Published state when something actually changed — an
        // unconditional removeAll reassigns the array every tick, which fires
        // objectWillChange and forces a full SwiftUI redraw once a second.
        let cutoff = Date().addingTimeInterval(-staleAfter)
        if sessions.contains(where: { $0.updatedAt < cutoff }) {
            sessions.removeAll { $0.updatedAt < cutoff }
        }

        let now = Date()
        let expired = pending.filter { $0.expiresAt <= now }
        for request in expired {
            resolve(request.id, .ask, note: nil)
        }
    }

    // MARK: - Permissions

    /// Registers a blocked tool call and parks the hook's response until a decision lands.
    func enqueue(_ request: PermissionRequest, reply: @escaping (PermissionDecision, String?) -> Void) {
        pending.append(request)
        waiters[request.id] = reply
        isExpanded = true
        Chiptune.shared.play(for: .needsInput)
        NotchWindowController.shared?.reveal(focus: Settings.shared.focusOnApproval)
    }

    func resolve(_ id: String, _ decision: PermissionDecision, note: String?) {
        guard let reply = waiters.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        reply(decision, note)
        if decision != .ask { Chiptune.shared.play(for: decision == .allow ? .done : .error) }
    }
}

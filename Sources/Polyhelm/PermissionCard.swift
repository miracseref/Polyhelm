import SwiftUI

/// A tool call blocked in the terminal, waiting on Allow / Deny from here.
struct PermissionCard: View {
    let request: PermissionRequest
    /// Only the topmost card owns ⏎/⎋, so a stack of them can't fight over keys.
    let isFocused: Bool

    @EnvironmentObject private var store: SessionStore
    @State private var showingDetail = false
    @State private var feedback = ""
    @State private var showingFeedback = false
    @State private var now = Date()
    @State private var panelIsKey = false

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var secondsLeft: Int {
        max(0, Int(request.expiresAt.timeIntervalSince(now).rounded()))
    }

    /// Shortcuts only fire when the panel actually holds keyboard focus. Advertise
    /// them on exactly the same condition — a hint for a key that does nothing is
    /// worse than no hint.
    private var shortcutsLive: Bool { isFocused && panelIsKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            summary
            if showingDetail { detail }
            if showingFeedback { feedbackField }
            actions
        }
        .padding(12)
        .background(SessionState.needsInput.tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(SessionState.needsInput.tint.opacity(shortcutsLive ? 0.6 : 0.35),
                        lineWidth: 1)
        )
        .background(shortcutKeys)
        .onReceive(tick) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            panelIsKey = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            panelIsKey = false
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SessionState.needsInput.tint)
            Text(request.toolName)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(request.project)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            // Countdown to handing the prompt back to the terminal.
            Text("\(secondsLeft)s")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(secondsLeft <= 10 ? 0.85 : 0.35))
        }
    }

    private var summary: some View {
        Text(request.summary)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(showingDetail ? nil : 3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.black.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var detail: some View {
        ScrollView {
            Text(request.detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 130)
        .padding(8)
        .background(Color.black.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Denying with a reason is more useful than denying silently — the text goes
    /// back to the agent as `permissionDecisionReason`, so it can course-correct.
    private var feedbackField: some View {
        HStack(spacing: 6) {
            TextField("Why not? (sent back to the agent)", text: $feedback)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.white)
                .padding(7)
                .background(Color.black.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit { deny() }

            Button("Send") { deny() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(SessionState.error.tint)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            action("Allow", tint: SessionState.done.tint, key: "⏎") { allow() }
            action("Deny", tint: SessionState.error.tint, key: "⎋") { deny() }

            Spacer()

            link(showingFeedback ? "Cancel note" : "Deny with note") {
                withAnimation(.easeInOut(duration: 0.18)) { showingFeedback.toggle() }
            }
            link(showingDetail ? "Less" : "Details") {
                withAnimation(.easeInOut(duration: 0.18)) { showingDetail.toggle() }
            }
            link("Terminal") { TerminalJump.focus(session?.terminal) }
        }
    }

    /// Invisible buttons that carry the real key equivalents.
    @ViewBuilder private var shortcutKeys: some View {
        if isFocused {
            ZStack {
                Button("") { allow() }.keyboardShortcut(.return, modifiers: [])
                Button("") { deny() }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Actions

    private func allow() {
        store.resolve(request.id, .allow, note: nil)
    }

    private func deny() {
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        store.resolve(request.id, .deny, note: note.isEmpty ? "Denied from Polyhelm" : note)
    }

    private var session: AgentSession? {
        store.sessions.first { $0.id == request.sessionID }
    }

    private func action(_ title: String, tint: Color, key: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                if shortcutsLive {
                    Text(key)
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.6)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func link(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
    }
}

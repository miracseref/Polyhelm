import SwiftUI

/// Compose and send a prompt to the selected session without leaving the notch.
///
/// There is no API to push text into a running Claude Code process, so this types
/// into the session's terminal the same way you would — which is why it only
/// works for sessions with an addressable terminal.
struct PromptBar: View {
    @EnvironmentObject private var store: SessionStore
    @State private var text = ""
    @State private var justSent = false
    @FocusState private var focused: Bool

    private var target: AgentSession? {
        store.sessions.first { $0.id == store.selectedSession } ?? store.sorted.first
    }

    private var canSend: Bool {
        guard let target else { return false }
        return target.terminal.canType
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white.opacity(0.35))

                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit(send)
                    // Keep the panel open while the field is focused or holds an
                    // unsent draft. Both handlers must compute the same value, or
                    // whichever fires last wins and the state flaps.
                    .onChange(of: text) { _, _ in syncComposing() }
                    .onChange(of: focused) { _, _ in syncComposing() }

                if justSent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(SessionState.done.tint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(canSend
                                             ? Color(red: 0.55, green: 0.78, blue: 1.0)
                                             : .white.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.03))
        }
    }

    /// Single source of truth for "the user is mid-thought, don't collapse".
    private func syncComposing() {
        store.isComposing = focused
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        guard let target else { return "No session to send to" }
        guard target.terminal.canType else {
            if let app = target.terminal.desktopAppName {
                return "\(target.displayName) runs in \(app) — no terminal to type into"
            }
            return "\(target.displayName) has no terminal to type into"
        }
        return "Message \(target.displayName)…"
    }

    private func send() {
        guard canSend, let target else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        TerminalJump.send(message, to: target.terminal)

        text = ""
        store.isComposing = false
        store.noteSent(to: target.id, message: message)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { justSent = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.2)) { justSent = false }
        }
    }
}

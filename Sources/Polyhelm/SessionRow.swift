import SwiftUI

struct SessionRow: View {
    let session: AgentSession
    var isSelected: Bool = false
    @EnvironmentObject private var store: SessionStore
    @State private var hovering = false

    var body: some View {
        Button {
            // Single click targets the prompt bar; the arrow does the jump.
            store.selectedSession = session.id
        } label: {
            HStack(spacing: 11) {
                // One badge carries all three things a row needs to say: which
                // agent, what state, and whether it is alive right now. Three
                // separate indicators in three columns was pure noise.
                SessionBadge(brand: AgentBrand.infer(from: session.agent),
                             state: session.state)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(session.state.label.lowercased())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(session.state.tint.opacity(0.85))
                    }
                    Text(session.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if hovering {
                    // Only offer the jump when there is somewhere to jump to.
                    if session.terminal.isAddressable {
                        Button { TerminalJump.focus(session.terminal) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help(session.terminal.canType
                              ? "Jump to this session's terminal"
                              : "Open in \(session.terminal.desktopAppName ?? "app")")
                    } else {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.25))
                            .help("No terminal — this session runs in the Claude Code app")
                    }
                    // Escape hatch for a session whose process died without
                    // ever emitting SessionEnd.
                    Button {
                        store.dismiss(id: session.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss this session")
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.white.opacity(isSelected ? 0.10 : (hovering ? 0.075 : 0.045)),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.18 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A session waiting on the human, with the answer box right there.
///
/// Approvals get a PermissionCard, but a plain question — Claude Code's
/// `Notification` event — previously had nowhere to answer from: you had to jump
/// to the terminal. This closes that.
struct ReplyBox: View {
    let session: AgentSession
    @EnvironmentObject private var store: SessionStore
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        session.terminal.canType
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                SessionBadge(brand: AgentBrand.infer(from: session.agent), state: session.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(session.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if session.terminal.canType {
                HStack(spacing: 6) {
                    // One tap covers the overwhelmingly common answers.
                    ForEach(["yes", "no", "continue"], id: \.self) { reply in
                        Button { send(reply) } label: {
                            Text(reply)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    TextField("Answer \(session.displayName)…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onSubmit { send(text) }
                        .padding(7)
                        .background(Color.black.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button { send(text) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(canSend ? SessionState.done.tint : .white.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            } else if session.terminal.desktopApp != nil {
                // No terminal to type into, but we can hand the user straight to
                // the app that owns it — one click instead of hunting for it.
                Button { TerminalJump.focus(session.terminal) } label: {
                    Label("Open in \(session.terminal.desktopAppName ?? "app")",
                          systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Label("No terminal to answer into — this session runs in the app",
                      systemImage: "desktopcomputer")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(11)
        .background(SessionState.needsInput.tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(SessionState.needsInput.tint.opacity(0.3), lineWidth: 1)
        )
        .onChange(of: focused) { _, value in store.isComposing = value || !text.isEmpty }
    }

    private func send(_ reply: String) {
        let message = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, session.terminal.canType else { return }
        TerminalJump.send(message, to: session.terminal)
        store.noteSent(to: session.id, message: message)
        text = ""
        store.isComposing = false
    }
}


/// Agent identity, session state, and liveness in a single mark.
struct SessionBadge: View {
    let brand: AgentBrand
    let state: SessionState

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 24, height: 24)
            Circle()
                .strokeBorder(state.tint.opacity(0.5), lineWidth: 1.5)
                .frame(width: 24, height: 24)
            AgentMark(brand: brand, size: 12)
            // Expanding ring, contained inside the 32pt slot so it can never
            // reach the text beside it.
            PulseRing(color: state.tint, animating: state == .working, base: 24, slot: 32)
        }
        .frame(width: 32, height: 32)
    }
}

/// A ring that expands and fades on repeat, driven by Core Animation so it costs
/// this process nothing per frame.
struct PulseRing: View {
    let color: Color
    let animating: Bool
    var base: CGFloat = 24
    var slot: CGFloat = 32

    var body: some View {
        PulseRingBacking(color: color, animating: animating, base: base)
            .frame(width: slot, height: slot)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

private struct PulseRingBacking: NSViewRepresentable {
    let color: Color
    let animating: Bool
    let base: CGFloat

    func makeNSView(context: Context) -> PulseRingView { PulseRingView(base: base) }
    func updateNSView(_ view: PulseRingView, context: Context) {
        view.apply(color: NSColor(color), animating: animating)
    }
}

final class PulseRingView: NSView {
    private let ring = CAShapeLayer()
    private let base: CGFloat
    private var isAnimating = false

    init(base: CGFloat) {
        self.base = base
        super.init(frame: NSRect(x: 0, y: 0, width: base, height: base))
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.opacity = 0
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = CGRect(x: (bounds.width - base) / 2, y: (bounds.height - base) / 2,
                          width: base, height: base)
        ring.frame = rect
        ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
        CATransaction.commit()
    }

    func apply(color: NSColor, animating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color.cgColor
        CATransaction.commit()

        guard animating != isAnimating else { return }
        isAnimating = animating

        guard animating else {
            ring.removeAnimation(forKey: "pulse")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            ring.opacity = 0
            CATransaction.commit()
            return
        }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        // Capped so the ring stays inside its slot and never touches neighbours.
        scale.toValue = 1.32
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }
}

/// Steady dot at rest, breathing while the agent is mid-turn.
///
/// Backed by Core Animation rather than SwiftUI on purpose. A SwiftUI
/// `repeatForever` animation ticks this process's render loop every frame — one
/// pulsing dot measured ~6-8% CPU continuously, whether or not it had a shadow.
/// A `CABasicAnimation` is handed to the render server once and runs there, so
/// the app itself does no per-frame work at all.
struct PulseDot: View {
    let color: Color
    let animating: Bool
    var diameter: CGFloat = 8

    var body: some View {
        // The explicit frame is load-bearing. An NSViewRepresentable without one
        // expands to fill all offered space, which silently swallowed each row's
        // width and pushed every other element to the right.
        PulseDotBacking(color: color, animating: animating, diameter: diameter)
            .frame(width: diameter * 2.1, height: diameter * 2.1)
            .fixedSize()
    }
}

private struct PulseDotBacking: NSViewRepresentable {
    let color: Color
    let animating: Bool
    var diameter: CGFloat

    func makeNSView(context: Context) -> PulseDotView {
        PulseDotView(diameter: diameter)
    }

    func updateNSView(_ view: PulseDotView, context: Context) {
        view.apply(color: NSColor(color), animating: animating)
    }
}

final class PulseDotView: NSView {
    private let core = CALayer()
    private let halo = CALayer()
    private let diameter: CGFloat
    private var isAnimating = false

    init(diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter * 2.1, height: diameter * 2.1))
        wantsLayer = true
        layer?.addSublayer(halo)
        layer?.addSublayer(core)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter * 2.1, height: diameter * 2.1)
    }

    override func layout() {
        super.layout()
        // Position without implicit animations, or every relayout cross-fades.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [core, halo] {
            sublayer.frame = CGRect(x: (bounds.width - diameter) / 2,
                                    y: (bounds.height - diameter) / 2,
                                    width: diameter, height: diameter)
            sublayer.cornerRadius = diameter / 2
        }
        CATransaction.commit()
    }

    func apply(color: NSColor, animating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(0.35).cgColor
        CATransaction.commit()

        guard animating != isAnimating else { return }
        isAnimating = animating

        if animating {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 2.1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0.0

            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.15
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            halo.add(group, forKey: "pulse")
        } else {
            halo.removeAnimation(forKey: "pulse")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            halo.opacity = 0
            CATransaction.commit()
        }
    }
}

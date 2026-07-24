import SwiftUI

/// The island. One container that morphs between a collapsed pill hugging the
/// notch and an expanded panel — never two separate views swapped out, which is
/// what lets the geometry animate continuously.
struct NotchView: View {
    /// Upper bound on each wing. The value actually used comes from the display
    /// (`geometry.wingWidth`), because a 76pt wing beside a 185pt notch reads very
    /// differently on a 13" screen than on a 16" one.
    ///
    /// Wings must stay equal on both sides or the middle stops lining up with the
    /// physical cutout.
    static let maxWingWidth: CGFloat = 76

    let geometry: NotchGeometry
    @EnvironmentObject private var store: SessionStore
    @ObservedObject private var settings = Settings.shared
    @State private var hovering = false
    /// Pending collapse, cancelled if the pointer comes back. Without this the
    /// panel flaps every time the mouse crosses the top of the screen.
    @State private var collapseTask: Task<Void, Never>?
    /// Pending open, cancelled if the pointer leaves before the dwell elapses.
    /// The island straddles the menu-bar band and, when agents run, spreads wings
    /// out to either side of the notch — right where browser tabs and menu items
    /// live. Opening the instant the pointer touches that band made the panel
    /// ambush anything the user was reaching for up top. Requiring a brief dwell
    /// means a sweep *past* the notch no longer springs it open; only lingering does.
    @State private var openTask: Task<Void, Never>?

    private var expanded: Bool { store.isExpanded }

    /// Nothing running: the island is exactly the notch and disappears into it.
    private var isDormant: Bool { store.sessions.isEmpty && store.pending.isEmpty }

    private var wing: CGFloat { isDormant ? 0 : geometry.wingWidth }

    private var islandWidth: CGFloat {
        expanded ? geometry.expandedWidth : geometry.notchWidth + 2 * wing
    }

    /// Spring tuned to feel like the hardware island: quick, slightly overshooting,
    /// settled well before the eye expects it.
    private var morph: Animation {
        .spring(response: 0.38, dampingFraction: 0.78)
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morph, value: expanded)
        .animation(.easeInOut(duration: 0.2), value: store.sessions)
        .animation(.easeInOut(duration: 0.2), value: store.pending.count)
    }

    private var island: some View {
        VStack(spacing: 0) {
            headerStrip
            if expanded { expandedBody.transition(.opacity) }
        }
        .frame(width: islandWidth)
        .background(
            NotchShape(cornerRadius: expanded ? 26 : 10)
                .fill(Color.black.opacity(expanded ? 0.86 : 1))
                .background(
                    NotchShape(cornerRadius: expanded ? 26 : 10)
                        .fill(.ultraThinMaterial)
                        .opacity(expanded ? 1 : 0)
                )
        )
        .overlay(
            NotchShape(cornerRadius: expanded ? 26 : 10)
                .strokeBorder(Color.white.opacity(expanded ? 0.12 : 0), lineWidth: 1)
        )
        .clipShape(NotchShape(cornerRadius: expanded ? 26 : 10))
        .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 24, y: 8)
        .contentShape(NotchShape(cornerRadius: expanded ? 26 : 10))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { NotchWindowController.shared?.setIslandSize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in
                        NotchWindowController.shared?.setIslandSize(size)
                    }
            }
        )
        .onHover { inside in
            hovering = inside
            inside ? scheduleOpen() : scheduleCollapse()
        }
        .background(
            // ⎋ collapses, unless an approval card is using it for Deny.
            Group {
                if expanded && store.pending.isEmpty {
                    Button("") { NotchWindowController.shared?.collapse() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        )
    }

    // MARK: - Header strip (the part that is always visible)

    private var headerStrip: some View {
        HStack(spacing: 0) {
            leftWing
            // The physical cutout. Painted black so the island reads as one shape.
            Color.clear.frame(width: expanded ? 0 : geometry.notchWidth)
            rightWing
        }
        .frame(height: geometry.notchHeight + (expanded ? 12 : 0))
        .padding(.horizontal, expanded ? 16 : 0)
    }

    private var leftWing: some View {
        HStack(spacing: 7) {
            // The dot only earns its ~24pt when expanded. Collapsed, the status
            // dots on the right already carry state, and this one was stealing a
            // third of the wing — which is why the project name kept truncating.
            if expanded {
                PulseDot(color: store.headline?.tint ?? Color(white: 0.35),
                         animating: store.sessions.contains { $0.state == .working })
            }
            if expanded {
                Text("Polyhelm")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Button {
                    NotchWindowController.shared?.collapse()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Collapse (⎋)")
            } else {
                Text(marquee)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(store.headline?.tint ?? .white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        // Padding goes INSIDE the frame. Applied outside, it silently added 10pt
        // per side to the island's real width — part of why it overhung the notch.
        .padding(.leading, expanded ? 0 : 9)
        .frame(width: expanded ? nil : wing, alignment: .leading)
        .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        .clipped()
    }

    private var rightWing: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if expanded {
                usageChip
            } else {
                // Budgeted to fit `wing` exactly: 3 dots plus an optional badge.
                // Four dots, a "+N" and a badge together overflowed and dragged
                // the whole island wider than the notch.
                ForEach(store.sorted.prefix(3)) { session in
                    Circle()
                        .fill(session.state.tint)
                        .frame(width: 6, height: 6)
                }
                if store.attentionCount > 0 {
                    Text("\(store.attentionCount)")
                        .font(.system(size: 9.5, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(SessionState.needsInput.tint, in: Capsule())
                } else if store.sessions.count > 3 {
                    Text("+\(store.sessions.count - 3)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(.trailing, expanded ? 0 : 9)
        .frame(width: expanded ? nil : wing, alignment: .trailing)
        .clipped()
    }

    /// What the collapsed pill says. Space is scarce, so this is a short phrase
    /// chosen for glanceability — never a raw tool line, which always truncated
    /// into meaningless fragments.
    private var marquee: String {
        if let request = store.pending.first { return request.toolName + "?" }
        guard let session = store.sorted.first else { return "" }
        let others = store.sessions.count - 1
        let suffix = others > 0 ? " +\(others)" : ""
        // State is already carried by the dot colour beside this, so the text
        // stays as the one thing colour cannot say: which project.
        return session.project + suffix
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.white.opacity(0.08))

            switch store.tab {
            case .sessions:
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(store.pending.enumerated()), id: \.element.id) { index, request in
                            PermissionCard(request: request, isFocused: index == 0)
                                .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                                        removal: .opacity))
                        }
                        ForEach(store.sorted) { session in
                            // A session blocked on a question gets an answer box
                            // inline; everything else stays a compact row.
                            if session.state == .needsInput {
                                ReplyBox(session: session).transition(.opacity)
                            } else {
                                SessionRow(session: session,
                                           isSelected: store.selectedSession == session.id)
                                    .transition(.opacity)
                            }
                        }
                        if store.sessions.isEmpty && store.pending.isEmpty { emptyState }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 320)
                PromptBar()
            case .usage:
                UsagePanel(usage: store.usage)
                    .frame(maxHeight: 380)
            }

            footer
        }
    }

    /// Sessions / Usage. Plain buttons in the view hierarchy, so they work
    /// without needing the window to present anything.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SessionStore.Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { store.tab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Text(tab == .sessions ? "Sessions" : "Usage")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        if tab == .sessions, store.attentionCount > 0 {
                            Text("\(store.attentionCount)")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(SessionState.needsInput.tint, in: Capsule())
                        }
                    }
                    .foregroundStyle(store.tab == tab ? .white : .white.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(store.tab == tab ? 0.10 : 0),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Header chip doubles as a shortcut into the Usage tab.
    private var usageChip: some View {
        UsageChip(usage: store.usage) {
            withAnimation(.easeInOut(duration: 0.15)) { store.tab = .usage }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.3))
            Text("No agents running")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Text(HookInstaller.isInstalled
                 ? "Start Claude Code in any terminal"
                 : "Install hooks below to get started")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.vertical, 34)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(HookInstaller.isInstalled ? "Hooks ✓" : "Install hooks") {
                HookInstaller.presentInstall()
            }
            Button(settings.notchApprovals ? "Approvals: notch" : "Approvals: terminal") {
                settings.notchApprovals.toggle()
                // Rewrite settings.json so the toggle actually takes effect.
                if HookInstaller.isInstalled { HookInstaller.apply() }
            }
            .foregroundStyle(settings.notchApprovals
                             ? SessionState.needsInput.tint.opacity(0.9)
                             : .white.opacity(0.55))
            Spacer()
            Text("⌥⌘Space")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.25))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.04))
    }

    // MARK: - Open / collapse

    /// Open only after the pointer dwells over the island, so aiming for a browser
    /// tab or menu-bar item beside the notch doesn't fling the panel open in
    /// passing. Cancelled the moment the pointer leaves (`scheduleCollapse`).
    private func scheduleOpen() {
        collapseTask?.cancel()
        guard !expanded else { return }
        openTask?.cancel()
        openTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, hovering, !expanded else { return }
            NotchWindowController.shared?.setExpanded(true)
        }
    }

    /// Collapse after a grace period, so brushing past the notch or crossing a
    /// gap between subviews doesn't slam the panel shut.
    private func scheduleCollapse() {
        // A pending open is now stale — the pointer left before it fired.
        openTask?.cancel()
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, !hovering else { return }
            // Never collapse out from under a decision the user still owes,
            // or while they are mid-sentence in the prompt bar.
            guard store.pending.isEmpty, !store.isComposing else { return }
            NotchWindowController.shared?.setExpanded(false)
        }
    }
}

/// Square on top (it meets the screen edge), rounded on the bottom.
struct NotchShape: InsettableShape {
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        NotchShape(cornerRadius: cornerRadius, inset: inset + amount)
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

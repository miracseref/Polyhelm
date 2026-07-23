import AppKit
import SwiftUI

/// Physical description of the host display's notch, or a synthetic one for
/// external / pre-notch screens so the UI has the same shape everywhere.
struct NotchGeometry {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasRealNotch: Bool
    var screenFrame: CGRect = .zero
    /// Height of the menu bar on this screen. On a notched Mac the island sits
    /// *in* that band; on every other screen it has to hang below it.
    var menuBarHeight: CGFloat = 24

    /// Where the top of the island goes, in screen coordinates.
    var islandTop: CGFloat {
        hasRealNotch ? screenFrame.maxY : screenFrame.maxY - menuBarHeight
    }

    /// The expanded panel scales with the display instead of being a fixed 580pt,
    /// which was ~34% of a 1728pt built-in but only 23% of a 2560pt external, and
    /// would overflow anything narrower than about 700pt.
    var expandedWidth: CGFloat {
        let ideal = screenFrame.width * 0.34
        return min(620, max(380, min(ideal, screenFrame.width - 80)))
    }

    /// Canvas the panel is drawn into. Must comfortably exceed the expanded panel
    /// in both axes, but never exceed the screen.
    var canvas: CGSize {
        CGSize(width: min(expandedWidth + 60, screenFrame.width),
               height: min(660, max(300, screenFrame.height * 0.62)))
    }

    /// Widest the collapsed wings may get on this display. On a small screen a
    /// 76pt wing is proportionally huge next to the notch.
    var wingWidth: CGFloat {
        min(NotchView.maxWingWidth, max(52, screenFrame.width * 0.045))
    }

    /// The display the island lives on.
    ///
    /// A physical notch is the whole point, so a notched built-in always wins over
    /// whichever screen happens to hold keyboard focus — otherwise the island would
    /// hop between displays every time the user switched windows.
    static func hostScreen() -> NSScreen? {
        NSScreen.screens.first { measure($0).hasRealNotch }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func measure(_ screen: NSScreen) -> NotchGeometry {
        // Menu bar band: what the screen has minus what windows may use.
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)

        // On notched Macs the two auxiliary areas flank the cutout; whatever
        // width they leave unaccounted for is the notch itself.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            // Notches run ~185pt (14") to ~200pt (16"); anything outside a sane
            // band means the auxiliary areas are telling us something else.
            if width > 100 && width < 400 {
                return NotchGeometry(notchWidth: width,
                                     // Trust the hardware rather than assuming 32.
                                     notchHeight: max(screen.safeAreaInsets.top, 24),
                                     hasRealNotch: true,
                                     screenFrame: screen.frame,
                                     menuBarHeight: menuBar)
            }
        }
        // No notch: a floating bar under the menu bar, proportioned like one so
        // the UI reads the same everywhere.
        return NotchGeometry(notchWidth: min(190, screen.frame.width * 0.11),
                             notchHeight: 30,
                             hasRealNotch: false,
                             screenFrame: screen.frame,
                             menuBarHeight: menuBar)
    }
}

/// Borderless, non-activating panel pinned to the top of the screen.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only accepts clicks inside the island itself.
///
/// The window is deliberately much larger than the island so the shape can morph
/// without ever resizing the window — resizing fights SwiftUI's animation and
/// produces the stepped, janky growth the old build had. The cost is a big
/// transparent surface over the top of the screen, so everything outside
/// `interactiveRect` must fall through to whatever is behind it.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// In this view's own (bottom-left origin) coordinates.
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// Without this, macOS spends the first click on an inactive app's window
    /// just bringing it forward. Polyhelm is an `.accessory` app that is almost
    /// never frontmost, so *every* click was a first click — buttons, tabs and
    /// text fields simply never received anything.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Take keyboard focus on press rather than waiting for a completed tap, so
    /// text fields are typable and controls respond on the same click that hit them.
    override func mouseDown(with event: NSEvent) {
        NotchWindowController.shared?.takeFocus()
        super.mouseDown(with: event)
    }
}

@MainActor
final class NotchWindowController: NSObject {
    static var shared: NotchWindowController?

    private let panel: NotchPanel
    private let store: SessionStore
    private var hosting: PassthroughHostingView<AnyView>!
    private(set) var geometry: NotchGeometry

    /// Canvas and panel width both come from the host display now — see
    /// NotchGeometry. A fixed 640x600 overflowed narrow screens outright.
    private var canvas: CGSize { geometry.canvas }
    /// Actual laid-out island size, reported back from SwiftUI.
    private var islandSize: CGSize = .zero
    private var outsideClickMonitor: Any?

    init(store: SessionStore) {
        self.store = store
        let screen = NotchGeometry.hostScreen() ?? NSScreen.screens[0]
        self.geometry = NotchGeometry.measure(screen)

        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: geometry.canvas),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        super.init()

        let view = PassthroughHostingView(
            rootView: AnyView(NotchView(geometry: geometry).environmentObject(store))
        )
        hosting = view
        panel.contentView = view

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func show() {
        position()
        updateInteractiveRect(expanded: store.isExpanded)
        panel.orderFrontRegardless()
        startOutsideClickMonitor()
    }

    /// Clicking anywhere else collapses the panel — the affordance people expect
    /// from a popover. Mouse-only monitors need no Accessibility grant.
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.isExpanded else { return }
                // A pending approval still owns the panel until it is answered.
                guard self.store.pending.isEmpty else { return }
                self.setExpanded(false)
            }
        }
    }

    /// Bring the panel forward when something needs the user.
    ///
    /// `focus` is opt-in: taking key status is what makes typing and ⏎/⎋ work, but
    /// it also pulls the caret out of whatever the user was typing in.
    func reveal(focus: Bool = false) {
        setExpanded(true)
        if focus { takeFocus() }
    }

    func takeFocus() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func setExpanded(_ expanded: Bool) {
        store.isExpanded = expanded
        updateInteractiveRect(expanded: expanded)
        if expanded {
            // Make the panel key the moment it opens — this is what makes it
            // actually interactive. SwiftUI controls ignore the first click in a
            // non-key window, so a hover-opened, non-key panel had dead tabs and
            // buttons: you could see the agents but touch nothing. A
            // `.nonactivatingPanel` can take key *without* activating the whole app
            // or ordering out what's behind it, so this costs none of that.
            panel.orderFrontRegardless()
            panel.makeKey()
        } else {
            store.isComposing = false
            // Give activation back to whatever the user was using. NEVER
            // NSApp.hide() here: that orders the panel out too, so the island
            // disappears entirely and there is nothing left to hover.
            if panel.isKeyWindow { NSApp.deactivate() }
        }
    }

    func collapse() { setExpanded(false) }

    /// Summoned by the ⌥⌘Space hotkey — always takes focus, since the user asked.
    func toggleViaHotKey() {
        // Keyed off the visible state only. Gating on isKeyWindow meant the
        // hotkey could not close a panel that was opened by hover.
        if store.isExpanded {
            setExpanded(false)
        } else {
            reveal(focus: true)
        }
    }

    /// Reported by the view once SwiftUI has laid the island out, so hit-testing
    /// matches what is actually drawn instead of the whole canvas.
    func setIslandSize(_ size: CGSize) {
        islandSize = size
        updateInteractiveRect(expanded: store.isExpanded)
    }

    private func position() {
        guard let screen = NotchGeometry.hostScreen() else { return }
        geometry = NotchGeometry.measure(screen)
        let canvas = geometry.canvas
        // islandTop hangs the panel below the menu bar on screens with no notch,
        // where anchoring to the very top would sit on top of the menu bar.
        panel.setFrame(NSRect(x: screen.frame.midX - canvas.width / 2,
                              y: geometry.islandTop - canvas.height,
                              width: canvas.width,
                              height: canvas.height),
                       display: true)
    }

    /// Clicks only land inside the island. Sized to the collapsed pill or the
    /// expanded panel, with a small margin so the hover target isn't pixel-tight.
    private func updateInteractiveRect(expanded: Bool) {
        let hasContent = !store.sessions.isEmpty || !store.pending.isEmpty
        let width = expanded
            ? geometry.expandedWidth
            : geometry.notchWidth + (hasContent ? 2 * geometry.wingWidth : 0)
        // Use the measured height when we have one; the canvas is far taller than
        // the panel, and claiming all of it swallows clicks in the empty space.
        let height = expanded
            ? (islandSize.height > 0 ? islandSize.height : canvas.height)
            // A few points of slop below the notch so the hover target is
            // reachable, without the island itself extending past the hardware.
            : geometry.notchHeight + 6
        // NSHostingView can't be flipped, so the island — which hangs from the top
        // of the canvas — sits at the high end of the y axis.
        hosting.interactiveRect = CGRect(x: (canvas.width - width) / 2,
                                         y: canvas.height - height,
                                         width: width,
                                         height: height)
    }

    // MARK: - Debug introspection (curl localhost:8787/debug)

    /// Snapshot of everything that decides whether the panel is interactive.
    func debugSnapshot() -> [String: Any] {
        func rect(_ r: CGRect) -> String {
            "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        }
        let mouse = NSEvent.mouseLocation
        return [
            "isExpanded": store.isExpanded,
            "isKeyWindow": panel.isKeyWindow,
            "isVisible": panel.isVisible,
            "canBecomeKey": panel.canBecomeKey,
            "appActive": NSApp.isActive,
            "activationPolicy": "\(NSApp.activationPolicy().rawValue)",
            "panelFrame": rect(panel.frame),
            "panelScreen": panel.screen?.localizedName ?? "nil",
            "hostScreen": NotchGeometry.hostScreen()?.localizedName ?? "nil",
            "hasRealNotch": geometry.hasRealNotch,
            "interactiveRect": rect(hosting.interactiveRect),
            "islandSize": "\(Int(islandSize.width))x\(Int(islandSize.height))",
            "mouseLocation": "\(Int(mouse.x)),\(Int(mouse.y))",
            "screens": NSScreen.screens.map { $0.localizedName }
        ]
    }

    /// Force the panel open with a chosen focus strategy, then report whether it
    /// actually took key. Lets a shell prove which strategy works on this machine.
    func debugForceExpand(strategy: String) -> [String: Any] {
        switch strategy {
        case "activate":
            store.isExpanded = true
            updateInteractiveRect(expanded: true)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        default: // "make"
            setExpanded(true)
        }
        var snap = debugSnapshot()
        snap["strategyUsed"] = strategy
        return snap
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    @objc private func screensChanged() {
        position()
        updateInteractiveRect(expanded: store.isExpanded)
        hosting.rootView = AnyView(NotchView(geometry: geometry).environmentObject(store))
    }
}

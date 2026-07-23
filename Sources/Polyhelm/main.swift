import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let settings = Settings.shared
    private var server: HTTPServer?
    private var statusItem: NSStatusItem?
    private var observers: Set<AnyCancellable> = []
    /// Codex has no hooks, so its sessions are discovered by watching its logs.
    private var codexWatcher: CodexSessionWatcher?
    /// Conductor has no hooks either; its sessions come from its state database.
    private var conductorWatcher: ConductorSessionWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Chiptune.shared.enabled = settings.soundsEnabled

        let controller = NotchWindowController(store: store)
        NotchWindowController.shared = controller
        controller.show()

        let router = EventRouter(store: store)
        let server = HTTPServer { request, respond in
            // The server runs off-main; every store mutation hops back here.
            Task { @MainActor in router.handle(request, respond: respond) }
        }
        do {
            try server.start(port: AppInfo.port)
            self.server = server
        } catch {
            let alert = NSAlert()
            alert.messageText = "Port \(AppInfo.port) is busy"
            alert.informativeText = """
            Polyhelm could not open its local listener — another copy may already \
            be running. Quit the other instance and relaunch.
            """
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }

        codexWatcher = CodexSessionWatcher(store: store)
        conductorWatcher = ConductorSessionWatcher(store: store)

        HotKey.register { NotchWindowController.shared?.toggleViaHotKey() }
        installMenuBarItem()

        // Keep the menu bar glyph in step with what the island is showing.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &observers)
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKey.unregister()
        server?.stop()
    }

    /// A menu bar item is the only way back to the app once the island is collapsed
    /// and the pointer is elsewhere.
    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item
        refreshStatusItem()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        return menu
    }

    /// Fills a menu in place. Swapping `statusItem.menu` while a menu is opening
    /// breaks the open tracking session, so rebuilds reuse the same object.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        add(to: menu, "Show island  ⌥⌘Space", #selector(showIsland))
        menu.addItem(.separator())

        add(to: menu, HookInstaller.isInstalled ? "Update Claude Code hooks…"
                                                : "Install Claude Code hooks…",
            #selector(installHooks))
        if HookInstaller.isInstalled {
            add(to: menu, "Remove hooks…", #selector(removeHooks))
        }
        menu.addItem(.separator())

        add(to: menu, "Approvals in the notch", #selector(toggleApprovals),
            state: settings.notchApprovals)
        add(to: menu, "Focus notch on approval", #selector(toggleFocus),
            state: settings.focusOnApproval)
        add(to: menu, "Sounds", #selector(toggleSound), state: settings.soundsEnabled)
        menu.addItem(.separator())

        add(to: menu, "Quit Polyhelm", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector,
                     state: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let state { item.state = state ? .on : .off }
        menu.addItem(item)
        return item
    }

    /// Glyph plus a count when something is waiting, so the state is legible even
    /// on an external display where the island isn't visible.
    private var renderedWaiting: Int = -1

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let waiting = store.attentionCount
        // Rebuilding the NSImage on every store change is pure waste; the glyph
        // only has two states.
        guard waiting != renderedWaiting else { return }
        renderedWaiting = waiting

        button.image = Self.statusImage(waiting: waiting > 0)
        button.title = waiting > 0 ? " \(waiting)" : ""
    }

    /// The Polyhelm mark as a menu-bar template: a rounded pill with three dots,
    /// the centre one larger to echo the app icon. Template (black + alpha) so the
    /// system tints it for light/dark menu bars. Idle draws an outline with solid
    /// dots; waiting fills the pill and knocks the dots out so attention reads fast.
    private static func statusImage(waiting: Bool) -> NSImage {
        let w: CGFloat = 34, h: CGFloat = 15, lw: CGFloat = 1.5
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let pillRect = NSRect(x: lw / 2, y: lw / 2, width: w - lw, height: h - lw)
            let radius = pillRect.height / 2
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)
            let cy = h / 2
            // (x-fraction, radius) — centre dot larger, like the icon.
            let dots: [(CGFloat, CGFloat)] = [(0.30, 1.7), (0.50, 2.4), (0.70, 1.7)]
            func dotPath(_ fx: CGFloat, _ r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: fx * w - r, y: cy - r, width: r * 2, height: r * 2))
            }
            NSColor.black.set()
            if waiting {
                pill.windingRule = .evenOdd
                for (fx, r) in dots { pill.append(dotPath(fx, r)) }
                pill.fill()
            } else {
                pill.lineWidth = lw
                pill.stroke()
                for (fx, r) in dots { dotPath(fx, r).fill() }
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Polyhelm"
        return img
    }

    // MARK: - Actions

    @objc private func showIsland() {
        NotchWindowController.shared?.toggleViaHotKey()
    }

    @objc private func installHooks() {
        HookInstaller.presentInstall()
    }

    @objc private func removeHooks() {
        HookInstaller.presentUninstall()
    }

    @objc private func toggleApprovals() {
        settings.notchApprovals.toggle()
        // The toggle is only real once settings.json reflects it.
        if HookInstaller.isInstalled { HookInstaller.apply() }
    }

    @objc private func toggleFocus() {
        settings.focusOnApproval.toggle()
    }

    @objc private func toggleSound() {
        settings.soundsEnabled.toggle()
        Chiptune.shared.enabled = settings.soundsEnabled
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuild on open so checkmarks and install/remove entries are never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}

let app = NSApplication.shared

if let index = CommandLine.arguments.firstIndex(of: "--codex-sessions") {
    app.setActivationPolicy(.prohibited)
    let minutes = index + 1 < CommandLine.arguments.count
        ? Double(CommandLine.arguments[index + 1]) ?? 30 : 30
    CodexSessionWatcher.dump(minutes: minutes)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--conductor-sessions") {
    app.setActivationPolicy(.prohibited)
    let minutes = index + 1 < CommandLine.arguments.count
        ? Double(CommandLine.arguments[index + 1]) ?? 60 : 60
    ConductorSessionWatcher.dump(minutes: minutes)
    exit(0)
}

if CommandLine.arguments.contains("--logos") {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { PreviewRenderer.dumpLogos() }
    exit(0)
}

if CommandLine.arguments.contains("--geometry") {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { PreviewRenderer.dumpGeometry() }
    exit(0)
}

// Offscreen render mode — see PreviewRenderer. Must run before the app loop.
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   index + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    let collapsed = CommandLine.arguments.contains("--collapsed")
    MainActor.assumeIsolated {
        PreviewRenderer.render(to: CommandLine.arguments[index + 1],
                               collapsed: collapsed,
                               dormant: CommandLine.arguments.contains("--dormant"),
                               tab: CommandLine.arguments.contains("--usage") ? .usage : .sessions)
    }
    exit(0)
}

// Top-level code already runs on the main thread; assert that for the compiler.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// Accessory: no Dock icon, no menu bar takeover — the island is the whole UI.
app.setActivationPolicy(.accessory)
app.run()

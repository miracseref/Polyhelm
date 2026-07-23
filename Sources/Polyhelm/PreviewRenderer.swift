import AppKit
import SwiftUI

/// Renders the island offscreen to a PNG.
///
/// `Polyhelm --render-preview <path> [--collapsed]`
///
/// This exists because the app is an `LSUIElement` overlay: it cannot be
/// screenshotted by the usual tooling, so without this there is no way to check
/// a layout change short of asking a human to look. It hosts the real view tree
/// in a real `NSHostingView`, so `NSViewRepresentable` sizing bugs show up here
/// exactly as they do on screen.
@MainActor
enum PreviewRenderer {
    static func render(to path: String, collapsed: Bool, dormant: Bool = false,
                       tab: SessionStore.Tab = .sessions) {
        let store = SessionStore()
        if !dormant { populate(store) }
        store.isExpanded = !collapsed
        store.tab = tab

        // Real measurements from a 14" MacBook Pro: 771 + 185 + 772 = 1728.
        let geometry = NotchGeometry(notchWidth: 185, notchHeight: 32, hasRealNotch: true,
                                     screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        // Dormant means no wings at all: the island *is* the notch.
        let collapsedWidth = geometry.notchWidth
            + (dormant ? 0 : 2 * geometry.wingWidth)
        let view = NotchView(geometry: geometry)
            .environmentObject(store)
            .frame(width: collapsed ? collapsedWidth : geometry.expandedWidth)
            // Opaque backdrop: materials render as clear in an offscreen cache,
            // which would make the capture unreadable.
            .background(Color(white: 0.07))

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0,
                               width: collapsed ? collapsedWidth : geometry.expandedWidth,
                               height: collapsed ? geometry.notchHeight : 620)
        hosting.layoutSubtreeIfNeeded()

        // A window is required for the view to lay out and draw like it does live.
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.displayIfNeeded()

        let size = hosting.fittingSize
        let height = collapsed ? geometry.notchHeight : min(max(size.height, 200), 700)
        // Pin the width: NSHostingView will grow past what we asked for if any
        // subview overflows its frame, which is exactly the bug worth catching.
        let intended = collapsed ? collapsedWidth : geometry.expandedWidth
        hosting.frame = NSRect(x: 0, y: 0, width: intended, height: height)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let natural = hosting.fittingSize.width
        if collapsed && natural > intended + 0.5 {
            let warning = "OVERFLOW: content wants \(Int(natural))pt "
                + "but the island is \(Int(intended))pt — a wing exceeds its frame\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("could not allocate bitmap\n".utf8))
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write(
            Data("rendered \(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)) -> \(path)\n".utf8)
        )
    }

    /// Reports where each brand's mark is coming from.
    static func dumpLogos() {
        for brand in AgentBrand.allCases where brand != .unknown {
            let name = brand.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)
            let origin = LogoLocator.origin(for: brand).padding(toLength: 22, withPad: " ", startingAt: 0)
            if let image = LogoLocator.image(for: brand) {
                print("\(name)\(origin)\(Int(image.size.width))x\(Int(image.size.height))")
            } else {
                print("\(name)\(origin)(shape drawn in code)")
            }
        }
    }

    /// Prints exactly what the app measures for every attached display.
    static func dumpGeometry() {
        for screen in NSScreen.screens {
            let frame = screen.frame
            let left = screen.auxiliaryTopLeftArea
            let right = screen.auxiliaryTopRightArea
            let measured = NotchGeometry.measure(screen)
            let leftText = left.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
            let rightText = right.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
            print(screen.localizedName
                  + "  \(Int(frame.width))x\(Int(frame.height))"
                  + " @(\(Int(frame.minX)),\(Int(frame.minY)))")
            print("  backingScale    \(screen.backingScaleFactor)")
            print("  safeArea.top    \(screen.safeAreaInsets.top)")
            print("  auxTopLeft      \(leftText)")
            print("  auxTopRight     \(rightText)")
            print("  => notch        \(measured.notchWidth) x \(measured.notchHeight)"
                  + "  real=\(measured.hasRealNotch)")
            print("  => wing         \(Int(measured.wingWidth))")
            print("  => collapsed    \(Int(measured.notchWidth + 2 * measured.wingWidth)) wide"
                  + "   dormant \(Int(measured.notchWidth))")
            print("  => expanded     \(Int(measured.expandedWidth))"
                  + "   canvas \(Int(measured.canvas.width))x\(Int(measured.canvas.height))")
            print("  => islandTop    \(Int(measured.islandTop))"
                  + (measured.hasRealNotch ? "  (in the notch)" : "  (below menu bar)"))
        }
    }

    /// A representative mix: several states, a long detail line, a session with
    /// no terminal, and a pending approval.
    private static func populate(_ store: SessionStore) {
        let iterm = TerminalRef(app: "iTerm.app", tty: "/dev/ttys004")
        let none = TerminalRef()

        store.upsert(id: "a", agent: "Claude Code", cwd: "/Users/me/code/api-server",
                     terminal: iterm, state: .working,
                     detail: "Read ~/conductor/frames/frame8.jpg")
        store.upsert(id: "b", agent: "Codex", cwd: "/Users/me/code/brazzaville",
                     terminal: iterm, state: .working, detail: "TaskUpdate")
        store.upsert(id: "c", agent: "Claude Code", cwd: "/Users/me/code/landing",
                     terminal: none, state: .done,
                     detail: "Waiting for your next message")
        store.upsert(id: "d", agent: "Gemini", cwd: "/Users/me/code/infra",
                     terminal: iterm, state: .error, detail: "Command failed with exit 1")
        // A session blocked on a question — exercises the inline answer box.
        store.upsert(id: "e", agent: "Claude Code", cwd: "/Users/me/code/payments",
                     terminal: iterm, state: .needsInput,
                     detail: "Should I also migrate the legacy webhook handlers?")

        // A Claude Code agent running inside Conductor: branded as Claude Code,
        // labelled by its branch, no terminal but the Conductor app to jump to.
        // Injected the way the real watcher does, so it exercises the row exactly.
        store.syncWatched(prefix: ConductorSessionWatcher.idPrefix, sessions: [
            AgentSession(id: ConductorSessionWatcher.idPrefix + "x",
                         agent: "Claude Code",
                         cwd: "/Users/me/conductor/workspaces/halisbayancuk/accra",
                         state: .working,
                         detail: "opus-4-8-1m  ·  10% ctx",
                         terminal: TerminalRef(desktopApp: "com.conductor.app"),
                         updatedAt: Date(), startedAt: Date(),
                         title: "geoblocked-youtube-modal")
        ])
    }
}

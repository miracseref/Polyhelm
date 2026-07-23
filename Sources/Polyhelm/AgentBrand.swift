import AppKit
import SwiftUI

/// The coding harnesses Polyhelm knows about.
enum AgentBrand: String, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case gemini
    case cursor
    case opencode
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .gemini:     return "Gemini"
        case .cursor:     return "Cursor"
        case .opencode:   return "opencode"
        case .unknown:    return "Agent"
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.30)  // terracotta
        case .codex:      return Color(red: 0.35, green: 0.85, blue: 0.70)
        case .gemini:     return Color(red: 0.40, green: 0.60, blue: 0.98)
        case .cursor:     return Color(red: 0.75, green: 0.75, blue: 0.80)
        case .opencode:   return Color(red: 0.95, green: 0.75, blue: 0.35)
        case .unknown:    return Color(white: 0.6)
        }
    }

    /// Maps whatever the hook reported (`TERM_PROGRAM`-adjacent free text) onto a brand.
    static func infer(from name: String) -> AgentBrand {
        let key = name.lowercased()
        if key.contains("claude") { return .claudeCode }
        if key.contains("codex") || key.contains("openai") { return .codex }
        if key.contains("gemini") || key.contains("antigravity") { return .gemini }
        if key.contains("cursor") { return .cursor }
        if key.contains("opencode") { return .opencode }
        return .unknown
    }

    /// How to find this brand's own mark among the files its app ships.
    ///
    /// These are the vendors' real logos, read from their own installed apps —
    /// preferred over an app icon because they are bare glyphs with no macOS
    /// squircle baked in.
    var vendorAssets: [AssetRule] {
        switch self {
        case .codex:
            // OpenAI's mark, shipped as vector inside the ChatGPT extension.
            return [.glob("~/.cursor/extensions/openai.chatgpt-*/resources/blossom-white.svg"),
                    .glob("~/.vscode/extensions/openai.chatgpt-*/resources/blossom-white.svg")]
        case .claudeCode:
            // Claude.app ships the burst as a lone 248x248 path, under a
            // content-hashed filename that changes with every release — so match
            // on the shape of the file rather than its name.
            return [.svgMatching(
                directory: "/Applications/Claude.app/Contents/Resources/ion-dist/assets/v1",
                viewBox: "0 0 248 248",
                maxPaths: 1)]
        case .gemini, .cursor, .opencode, .unknown:
            return []
        }
    }

    /// Installed applications whose icon is this brand's mark.
    var iconApps: [String] {
        switch self {
        case .claudeCode: return ["/Applications/Claude.app"]
        case .codex:      return ["/Applications/ChatGPT.app"]
        case .cursor:     return ["/Applications/Cursor.app"]
        case .gemini:     return ["/Applications/Antigravity.app", "/Applications/Gemini.app"]
        case .opencode:   return []
        case .unknown:    return []
        }
    }
}

/// Resolves a real logo for a brand, or nothing.
///
/// Nothing is bundled into the binary. Every image is discovered on the machine
/// the app is running on — either supplied by the user or shipped by the vendor's
/// own installed app — so Polyhelm never redistributes anyone's trademark, and a
/// machine without a given harness installed simply falls back to plain geometry.
@MainActor
enum LogoLocator {
    private static var cache: [AgentBrand: NSImage?] = [:]

    static var overridesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".polyhelm/logos")
    }

    static func image(for brand: AgentBrand) -> NSImage? {
        if let cached = cache[brand] { return cached }
        let resolved = resolve(brand)
        cache[brand] = resolved
        return resolved
    }

    /// Call after dropping new files into the overrides directory.
    static func invalidate() { cache.removeAll() }

    /// Reports where each brand's mark came from, for `--logos`.
    static func origin(for brand: AgentBrand) -> String {
        for ext in ["svg", "pdf", "png", "jpg"] {
            let url = overridesDirectory.appendingPathComponent("\(brand.rawValue).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return "user override" }
        }
        if bundledImage(for: brand) != nil { return "bundled in app" }
        for rule in brand.vendorAssets where rule.resolve() != nil { return "vendor asset on disk" }
        for path in brand.iconApps where FileManager.default.fileExists(atPath: path) {
            return "installed app icon"
        }
        return "drawn fallback"
    }

    private static func bundledImage(for brand: AgentBrand) -> NSImage? {
        for ext in ["svg", "pdf", "png"] {
            if let url = Bundle.main.url(forResource: brand.rawValue,
                                         withExtension: ext,
                                         subdirectory: "Logos"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private static func resolve(_ brand: AgentBrand) -> NSImage? {
        // 1. Anything the user dropped in wins outright.
        for ext in ["svg", "pdf", "png", "jpg"] {
            let url = overridesDirectory.appendingPathComponent("\(brand.rawValue).\(ext)")
            if let image = NSImage(contentsOf: url) { return image }
        }
        // 2. Artwork bundled into the app at build time, from the repo's Logos/
        //    folder. Empty by default — see Logos/README.md before filling it, as
        //    shipping someone else's logo is a licensing decision, not a technical
        //    one. This is what makes marks available on a Mac that has none of the
        //    harnesses installed.
        if let bundled = bundledImage(for: brand) { return bundled }
        // 3. A vendor's own asset file, which is usually a clean bare mark.
        for rule in brand.vendorAssets {
            if let url = rule.resolve(), let image = NSImage(contentsOf: url) {
                return image
            }
        }
        // 4. The installed app's icon. Recognisable, though it carries the
        //    macOS squircle rather than the bare glyph.
        for path in brand.iconApps where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }

}

/// A way of locating a vendor's logo file on disk.
enum AssetRule {
    /// A path with at most one `*` component. `~` expands to the home directory.
    case glob(String)
    /// Any SVG in `directory` whose header declares `viewBox` and contains no
    /// more than `maxPaths` paths — for assets shipped under hashed filenames.
    case svgMatching(directory: String, viewBox: String, maxPaths: Int)

    func resolve() -> URL? {
        switch self {
        case .glob(let pattern):    return Self.resolveGlob(pattern)
        case .svgMatching(let directory, let viewBox, let maxPaths):
            return Self.resolveSVG(directory, viewBox, maxPaths)
        }
    }

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }

    /// Picks the last match so the newest versioned directory wins.
    private static func resolveGlob(_ pattern: String) -> URL? {
        let full = expand(pattern)
        guard full.contains("*") else {
            return FileManager.default.fileExists(atPath: full)
                ? URL(fileURLWithPath: full) : nil
        }
        var components = full.split(separator: "/").map(String.init)
        var base = URL(fileURLWithPath: "/")
        while let next = components.first, !next.contains("*") {
            base.appendPathComponent(next)
            components.removeFirst()
        }
        guard let wildcard = components.first else { return nil }
        let remainder = components.dropFirst().joined(separator: "/")
        let prefix = wildcard.replacingOccurrences(of: "*", with: "")

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for entry in entries.filter({ $0.hasPrefix(prefix) }).sorted().reversed() {
            let url = base.appendingPathComponent(entry).appendingPathComponent(remainder)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func resolveSVG(_ directory: String,
                                   _ viewBox: String,
                                   _ maxPaths: Int) -> URL? {
        let root = URL(fileURLWithPath: expand(directory))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries.filter({ $0.hasSuffix(".svg") }).sorted() {
            let url = root.appendingPathComponent(entry)
            // These files are small; reading them whole is cheaper than being clever.
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("viewBox=\"\(viewBox)\""),
                  text.components(separatedBy: "<path").count - 1 <= maxPaths
            else { continue }
            return url
        }
        return nil
    }
}

/// A small brand mark for an agent.
///
/// Ships geometric stand-ins rather than redrawn corporate logos — those are
/// trademarks, and baking approximations of them into a distributed binary is
/// not something to do casually. `~/.polyhelm/logos/<brand>.png` overrides.
struct AgentMark: View {
    let brand: AgentBrand
    var size: CGFloat = 13

    var body: some View {
        Group {
            if let artwork = LogoLocator.image(for: brand) {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // App icons are squircles; rounding keeps them from reading
                    // as a hard square inside the round badge.
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22,
                                                style: .continuous))
            } else {
                shape
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var shape: some View {
        switch brand {
        case .claudeCode:
            BurstMark().stroke(brand.tint, style: .init(lineWidth: size * 0.13, lineCap: .round))
        case .codex:
            RingMark().stroke(brand.tint, lineWidth: size * 0.13)
        case .gemini:
            SparkMark().fill(brand.tint)
        case .cursor:
            TriangleMark().stroke(brand.tint, style: .init(lineWidth: size * 0.12, lineJoin: .round))
        case .opencode:
            RoundedRectangle(cornerRadius: size * 0.24)
                .stroke(brand.tint, lineWidth: size * 0.13)
        case .unknown:
            Circle().stroke(brand.tint, lineWidth: size * 0.12)
        }
    }
}

/// Radial spokes.
private struct BurstMark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        return Path { path in
            for index in 0..<6 {
                let angle = Double(index) * .pi / 3
                path.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.32,
                                      y: center.y + sin(angle) * radius * 0.32))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * radius,
                                         y: center.y + sin(angle) * radius))
            }
        }
    }
}

/// Hexagonal ring.
private struct RingMark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        return Path { path in
            for index in 0..<6 {
                let angle = Double(index) * .pi / 3 - .pi / 2
                let point = CGPoint(x: center.x + cos(angle) * radius,
                                    y: center.y + sin(angle) * radius)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.closeSubpath()
        }
    }
}

/// Four-point star built from concave curves.
private struct SparkMark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        return Path { path in
            path.move(to: CGPoint(x: center.x, y: center.y - radius))
            for index in 0..<4 {
                let next = Double(index + 1) * .pi / 2 - .pi / 2
                let end = CGPoint(x: center.x + cos(next) * radius,
                                  y: center.y + sin(next) * radius)
                path.addQuadCurve(to: end, control: center)
            }
            path.closeSubpath()
        }
    }
}

/// Upward chevron / prism outline.
private struct TriangleMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

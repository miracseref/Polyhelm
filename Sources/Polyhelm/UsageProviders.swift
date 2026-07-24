import Foundation
import Security

/// One harness's usage picture.
///
/// Several very different things live here and they must not be conflated:
/// `quota` is what the *server* told the harness — authoritative, a real
/// percentage of a real limit. `measured` is what we counted from local logs —
/// accurate about spend, but it knows no ceiling. `activity` is the weakest
/// signal of all: for harnesses whose logs are opaque blobs, it's file
/// timestamps standing in for "this got used." A harness may report any mix.
struct UsageReport: Identifiable {
    /// A real server-reported ceiling. A harness may enforce several windows at
    /// once (a 5-hour session cap and a rolling weekly cap, plus per-model caps),
    /// so this holds one or more, each with its own percentage and reset.
    struct Quota {
        struct Window: Identifiable {
            /// Descriptive name for named windows (Claude's "All models", "Fable").
            /// Empty for Codex, whose windows are identified only by length.
            var name: String
            var usedPercent: Double
            var windowMinutes: Int
            var resetsAt: Date?
            var id: String { name.isEmpty ? "w\(windowMinutes)" : name }
        }

        var windows: [Window]
        var planType: String?

        static func windowLabel(minutes: Int) -> String {
            switch minutes {
            case ..<1:       return ""
            case ..<60:      return "\(minutes)m"
            case ..<1440:    return "\(minutes / 60)h"
            case 10080:      return "week"
            default:         return "\(minutes / 1440)d"
            }
        }

        /// The window under the most pressure — what the headline chip and the
        /// switcher dot should reflect, since it's the one that will bite first.
        var peak: Window {
            windows.max { $0.usedPercent < $1.usedPercent }
                ?? Window(name: "", usedPercent: 0, windowMinutes: 0, resetsAt: nil)
        }
        var usedPercent: Double { peak.usedPercent }
        var windowLabel: String { Self.windowLabel(minutes: peak.windowMinutes) }
        var resetsAt: Date? { peak.resetsAt }
    }

    struct Measured {
        var messages: Int
        var inputTokens: Int
        var cacheReadTokens: Int
        var outputTokens: Int
        var resetsAt: Date?
        var models: Set<String>
        var tokensByModel: [String: Int] = [:]

        /// Cache reads are an order of magnitude cheaper, so the headline number
        /// leaves them out — including them overstates consumption enormously.
        var billableTokens: Int { inputTokens + outputTokens }
    }

    /// For harnesses whose logs we can't read, usage inferred from file
    /// timestamps: how many sessions and when the newest one was touched.
    struct Activity {
        var count: Int
        var noun: String
        var lastActive: Date?
    }

    /// Rolling 7-day totals, shown alongside the current-window figure.
    struct Week {
        var tokens: Int
        var messages: Int
    }

    let brand: AgentBrand
    var quota: Quota?
    var measured: Measured?
    var activity: Activity?
    var week: Week?
    /// Set when the harness is installed but exposes nothing we can read.
    var note: String?

    var id: String { brand.rawValue }
    var hasAnything: Bool { quota != nil || measured != nil || activity != nil }
}

protocol UsageProvider: Sendable {
    var brand: AgentBrand { get }
    /// Runs off the main thread. Returns nil when the harness isn't installed.
    func read(since cutoff: Date) -> UsageReport?
}

// MARK: - Codex

/// Parsed-rollout cache. Confined to `UsageTracker.queue` (the same serial queue
/// every provider's `read` runs on), never shared — same pattern as
/// `TranscriptCache`. A session's `~190 MB` of history across 65 files makes an
/// mtime cache mandatory: re-parsing every refresh would stall the scan.
private final class RolloutCache: @unchecked Sendable {
    struct Digest {
        var modified: Date
        var input: Int
        var cacheRead: Int
        var output: Int
        var messages: Int
        var quota: UsageReport.Quota?
    }
    var entries: [String: Digest] = [:]

    func prune(keeping livePaths: Set<String>) {
        entries = entries.filter { livePaths.contains($0.key) }
    }
}

/// Reads every `~/.codex/sessions/**/rollout-*.jsonl` touched in the window.
///
/// Codex is the one harness here that persists the server's own rate-limit
/// response, so this reports a true percentage rather than a local estimate.
/// Token totals are summed across every session in the window; the quota is
/// taken from whichever session was written most recently.
struct CodexUsageProvider: UsageProvider {
    let brand = AgentBrand.codex
    private let cache = RolloutCache()

    func read(since cutoff: Date) -> UsageReport? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var digests: [RolloutCache.Digest] = []
        var livePaths = Set<String>()

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, modified >= cutoff else { continue }
            livePaths.insert(url.path)

            // Rollout files are append-only, so an unchanged mtime means last
            // time's digest is still exact — this is what keeps 190 MB cheap.
            if let hit = cache.entries[url.path], hit.modified == modified {
                digests.append(hit)
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var digest = RolloutCache.Digest(modified: modified, input: 0, cacheRead: 0,
                                             output: 0, messages: 0, quota: nil)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.contains("\"token_count\"") {
                    guard let data = line.data(using: .utf8),
                          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let payload = record["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count"
                    else { continue }

                    // total_token_usage is cumulative within a session, so the
                    // last one wins — overwrite, don't accumulate. output_tokens
                    // already includes reasoning_output_tokens; don't add it.
                    if let info = payload["info"] as? [String: Any],
                       let total = info["total_token_usage"] as? [String: Any] {
                        digest.input = total["input_tokens"] as? Int ?? digest.input
                        digest.cacheRead = total["cached_input_tokens"] as? Int ?? digest.cacheRead
                        digest.output = total["output_tokens"] as? Int ?? digest.output
                    }
                    if let limits = payload["rate_limits"] as? [String: Any],
                       let primary = limits["primary"] as? [String: Any],
                       let percent = primary["used_percent"] as? Double {
                        func window(_ dict: [String: Any]?, percent: Double) -> UsageReport.Quota.Window {
                            .init(name: "", usedPercent: percent,
                                  windowMinutes: dict?["window_minutes"] as? Int ?? 0,
                                  resetsAt: (dict?["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
                        }
                        var windows = [window(primary, percent: percent)]
                        if let secondary = limits["secondary"] as? [String: Any],
                           let sp = secondary["used_percent"] as? Double {
                            windows.append(window(secondary, percent: sp))
                        }
                        digest.quota = UsageReport.Quota(windows: windows,
                                                         planType: limits["plan_type"] as? String)
                    }
                } else if line.contains("\"agent_message\"") {
                    guard let data = line.data(using: .utf8),
                          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          record["type"] as? String == "event_msg",
                          let payload = record["payload"] as? [String: Any],
                          payload["type"] as? String == "agent_message"
                    else { continue }
                    digest.messages += 1
                }
            }
            cache.entries[url.path] = digest
            digests.append(digest)
        }
        cache.prune(keeping: livePaths)

        guard !digests.isEmpty else {
            return UsageReport(brand: brand, note: "No Codex sessions in the last 7 days")
        }

        var measured = UsageReport.Measured(messages: 0, inputTokens: 0, cacheReadTokens: 0,
                                            outputTokens: 0, resetsAt: nil, models: [])
        for digest in digests {
            measured.inputTokens += digest.input
            measured.cacheReadTokens += digest.cacheRead
            measured.outputTokens += digest.output
            measured.messages += digest.messages
        }
        // Quota of the freshest session that carried one — a stale file's
        // percentage would understate the real figure.
        let quota = digests.filter { $0.quota != nil }
            .max(by: { $0.modified < $1.modified })?.quota

        let hasSpend = measured.inputTokens + measured.outputTokens
            + measured.cacheReadTokens + measured.messages > 0
        guard quota != nil || hasSpend else {
            return UsageReport(brand: brand, note: "No usage recorded yet")
        }
        return UsageReport(brand: brand, quota: quota, measured: hasSpend ? measured : nil)
    }
}

// MARK: - opencode

/// Reads `~/.local/share/opencode/storage/message/**/*.json` — opencode's
/// message-v2 format, one small immutable file per message. These are tiny and
/// never rewritten, so no mtime cache is needed.
struct OpenCodeUsageProvider: UsageProvider {
    let brand = AgentBrand.opencode

    func read(since cutoff: Date) -> UsageReport? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let messages = home.appendingPathComponent(".local/share/opencode/storage/message")
        let config = home.appendingPathComponent(".config/opencode")
        let fm = FileManager.default

        guard fm.fileExists(atPath: messages.path) else {
            // Installed (config present) but never run, vs. not installed at all.
            return fm.fileExists(atPath: config.path)
                ? UsageReport(brand: brand, note: "Installed — no sessions recorded yet")
                : nil
        }
        guard let walker = fm.enumerator(
            at: messages, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var measured = UsageReport.Measured(messages: 0, inputTokens: 0, cacheReadTokens: 0,
                                            outputTokens: 0, resetsAt: nil, models: [])

        for case let url as URL in walker {
            guard url.pathExtension == "json" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified >= cutoff else { continue }

            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["role"] as? String == "assistant",
                  let tokens = record["tokens"] as? [String: Any]
            else { continue }   // skip older v1 messages and non-assistant rows

            // Prefer the message's own timestamp (epoch millis) over mtime.
            if let time = record["time"] as? [String: Any],
               let created = (time["created"] as? NSNumber)?.doubleValue,
               Date(timeIntervalSince1970: created / 1000) < cutoff { continue }

            let cache = tokens["cache"] as? [String: Any] ?? [:]
            let int: (Any?) -> Int = { ($0 as? NSNumber)?.intValue ?? 0 }
            // opencode reports reasoning separately from output; cache write is a
            // form of input, cache read is billed like Claude's cache reads.
            let input = int(tokens["input"]) + int(cache["write"])
            let output = int(tokens["output"]) + int(tokens["reasoning"])

            measured.inputTokens += input
            measured.cacheReadTokens += int(cache["read"])
            measured.outputTokens += output
            measured.messages += 1
            if let model = record["modelID"] as? String {
                measured.models.insert(model)
                measured.tokensByModel[model, default: 0] += input + output
            }
        }

        guard measured.messages > 0 else {
            return UsageReport(brand: brand, note: "No opencode sessions in the last 7 days")
        }
        return UsageReport(brand: brand, measured: measured)
    }
}

// MARK: - Activity-only harnesses

/// For harnesses whose logs are opaque (Antigravity protobufs, Cursor SQLite
/// blobs), the only honest signal is "something happened, and when." This counts
/// matching files touched in the window and reports the count plus last-active,
/// making clear in the note why no tokens are shown.
struct ActivityUsageProvider: UsageProvider {
    enum Counter {
        case filesWithExtension(subpath: String, ext: String)
        case filesNamed(subpath: String, name: String)
    }

    let brand: AgentBrand
    let probePath: String
    let noun: String
    let counters: [Counter]
    let reason: String

    func read(since cutoff: Date) -> UsageReport? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(probePath).path)
        else { return nil }

        var count = 0
        var lastActive: Date?
        for counter in counters {
            let (subpath, matches): (String, (URL) -> Bool)
            switch counter {
            case let .filesWithExtension(sub, ext):
                subpath = sub; matches = { $0.pathExtension == ext }
            case let .filesNamed(sub, name):
                subpath = sub; matches = { $0.lastPathComponent == name }
            }
            let root = home.appendingPathComponent(subpath)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard matches(url) else { continue }
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, modified >= cutoff else { continue }
                count += 1
                if lastActive == nil || modified > lastActive! { lastActive = modified }
            }
        }

        guard count > 0 else {
            return UsageReport(brand: brand, note: "No activity in the last 7 days")
        }
        return UsageReport(brand: brand,
                           activity: .init(count: count, noun: noun, lastActive: lastActive),
                           note: reason)
    }
}

// MARK: - Claude Code server quota

/// Claude Code keeps no quota on disk — the `/usage` panel is fetched live. So,
/// like the CLI itself, this reads the OAuth token from the login Keychain and
/// asks Anthropic's usage endpoint for the real percentages.
///
/// This is the one thing in Polyhelm that leaves the machine: it sends the
/// user's own token to Anthropic's own endpoint (the same request `/usage`
/// makes) and nowhere else. The token is held only for the call — never logged,
/// never written. Any failure (no token, expired, offline, endpoint change)
/// returns nil so the caller falls back to locally-measured tokens. A last-good
/// result is reused briefly so a transient blip doesn't blank the panel.
///
/// Confined to `UsageTracker.queue`; the network call blocks that background
/// queue on a semaphore, which is fine — it never touches the main thread.
final class ClaudeQuotaReader: @unchecked Sendable {
    /// Why a fetch didn't yield a quota, so the panel can explain itself rather
    /// than silently showing "no quota".
    enum Outcome {
        case ok(UsageReport.Quota)
        /// A token exists but is expired or was rejected — the user can fix this
        /// by running Claude Code, which refreshes it.
        case stale
        /// No token, offline, or an unreadable response — nothing to say; the
        /// panel just falls back to locally-measured tokens.
        case none
    }

    private var cached: UsageReport.Quota?
    private var cachedAt: Date?
    private let staleAfter: TimeInterval = 10 * 60

    func fetch() -> Outcome {
        let outcome = fetchLive()
        if case .ok(let quota) = outcome {
            cached = quota
            cachedAt = Date()
            return outcome
        }
        // Ride a transient expiry/outage on the last good reading — the numbers
        // barely move minute to minute, so a brief blip shouldn't blank the bars.
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < staleAfter {
            return .ok(cached)
        }
        return outcome
    }

    private struct Credentials { var token: String; var planType: String? }
    private enum CredentialState { case ok(Credentials); case expired; case missing }

    /// Pulls `claudeAiOauth` out of the `Claude Code-credentials` Keychain item.
    /// Distinguishes expired (actionable) from missing/unreadable (stay quiet) —
    /// refreshing would mean writing the user's credentials, which we never do.
    private func credentials() -> CredentialState {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return .missing }

        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiresAt / 1000) <= Date() {
            return .expired   // Claude Code will refresh it on its next run
        }
        return .ok(Credentials(token: token, planType: Self.planLabel(
            tier: oauth["rateLimitTier"] as? String,
            subscription: oauth["subscriptionType"] as? String)))
    }

    private static func planLabel(tier: String?, subscription: String?) -> String? {
        if let tier {
            if tier.contains("max_20x") { return "Max (20x)" }
            if tier.contains("max_5x")  { return "Max (5x)" }
        }
        if let subscription, !subscription.isEmpty { return subscription.capitalized }
        return nil
    }

    private func fetchLive() -> Outcome {
        let creds: Credentials
        switch credentials() {
        case .ok(let value): creds = value
        case .expired:       return .stale
        case .missing:       return .none
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Kept short: this blocks the background refresh, and the stale-cache
        // covers any gap, so an outage mustn't stall the panel for long.
        request.timeoutInterval = 8

        let semaphore = DispatchSemaphore(value: 0)
        var body: Data?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 9) == .success else { return .none }

        // 401 means the token was rejected despite looking unexpired — treat it
        // like an expired token so the panel still nudges the user to refresh.
        if status == 401 { return .stale }
        guard status == 200, let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .none }

        let windows = Self.parseWindows(json)
        guard !windows.isEmpty else { return .none }
        return .ok(UsageReport.Quota(windows: windows, planType: creds.planType))
    }

    /// The response carries a normalized `limits` array — one entry per enforced
    /// window (session, weekly-all, per-model weekly) — which maps straight onto
    /// our windows. Falls back to the flat `five_hour`/`seven_day` fields.
    private static func parseWindows(_ json: [String: Any]) -> [UsageReport.Quota.Window] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ any: Any?) -> Date? {
            guard let string = any as? String else { return nil }
            return iso.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }

        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.compactMap { limit in
                guard let percent = (limit["percent"] as? NSNumber)?.doubleValue else { return nil }
                let kind = limit["kind"] as? String ?? ""
                let name: String, minutes: Int
                switch kind {
                case "session":
                    name = "Current session"; minutes = 300
                case "weekly_all":
                    name = "All models"; minutes = 10080
                case "weekly_scoped":
                    let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                    name = model?["display_name"] as? String ?? "Scoped model"; minutes = 10080
                default:
                    name = kind.replacingOccurrences(of: "_", with: " ").capitalized; minutes = 0
                }
                return .init(name: name, usedPercent: percent, windowMinutes: minutes,
                             resetsAt: date(limit["resets_at"]))
            }
        }

        var windows: [UsageReport.Quota.Window] = []
        func flat(_ key: String, _ name: String, _ minutes: Int) {
            guard let block = json[key] as? [String: Any],
                  let percent = (block["utilization"] as? NSNumber)?.doubleValue else { return }
            windows.append(.init(name: name, usedPercent: percent, windowMinutes: minutes,
                                 resetsAt: date(block["resets_at"])))
        }
        flat("five_hour", "Current session", 300)
        flat("seven_day", "All models", 10080)
        return windows
    }
}

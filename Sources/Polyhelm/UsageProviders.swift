import Foundation

/// One harness's usage picture.
///
/// Two very different things live here and they must not be conflated:
/// `quota` is what the *server* told the harness — authoritative, a real
/// percentage of a real limit. `measured` is what we counted from local logs —
/// accurate about spend, but it knows no ceiling. A harness may report either,
/// both, or neither.
struct UsageReport: Identifiable {
    struct Quota {
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date?
        var planType: String?
        var secondaryPercent: Double?
        var secondaryWindowMinutes: Int?

        var windowLabel: String {
            switch windowMinutes {
            case ..<60:      return "\(windowMinutes)m"
            case ..<1440:    return "\(windowMinutes / 60)h"
            case 10080:      return "week"
            default:         return "\(windowMinutes / 1440)d"
            }
        }
    }

    struct Measured {
        var messages: Int
        var inputTokens: Int
        var cacheReadTokens: Int
        var outputTokens: Int
        var resetsAt: Date?
        var models: Set<String>

        /// Cache reads are an order of magnitude cheaper, so the headline number
        /// leaves them out — including them overstates consumption enormously.
        var billableTokens: Int { inputTokens + outputTokens }
    }

    let brand: AgentBrand
    var quota: Quota?
    var measured: Measured?
    /// Set when the harness is installed but exposes nothing we can read.
    var note: String?

    var id: String { brand.rawValue }
    var hasAnything: Bool { quota != nil || measured != nil }
}

protocol UsageProvider: Sendable {
    var brand: AgentBrand { get }
    /// Runs off the main thread. Returns nil when the harness isn't installed.
    func read(since cutoff: Date) -> UsageReport?
}

// MARK: - Codex

/// Reads `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Codex is the one harness here that persists the server's own rate-limit
/// response, so this reports a true percentage rather than a local estimate.
struct CodexUsageProvider: UsageProvider {
    let brand = AgentBrand.codex

    func read(since cutoff: Date) -> UsageReport? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        // Only the freshest token_count matters — it carries the newest quota.
        guard let newest = newestSessionFile(under: root, since: cutoff) else {
            return UsageReport(brand: brand, note: "No Codex sessions in the last 7 days")
        }
        guard let text = try? String(contentsOf: newest, encoding: .utf8) else { return nil }

        var quota: UsageReport.Quota?
        var measured: UsageReport.Measured?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"token_count\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count"
            else { continue }

            if let limits = payload["rate_limits"] as? [String: Any],
               let primary = limits["primary"] as? [String: Any],
               let percent = primary["used_percent"] as? Double {
                let secondary = limits["secondary"] as? [String: Any]
                quota = UsageReport.Quota(
                    usedPercent: percent,
                    windowMinutes: primary["window_minutes"] as? Int ?? 0,
                    resetsAt: (primary["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                    planType: limits["plan_type"] as? String,
                    secondaryPercent: secondary?["used_percent"] as? Double,
                    secondaryWindowMinutes: secondary?["window_minutes"] as? Int
                )
            }
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                measured = UsageReport.Measured(
                    messages: 0,
                    inputTokens: total["input_tokens"] as? Int ?? 0,
                    cacheReadTokens: total["cached_input_tokens"] as? Int ?? 0,
                    outputTokens: total["output_tokens"] as? Int ?? 0,
                    resetsAt: nil,
                    models: []
                )
            }
            if quota != nil { break }   // newest wins
        }

        guard quota != nil || measured != nil else {
            return UsageReport(brand: brand, note: "No usage recorded yet")
        }
        return UsageReport(brand: brand, quota: quota, measured: measured)
    }

    private func newestSessionFile(under root: URL, since cutoff: Date) -> URL? {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

        var newest: (URL, Date)?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, modified >= cutoff else { continue }
            if newest == nil || modified > newest!.1 { newest = (url, modified) }
        }
        return newest?.0
    }
}

// MARK: - Harnesses with nothing readable

/// Installed but silent: no session logs we can parse, so say so rather than
/// showing a zero that looks like real information.
struct OpaqueUsageProvider: UsageProvider {
    let brand: AgentBrand
    let probePath: String
    let reason: String

    func read(since cutoff: Date) -> UsageReport? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(probePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UsageReport(brand: brand, note: reason)
    }
}

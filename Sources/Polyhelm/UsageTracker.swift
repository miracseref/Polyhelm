import Foundation

/// Measures Claude Code usage by reading the local transcripts in
/// `~/.claude/projects/**/*.jsonl`.
///
/// Important: these are *locally measured* numbers, not your account's quota.
/// The real ceiling lives server-side and depends on your plan, so nothing here
/// invents a percentage — it reports what was actually spent and when the
/// current 5-hour block resets.
@MainActor
final class UsageTracker: ObservableObject {
    struct Block {
        var startedAt: Date
        var resetsAt: Date
        var messages: Int
        var inputTokens: Int      // includes cache creation
        var cacheReadTokens: Int
        var outputTokens: Int
        var models: Set<String>
        var tokensByModel: [String: Int]

        /// Cache reads are an order of magnitude cheaper, so the headline number
        /// leaves them out — counting them would wildly overstate consumption.
        var billableTokens: Int { inputTokens + outputTokens }
    }

    @Published private(set) var currentBlock: Block?
    @Published private(set) var weekTokens: Int = 0
    @Published private(set) var weekMessages: Int = 0
    @Published private(set) var lastRefreshed: Date?
    /// Every harness we could find something for, Claude Code first.
    @Published private(set) var reports: [UsageReport] = []

    /// Harnesses other than Claude Code. Codex reports a real server quota;
    /// the rest are probed so we can say "installed, but nothing readable"
    /// instead of silently omitting them.
    private let providers: [any UsageProvider] = [
        CodexUsageProvider(),
        OpenCodeUsageProvider(),
        ActivityUsageProvider(
            brand: .gemini, probePath: ".gemini", noun: "conversations",
            counters: [.filesWithExtension(subpath: ".gemini/antigravity/conversations", ext: "pb"),
                       .filesNamed(subpath: ".gemini/tmp", name: "logs.json")],
            reason: "Antigravity stores conversations as protobuf — no readable token counts."),
        ActivityUsageProvider(
            brand: .cursor, probePath: ".cursor/chats", noun: "chats",
            counters: [.filesNamed(subpath: ".cursor/chats", name: "store.db")],
            reason: "Cursor chats are SQLite blobs with no usage fields.")
    ]

    /// Anthropic's usage window is 5 hours from your first message in it.
    private let blockLength: TimeInterval = 5 * 3600
    private let week: TimeInterval = 7 * 24 * 3600

    private var timer: Timer?
    private let queue = DispatchQueue(label: "polyhelm.usage", qos: .utility)
    private var isScanning = false
    /// Parsed samples per transcript, keyed by path. Only ever touched on `queue`.
    private let cache = TranscriptCache()
    /// Fetches Claude Code's real server quota. Only ever touched on `queue`.
    private let claudeQuota = ClaudeQuotaReader()

    init() {
        refresh()
        // Cheap enough to redo periodically; the mtime filter keeps it to a
        // handful of files even though the projects tree holds hundreds.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let cutoff = Date().addingTimeInterval(-week)
        let blockLength = self.blockLength

        let providers = self.providers

        queue.async { [weak self] in
            guard let self else { return }
            let samples = Self.scan(since: cutoff, cache: self.cache)
            let blocks = Self.group(samples, blockLength: blockLength)
            let weekTotal = samples.reduce(0) { $0 + $1.input + $1.output }
            let quota = self.claudeQuota.fetch()
            let others = providers.compactMap { $0.read(since: cutoff) }

            Task { @MainActor in
                // Only surface a block that hasn't expired yet.
                self.currentBlock = blocks.last.flatMap { $0.resetsAt > Date() ? $0 : nil }
                self.weekTokens = weekTotal
                self.weekMessages = samples.count
                self.lastRefreshed = Date()
                self.reports = self.claudeReport(blocks: blocks, weekTotal: weekTotal,
                                                 weekMessages: samples.count, quota: quota) + others
                self.isScanning = false
            }
        }
    }

    /// Claude Code now reports a real server quota when its OAuth token can be
    /// read, alongside the locally-measured 5-hour block and 7-day rollup. Any of
    /// the three may be absent — quota if offline/signed-out, measured if idle.
    private func claudeReport(blocks: [Block], weekTotal: Int, weekMessages: Int,
                              quota outcome: ClaudeQuotaReader.Outcome) -> [UsageReport] {
        // 7-day rollup rides along with the live figure, when there's anything to show.
        let week = weekMessages > 0 ? UsageReport.Week(tokens: weekTotal, messages: weekMessages) : nil
        let measured: UsageReport.Measured? = blocks.last.flatMap { block in
            block.resetsAt > Date()
                ? UsageReport.Measured(messages: block.messages,
                                       inputTokens: block.inputTokens,
                                       cacheReadTokens: block.cacheReadTokens,
                                       outputTokens: block.outputTokens,
                                       resetsAt: block.resetsAt,
                                       models: block.models,
                                       tokensByModel: block.tokensByModel)
                : nil
        }

        var quota: UsageReport.Quota?
        var note: String?
        switch outcome {
        case .ok(let value): quota = value
        case .stale:         note = "Claude Code's saved token has expired — run `claude` to refresh the quota."
        case .none:          break
        }
        // Only call it empty when there's genuinely nothing to show.
        if quota == nil && measured == nil && note == nil {
            note = "No messages in the last 5 hours"
        }
        return [UsageReport(brand: .claudeCode, quota: quota, measured: measured,
                            week: week, note: note)]
    }

    // MARK: - Scanning

    fileprivate struct Sample {
        var at: Date
        var input: Int
        var cacheRead: Int
        var output: Int
        var model: String
    }

    nonisolated private static func scan(since cutoff: Date, cache: TranscriptCache) -> [Sample] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles])
        else { return [] }

        var samples: [Sample] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            // Skip files untouched in the window — this is what keeps the scan cheap.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified >= cutoff else { continue }

            // Transcripts are append-only, so an unchanged mtime means the parse
            // from last time is still exact. This turns a ~2.5s rescan into ~0.
            if let hit = cache.entries[url.path], hit.modified == modified {
                samples.append(contentsOf: hit.samples.filter { $0.at >= cutoff })
                continue
            }

            var parsed: [Sample] = []
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // Cheap prefilter before paying for JSON parsing.
                guard line.contains("\"type\":\"assistant\""), line.contains("\"usage\"") else { continue }
                guard let data = line.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let stamp = record["timestamp"] as? String,
                      let at = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp),
                      at >= cutoff,
                      let message = record["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { continue }

                let input = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                parsed.append(Sample(at: at,
                                     input: input,
                                     cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                                     output: usage["output_tokens"] as? Int ?? 0,
                                     model: message["model"] as? String ?? "unknown"))
            }
            cache.entries[url.path] = TranscriptCache.Entry(modified: modified, samples: parsed)
            samples.append(contentsOf: parsed)
        }
        // Forget transcripts that have aged out, so the cache can't grow forever.
        cache.prune(olderThan: cutoff)
        return samples.sorted { $0.at < $1.at }
    }

    /// Walks the timeline splitting it into 5-hour blocks, each anchored on the
    /// first message that falls outside the previous one — which is how the
    /// rolling window actually behaves.
    nonisolated private static func group(_ samples: [Sample], blockLength: TimeInterval) -> [Block] {
        var blocks: [Block] = []
        for sample in samples {
            if var open = blocks.last, sample.at < open.resetsAt {
                open.messages += 1
                open.inputTokens += sample.input
                open.cacheReadTokens += sample.cacheRead
                open.outputTokens += sample.output
                open.models.insert(sample.model)
                open.tokensByModel[sample.model, default: 0] += sample.input + sample.output
                blocks[blocks.count - 1] = open
            } else {
                blocks.append(Block(startedAt: sample.at,
                                    resetsAt: sample.at.addingTimeInterval(blockLength),
                                    messages: 1,
                                    inputTokens: sample.input,
                                    cacheReadTokens: sample.cacheRead,
                                    outputTokens: sample.output,
                                    models: [sample.model],
                                    tokensByModel: [sample.model: sample.input + sample.output]))
            }
        }
        return blocks
    }
}

/// Parsed-transcript cache. Confined to `UsageTracker.queue`, never shared.
private final class TranscriptCache: @unchecked Sendable {
    struct Entry {
        var modified: Date
        var samples: [UsageTracker.Sample]
    }
    var entries: [String: Entry] = [:]

    func prune(olderThan cutoff: Date) {
        entries = entries.filter { $0.value.modified >= cutoff }
    }
}

extension Int {
    /// 1234 → "1.2k", 1234567 → "1.2M"
    var compactTokens: String {
        switch self {
        case 1_000_000...: return String(format: "%.1fM", Double(self) / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", Double(self) / 1_000)
        default:           return "\(self)"
        }
    }
}

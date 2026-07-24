import SwiftUI

/// Header chip: the single most urgent usage number across every harness.
/// Prefers a real server quota over a locally measured one, because only the
/// former means anything as a fraction.
struct UsageChip: View {
    @ObservedObject var usage: UsageTracker
    /// Switching to the Usage tab is the caller's job — the chip no longer owns
    /// a popover, which never reliably presented from a borderless non-key panel.
    var action: () -> Void = {}
    @State private var now = Date()

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var headline: UsageReport? {
        let quoted = usage.reports.filter { $0.quota != nil }
        if let worst = quoted.max(by: { ($0.quota?.usedPercent ?? 0) < ($1.quota?.usedPercent ?? 0) }) {
            return worst
        }
        return usage.reports.first { $0.measured != nil }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let report = headline {
                    AgentMark(brand: report.brand, size: 11)
                    if let quota = report.quota {
                        Text("\(Int(quota.usedPercent))%")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(UsageTint.of(quota.usedPercent))
                        Text(quota.windowLabel)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    } else if let measured = report.measured {
                        Text(measured.billableTokens.compactTokens)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                        if let resets = measured.resetsAt {
                            Text(Self.countdown(to: resets, from: now))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                } else {
                    Image(systemName: "gauge.medium")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("usage")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .onReceive(tick) { now = $0 }
        .help("Usage across every harness")
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let remaining = max(0, date.timeIntervalSince(now))
        let days = Int(remaining) / 86_400
        if days > 0 { return "\(days)d" }
        let hours = Int(remaining) / 3600, minutes = (Int(remaining) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

enum UsageTint {
    /// Claude Code's own usage palette: blue while there's headroom, amber as the
    /// window fills, red near the ceiling.
    static func of(_ percent: Double) -> Color {
        switch percent {
        case ..<60:  return Color(red: 0.29, green: 0.56, blue: 0.95)   // blue
        case ..<85:  return Color(red: 0.95, green: 0.66, blue: 0.15)   // amber
        default:     return Color(red: 0.90, green: 0.30, blue: 0.24)   // red
        }
    }
}

/// Harness picker along the top, full detail for the selected one below.
struct UsagePanel: View {
    @ObservedObject var usage: UsageTracker
    @State private var selected: AgentBrand?
    @State private var now = Date()

    private let tick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var current: UsageReport? {
        usage.reports.first { $0.brand == selected } ?? usage.reports.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switcher
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                if let report = current {
                    detail(for: report)
                } else {
                    // Distinguish "still scanning" from "nothing here" — the first
                    // scan takes a moment and read as a wrong answer.
                    Text(usage.lastRefreshed == nil
                         ? "Scanning local logs…"
                         : "No harnesses found on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(16)
                }
            }
        }
        .onReceive(tick) { now = $0 }
        .onAppear { selected = selected ?? usage.reports.first?.brand }
    }

    /// One tab per harness. The dot beneath each marks how much it has to say:
    /// a real quota, a measured number, or nothing readable.
    private var switcher: some View {
        HStack(spacing: 4) {
            ForEach(usage.reports) { report in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selected = report.brand }
                } label: {
                    VStack(spacing: 4) {
                        AgentMark(brand: report.brand, size: 17)
                            .opacity(report.hasAnything ? 1 : 0.35)
                        Circle()
                            .fill(indicator(for: report))
                            .frame(width: 4, height: 4)
                    }
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(report.brand == current?.brand ? 0.12 : 0))
                    )
                }
                .buttonStyle(.plain)
                .help(report.brand.displayName)
            }
            Spacer(minLength: 0)
            Button { usage.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .help("Rescan")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func indicator(for report: UsageReport) -> Color {
        if let quota = report.quota { return UsageTint.of(quota.usedPercent) }
        if report.measured != nil { return .white.opacity(0.5) }
        if report.activity != nil { return .white.opacity(0.35) }
        return .white.opacity(0.18)
    }

    @ViewBuilder
    private func detail(for report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Text(report.brand.displayName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                if let plan = report.quota?.planType {
                    Text(plan.uppercased())
                        .font(.system(size: 8.5, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                Spacer()
            }

            if let quota = report.quota {
                quotaBlock(quota)
            }

            if let measured = report.measured {
                measuredBlock(measured, hasQuota: report.quota != nil)
            }

            if let activity = report.activity {
                activityBlock(activity)
            }

            if let week = report.week {
                weekBlock(week)
            }

            if let note = report.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(source(for: report))
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blocks

    /// One row per enforced window, laid out like Claude Code's own `/usage`:
    /// name + reset on the left, the bar filling the middle, "X% used" at the right.
    private func quotaBlock(_ quota: UsageReport.Quota) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(quota.windows) { window in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: window))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        if let resets = window.resetsAt {
                            Text(resetLabel(resets, minutes: window.windowMinutes))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .frame(width: 116, alignment: .leading)

                    bar(window.usedPercent)

                    Text("\(Int(window.usedPercent))% used")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    private func title(for window: UsageReport.Quota.Window) -> String {
        if !window.name.isEmpty { return window.name }
        // Codex windows carry no name — title them by length.
        switch window.windowMinutes {
        case 10080:      return "Weekly"
        case 1..<1440:   return "Current session"
        default:
            let label = UsageReport.Quota.windowLabel(minutes: window.windowMinutes)
            return label.isEmpty ? "Limit" : "Rolling \(label)"
        }
    }

    /// Short windows count down ("Resets in 4 hr 35 min"); weekly ones name the
    /// day and time ("Resets Mon 4:00 PM") — matching how `/usage` phrases each.
    private func resetLabel(_ date: Date, minutes: Int) -> String {
        if minutes > 0 && minutes < 1440 {
            let remaining = max(0, Int(date.timeIntervalSince(now)))
            let hours = remaining / 3600, mins = (remaining % 3600) / 60
            return hours > 0 ? "Resets in \(hours) hr \(mins) min" : "Resets in \(mins) min"
        }
        let day = date.formatted(.dateTime.weekday(.abbreviated))
        let time = date.formatted(date: .omitted, time: .shortened)
        return "Resets \(day) \(time)"
    }

    private func measuredBlock(_ measured: UsageReport.Measured, hasQuota: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasQuota {
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 2)
            }
            Text(hasQuota ? "Measured locally" : "Measured locally — no quota is published")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            row("Input + cache writes", measured.inputTokens.compactTokens)
            row("Output", measured.outputTokens.compactTokens)
            row("Cache reads", measured.cacheReadTokens.compactTokens)
            if measured.messages > 0 { row("Messages", "\(measured.messages)") }
            if let resets = measured.resetsAt {
                row("5h block resets", resets.formatted(date: .omitted, time: .shortened))
            }
            if !measured.tokensByModel.isEmpty {
                // A row per model, heaviest first — more useful than a joined list.
                ForEach(measured.tokensByModel.sorted { $0.value > $1.value }, id: \.key) { model, tokens in
                    row(model.replacingOccurrences(of: "claude-", with: ""), tokens.compactTokens)
                }
            } else if !measured.models.isEmpty {
                row("Models", measured.models.sorted()
                    .map { $0.replacingOccurrences(of: "claude-", with: "") }
                    .joined(separator: ", "))
            }
        }
    }

    private func activityBlock(_ activity: UsageReport.Activity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(activity.noun.capitalized, "\(activity.count)")
            if let last = activity.lastActive {
                row("Last active", last.formatted(.relative(presentation: .named)))
            }
        }
    }

    private func weekBlock(_ week: UsageReport.Week) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 2)
            Text("Last 7 days")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            row("Tokens", week.tokens.compactTokens)
            row("Messages", "\(week.messages)")
        }
    }

    private func bar(_ percent: Double) -> some View {
        let tint = UsageTint.of(percent)
        // Track is a dim wash of the same hue, so an amber bar sits in a brown
        // channel and a blue one in a navy channel — exactly like the image.
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.22))
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, proxy.size.width * min(percent, 100) / 100))
            }
        }
        .frame(height: 6)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    /// Always say where a number came from — a server percentage and a local
    /// token count are not the same kind of fact.
    private func source(for report: UsageReport) -> String {
        if report.quota != nil {
            return "Percentages are live from \(report.brand.displayName)'s servers — "
                + "a real fraction of a real limit."
        }
        if report.measured != nil {
            return "Counted from local transcripts. This is what you spent — the "
                + "ceiling is only known server-side, so no percentage is shown."
        }
        if report.activity != nil {
            return "Inferred from file timestamps — \(report.brand.displayName)'s logs "
                + "don't store readable token counts."
        }
        return "\(report.brand.displayName) is installed but keeps no usage data "
            + "Polyhelm can read."
    }
}

import SwiftUI

public struct ProviderRow: View {
    public let entry: UsageEntry
    public let showUsed: Bool
    public let showAbsolute: Bool
    public let hidePersonalInfo: Bool

    public init(entry: UsageEntry, showUsed: Bool = false, showAbsolute: Bool = false, hidePersonalInfo: Bool = false) {
        self.entry = entry
        self.showUsed = showUsed
        self.showAbsolute = showAbsolute
        self.hidePersonalInfo = hidePersonalInfo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let usage = entry.usage {
                if let p = usage.primary { limitView("Primary", p); paceLine(for: p) }
                if let s = usage.secondary { limitView("Secondary", s); paceLine(for: s) }
                if let t = usage.tertiary { limitView("Tertiary", t); paceLine(for: t) }
                resetCreditsView(usage.codexResetCredits)
                footer(usage)
            } else if let err = entry.error {
                Text(err.message ?? err.kind ?? "no data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ProviderDisplayName.name(for: entry.provider))
                .font(.headline)
            if let acct = visibleAccount {
                Text(acct)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let src = entry.source {
                Text(src)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
    }

    private func footer(_ usage: Usage) -> some View {
        Group {
            if let updated = usage.updatedAt {
                Text("updated \(absoluteShort(updated))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var visibleAccount: String? {
        guard !hidePersonalInfo else { return nil }
        return entry.usage?.accountEmail ?? entry.account
    }

    private func limitView(_ label: String, _ limit: Limit) -> some View {
        // showUsed=false -> remaining: bar depletes as you use, low remaining = red.
        // showUsed=true  -> used: bar fills as you use, high used = red.
        let used = limit.usedPercent ?? 0
        let displayed = showUsed ? used : max(0, 100 - used)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", displayed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(percentColor(displayed, showUsed: showUsed))
            }
            ProgressView(value: min(max(displayed, 0), 100), total: 100)
                .tint(percentColor(displayed, showUsed: showUsed))
                #if os(iOS)
                .scaleEffect(y: 1.1)
                #endif
            if let line = ResetCountdown.resetLine(for: limit, showAbsolute: showAbsolute) {
                Text(line)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private func percentColor(_ displayed: Double, showUsed: Bool) -> Color {
        // "bad" side is always red: high used, or low remaining.
        let bad = showUsed ? displayed : (100 - displayed)
        switch bad {
        case 80...: return .red
        case 50...: return .orange
        default: return .green
        }
    }

    /// Pace line color: deficit / runs-out = warning, on-pace / reserve / lasts = OK.
    private func paceColor(_ text: String) -> Color {
        if text.contains("deficit") || text.contains("Runs out") { return .orange }
        return .secondary
    }

    @ViewBuilder
    private func paceLine(for limit: Limit) -> some View {
        if let pace = UsagePaceText.summary(for: limit) {
            Text(pace)
                .font(.caption2)
                .foregroundStyle(paceColor(pace))
                .padding(.top, 1)
        }
    }

    @ViewBuilder
    private func resetCreditsView(_ credits: CodexResetCredits?) -> some View {
        if let credits, let n = credits.availableCount, n > 0 {
            let availableCredits = (credits.credits ?? []).filter { $0.status == "available" }
            let displayedCredits = availableCredits.isEmpty ? (credits.credits ?? []) : availableCredits
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise.circle").font(.caption2)
                    Text("\(n) reset credit\(n == 1 ? "" : "s") available")
                        .font(.caption.bold())
                }
                .foregroundStyle(.tint)
                ForEach(Array(displayedCredits.enumerated()), id: \.offset) { _, credit in
                    if let title = credit.title, !title.isEmpty {
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let iso = credit.expiresAt, let d = ISO8601DateFormatter().date(from: iso) {
                        Text("expires \(absoluteShort(iso)) · \(countdownTo(d))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func countdownTo(_ date: Date) -> String {
        let s = max(0, date.timeIntervalSince(.now))
        let m = max(1, Int(ceil(s / 60.0)))
        let d = m / (24 * 60)
        let h = (m / 60) % 24
        if d > 0 { return h > 0 ? "in \(d)d \(h)h" : "in \(d)d" }
        if h > 0 { let mn = m % 60; return mn > 0 ? "in \(h)h \(mn)m" : "in \(h)h" }
        return "in \(m)m"
    }

    private func absoluteShort(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

public struct UsageListView: View {
    public let payload: Payload?
    public let searching: Bool
    public let statusText: String?
    public let sourceBadge: String?
    public let hidePersonalInfo: Bool

    public init(payload: Payload?, searching: Bool = false, statusText: String? = nil, sourceBadge: String? = nil, hidePersonalInfo: Bool = false) {
        self.payload = payload
        self.searching = searching
        self.statusText = statusText
        self.sourceBadge = sourceBadge
        self.hidePersonalInfo = hidePersonalInfo
    }

    public var body: some View {
        List {
            if let payload {
                headerSection(payload)
                let usable = payload.usage.filter { $0.hasUsage }
                let errored = payload.usage.filter { !$0.hasUsage }
                Section {
                    ForEach(usable, id: \.self) { ProviderRow(entry: $0, showUsed: payload.showUsed, showAbsolute: payload.resetTimesShowAbsolute, hidePersonalInfo: hidePersonalInfo) }
                } header: {
                    Text("\(usable.count) providers")
                }
                if !errored.isEmpty {
                    Section {
                        ForEach(errored, id: \.self) { ProviderRow(entry: $0, showUsed: payload.showUsed, showAbsolute: payload.resetTimesShowAbsolute, hidePersonalInfo: hidePersonalInfo) }
                    } header: {
                        Text("\(errored.count) unavailable")
                    }
                }
            } else if searching {
                ContentUnavailableViewCompat(
                    title: "Searching for your Mac…",
                    systemImage: "wifi",
                    description: "Make sure both devices are on the same Wi-Fi and CodexBar iOS Relay is running on the Mac."
                )
            } else {
                ContentUnavailableViewCompat(
                    title: "No data yet",
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: statusText
                )
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    @ViewBuilder
    private func headerSection(_ payload: Payload) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(maskHostname(payload.hostname))
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(syncedAgo(payload.syncedAt))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    if let badge = sourceBadge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(payload.showUsed ? "used" : "remaining")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func syncedAgo(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        #if os(iOS)
        // ponytail: absolute timestamp on iOS — relative "8s ago" hides staleness;
        // a clock time makes a stale snapshot obvious at a glance.
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return "synced " + f.string(from: d)
        #else
        let s = Date().timeIntervalSince(d)
        if s < 5 { return "synced just now" }
        if s < 60 { return "synced \(Int(s))s ago" }
        if s < 3600 { return "synced \(Int(s/60))m ago" }
        return "synced \(Int(s/3600))h ago"
        #endif
    }

    private func maskHostname(_ value: String) -> String {
        hidePersonalInfo ? "This Mac" : value
    }
}

/// ContentUnavailableView exists on iOS 17+ and macOS 14+; tiny shim for parity.
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}

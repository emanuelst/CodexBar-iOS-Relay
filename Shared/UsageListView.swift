import SwiftUI

public struct ProviderRow: View {
    public let entry: UsageEntry
    public let showUsed: Bool
    public let showAbsolute: Bool
    public let hidePersonalInfo: Bool
    public let now: Date

    public init(entry: UsageEntry, showUsed: Bool = false, showAbsolute: Bool = false, hidePersonalInfo: Bool = false, now: Date = .now) {
        self.entry = entry
        self.showUsed = showUsed
        self.showAbsolute = showAbsolute
        self.hidePersonalInfo = hidePersonalInfo
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let usage = entry.usage {
                if hasVisibleLimits(usage) {
                    if let p = usage.primary { limitView("Primary", p); paceLine(for: p) }
                    if let s = usage.secondary { limitView("Secondary", s); paceLine(for: s) }
                    if let t = usage.tertiary { limitView("Tertiary", t); paceLine(for: t) }
                    gptReserveView(usage.extraRateWindows)
                } else {
                    Text("Limits not available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                claudeSavedResetsView(usage)
                cloudCreditsView(usage.details)
                resetCreditsView(usage.codexResetCredits)
                subscriptionMetadataView(usage)
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
                Text("updated \(SyncFreshness.relativeAgeLabel(from: updated, now: now))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var visibleAccount: String? {
        guard !hidePersonalInfo else { return nil }
        return entry.usage?.accountEmail ?? entry.account
    }

    private func hasVisibleLimits(_ usage: Usage) -> Bool {
        usage.primary != nil
            || usage.secondary != nil
            || usage.tertiary != nil
            || (usage.extraRateWindows ?? []).contains(where: Self.isGPTReserve)
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
                Text(percentageText(displayed, wholeNumberIfIntegral: label == "Primary" || label == "Secondary"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(percentColor(displayed, showUsed: showUsed))
            }
            ProgressView(value: min(max(displayed, 0), 100), total: 100)
                #if os(macOS)
                .progressViewStyle(QuotaProgressStyle(color: percentColor(displayed, showUsed: showUsed)))
                .accessibilityLabel(Text("\(label) \(showUsed ? "used" : "remaining")"))
                .accessibilityValue(Text(percentageText(displayed, wholeNumberIfIntegral: label == "Primary" || label == "Secondary")))
                #else
                .tint(percentColor(displayed, showUsed: showUsed))
                .scaleEffect(y: 1.1)
                #endif
            if let line = ResetCountdown.resetLine(for: limit, showAbsolute: showAbsolute, now: now) {
                Text(line)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private func percentageText(_ value: Double, wholeNumberIfIntegral: Bool) -> String {
        if wholeNumberIfIntegral, value.rounded() == value {
            return "\(Int(value.rounded()))%"
        }
        return String(format: "%.1f%%", value)
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
        if let pace = UsagePaceText.summary(for: limit, now: now) {
            Text(pace)
                .font(.caption2)
                .foregroundStyle(paceColor(pace))
                .padding(.top, 1)
        }
    }

    @ViewBuilder
    private func gptReserveView(_ windows: [NamedLimit]?) -> some View {
        ForEach((windows ?? []).filter(Self.isGPTReserve), id: \.id) { reserve in
            limitView(reserve.title, reserve.window)
            paceLine(for: reserve.window)
        }
    }

    private static func isGPTReserve(_ window: NamedLimit) -> Bool {
        guard window.usageKnown != false else { return false }
        let id = window.id.lowercased()
        let title = window.title.lowercased()
        return id == "codex-base-model-inference" || id.contains("gpt-reserve") || title.contains("gpt reserve")
    }

    @ViewBuilder
    private func claudeSavedResetsView(_ usage: Usage) -> some View {
        if entry.provider == "claude", let reset = usage.claudeSavedResetDetail(at: now) {
            VStack(alignment: .leading, spacing: 3) {
                resetCreditsHeader(reset.isStale ? "\(reset.count) last reported" : reset.value)
                Link("Saved reset", destination: URL(string: "https://claude.ai/settings/usage")!)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Open Claude's Usage page to see the reset type and options.")
                if let expiry = reset.expiryText {
                    let estimated = usage.updatedAt.flatMap(ResetCountdown.date(from:)).flatMap {
                        ResetCountdown.estimatedSavedResetExpiryLine(expiry, capturedAt: $0, now: now)
                    }
                    let text = estimated ?? (expiry.hasPrefix("Expires ")
                        ? "expires " + expiry.dropFirst("Expires ".count)
                        : expiry)
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(estimated == nil ? expiry : "Approximate: year inferred from the saved snapshot; time interpreted in this device's timezone.")
                }
            }
            .padding(.top, 2)
        }
    }

    private func resetCreditsHeader(_ value: String) -> some View {
        HStack {
            Text("Reset credits")
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func cloudCreditsView(_ sections: [UsageDetailSection]?) -> some View {
        if entry.provider == "claude",
           let credit = sections?.flatMap(\.rows).first(where: { $0.id == "claude-cloud-credits" }) {
            let expired = credit.cloudCreditExpired(at: now)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label("Cloud credits", systemImage: "cloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(expired ? "Expired" : credit.value)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let iso = credit.cloudCreditExpiry,
                   let absolute = ResetCountdown.absolute(from: iso, now: now) {
                    Text("\(expired ? "expired" : "expires") \(absolute)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else if let note = credit.secondaryValue {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func resetCreditsView(_ credits: CodexResetCredits?) -> some View {
        if let credits, let n = credits.availableCount, n > 0 {
            let availableCredits = (credits.credits ?? []).filter { $0.status == "available" }
            let displayedCredits = availableCredits.isEmpty ? (credits.credits ?? []) : availableCredits
            VStack(alignment: .leading, spacing: 3) {
                resetCreditsHeader("\(n) available")
                ForEach(Array(displayedCredits.enumerated()), id: \.offset) { _, credit in
                    if let title = credit.title, !title.isEmpty {
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let iso = credit.expiresAt, let d = ResetCountdown.date(from: iso) {
                        Text("expires \(absoluteShort(iso)) · \(countdownTo(d))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func subscriptionMetadataView(_ usage: Usage) -> some View {
        if let iso = usage.subscriptionRenewalValue {
            planDateLine("Plan renews", iso)
        }
        if let iso = usage.subscriptionExpirationValue {
            planDateLine("Plan expires", iso)
        }
    }

    @ViewBuilder
    private func planDateLine(_ label: String, _ iso: String) -> some View {
        if let rendered = ResetCountdown.subscriptionDate(iso, now: now) {
            let countdown: String = {
                // Date-only billing values have no exact time, so do not invent one.
                guard iso.count > 10,
                      let date = ResetCountdown.date(from: iso), date > now else { return "" }
                return " · \(ResetCountdown.countdown(to: date, now: now))"
            }()
            Text("\(label) \(rendered)\(countdown)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func countdownTo(_ date: Date) -> String {
        let s = max(0, date.timeIntervalSince(now))
        let m = max(1, Int(ceil(s / 60.0)))
        let d = m / (24 * 60)
        let h = (m / 60) % 24
        if d > 0 { return h > 0 ? "in \(d)d \(h)h" : "in \(d)d" }
        if h > 0 { let mn = m % 60; return mn > 0 ? "in \(h)h \(mn)m" : "in \(h)h" }
        return "in \(m)m"
    }

    private func subscriptionDateTime(_ date: Date) -> String {
        ResetCountdown.absoluteDateTime(date, now: now)
    }

    private func absoluteShort(_ iso: String) -> String {
        guard let d = ResetCountdown.date(from: iso) else { return iso }
        return ResetCountdown.absoluteDateTime(d, now: now)
    }
}

#if os(macOS)
/// Draw the quota color explicitly instead of relying on the native control's accent tint.
private struct QuotaProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            let fraction = min(max(configuration.fractionCompleted ?? 0, 0), 1)
            Capsule()
                .fill(Color.primary.opacity(0.06))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * fraction)
                }
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
        .frame(height: 8)
    }
}
#endif

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
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
            if let payload {
                headerSection(payload, now: context.date)
                let ordered = payload.usage.sorted {
                    ProviderDisplayName.name(for: $0.provider).lowercased()
                        < ProviderDisplayName.name(for: $1.provider).lowercased()
                }
                let usable = ordered.filter { $0.hasUsage }
                let errored = ordered.filter { !$0.hasUsage }
                Section {
                    ForEach(usable, id: \.rowIdentity) { ProviderRow(entry: $0, showUsed: payload.showUsed, showAbsolute: payload.resetTimesShowAbsolute, hidePersonalInfo: hidePersonalInfo, now: context.date) }
                } header: {
                    Text("\(usable.count) providers")
                }
                if !errored.isEmpty {
                    Section {
                        ForEach(errored, id: \.rowIdentity) { ProviderRow(entry: $0, showUsed: payload.showUsed, showAbsolute: payload.resetTimesShowAbsolute, hidePersonalInfo: hidePersonalInfo, now: context.date) }
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
    }

    @ViewBuilder
    private func headerSection(_ payload: Payload, now: Date) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(maskHostname(payload.hostname))
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    Image(systemName: syncIcon(for: payload.syncedAt, now: now))
                        .font(.caption2)
                    Text(syncedAgo(payload.syncedAt, now: now))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(syncColor(for: payload.syncedAt, now: now))
                Text("Times: \(ResetCountdown.localTimeZoneLabel())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
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

    private func syncedAgo(_ iso: String, now: Date) -> String {
        SyncFreshness.label(from: iso, now: now)
    }

    private func syncIcon(for iso: String, now: Date) -> String {
        switch SyncFreshness.level(from: iso, now: now) {
        case .stale: return "exclamationmark.triangle.fill"
        case .aging: return "clock.badge.exclamationmark"
        case .fresh: return "clock"
        case .unknown: return "questionmark.circle"
        }
    }

    private func syncColor(for iso: String, now: Date) -> Color {
        switch SyncFreshness.level(from: iso, now: now) {
        case .stale: return .red
        case .aging: return .orange
        case .fresh: return .secondary
        case .unknown: return .secondary
        }
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

import Foundation

/// Read-only adapter for CodexBar's version-1 PlanUtilizationHistoryStore.
/// It deliberately never merges buckets, adopts unscoped entries, or adds snapshot samples.
struct PlanUsageHistoryDocument: Decodable {
    let version: Int
    let preferredAccountKey: String?
    let unscoped: [PlanUsageSeries]
    let accounts: [String: [PlanUsageSeries]]

    var selected: [PlanUsageSeries] {
        guard version == 1, let key = preferredAccountKey,
              key != "__codexbar_unscoped__" else { return [] }
        // A missing selection is unavailable, rather than choosing another account by recency.
        return accounts[key] ?? []
    }
}

struct PlanUsageSeries: Decodable, Equatable, Identifiable {
    let name: String
    let windowMinutes: Int
    let entries: [PlanUsageEntry]
    var id: String { "\(name):\(windowMinutes)" }
    var lane: String { windowMinutes == 43200 && ["session", "weekly"].contains(name) ? "monthly" : name }
    var title: String {
        switch lane {
        case "session": return "Session"
        case "weekly": return "Weekly"
        case "monthly": return "Monthly"
        case "opus": return "Sonnet"
        default: return lane.capitalized
        }
    }
}

struct PlanUsageEntry: Decodable, Equatable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

/// Port of upstream QuotaBurndownModel. Preparation uses the LAST RECORDED capture,
/// not the wall clock or a current Relay snapshot. The wall clock only expires the window.
struct PlanUsageGraph: Equatable {
    struct Sample: Equatable {
        let date: Date
        let remaining: Double
    }
    let start: Date
    let reset: Date
    let samples: [Sample]
    var last: Sample { samples[samples.count - 1] }

    init?(series: PlanUsageSeries, now: Date) {
        let entries = series.entries.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            if $0.usedPercent != $1.usedPercent { return $0.usedPercent < $1.usedPercent }
            return ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast)
        }
        guard series.windowMinutes > 0, let latest = entries.last,
              latest.capturedAt <= now, latest.usedPercent.isFinite,
              let reset = latest.resetsAt, reset > now else { return nil }
        let start = reset.addingTimeInterval(-Double(series.windowMinutes) * 60)
        guard start <= latest.capturedAt else { return nil }
        var segment: [PlanUsageEntry] = []
        for entry in entries {
            guard entry.capturedAt >= start, entry.capturedAt <= latest.capturedAt,
                  entry.usedPercent.isFinite,
                  entry.resetsAt.map({ abs($0.timeIntervalSince(reset)) <= 120 }) ?? true else { continue }
            if let last = segment.last {
                if entry.capturedAt == last.capturedAt { segment[segment.count - 1] = entry; continue }
                if entry.usedPercent < last.usedPercent { segment.removeAll() }
            }
            segment.append(entry)
        }
        guard !segment.isEmpty else { return nil }
        self.start = start
        self.reset = reset
        self.samples = segment.map { Sample(date: $0.capturedAt, remaining: min(100, max(0, 100 - $0.usedPercent))) }
    }

    func progress(_ date: Date) -> Double {
        100 * date.timeIntervalSince(start) / reset.timeIntervalSince(start)
    }
}

struct PlanUsageHistoryReader {
    let directory: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.steipete.codexbar/history")) {
        self.directory = directory
    }
    func read(provider: String) -> [PlanUsageSeries] {
        guard ["codex", "claude"].contains(provider),
              let data = try? Data(contentsOf: directory.appendingPathComponent(provider + ".json")) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(PlanUsageHistoryDocument.self, from: data) else { return [] }
        // Upstream folds legacy Codex 30-day payload slots into Monthly. Merge only within
        // the already selected owner; canonicalize the same ±5-minute duration tolerance.
        let groups = Dictionary(grouping: document.selected.filter { (provider == "codex" ? ["session", "weekly", "monthly"] : ["session", "weekly", "opus"]).contains($0.name) && $0.windowMinutes > 0 && !$0.entries.isEmpty }) { series in
            let lane = provider == "codex" ? series.lane : series.name
            let duration = lane == "session" && (295...305).contains(series.windowMinutes) ? 300
                : lane == "weekly" && (10070...10090).contains(series.windowMinutes) ? 10080 : series.windowMinutes
            return "\(lane):\(duration)"
        }
        return groups.values.compactMap { values in
            guard let first = values.first else { return nil }
            let lane = provider == "codex" ? first.lane : first.name
            let duration = lane == "session" && (295...305).contains(first.windowMinutes) ? 300
                : lane == "weekly" && (10070...10090).contains(first.windowMinutes) ? 10080 : first.windowMinutes
            return PlanUsageSeries(name: lane, windowMinutes: duration, entries: values.flatMap(\.entries))
        }.sorted { $0.windowMinutes == $1.windowMinutes ? $0.name < $1.name : $0.windowMinutes < $1.windowMinutes }
    }
}

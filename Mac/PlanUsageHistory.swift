import CoreGraphics
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

struct PlanUsageTimeAxis {
    let labelDates: [Date]
    let dayBoundaries: [Date]
    let hourBoundaries: [Date]
    let duration: TimeInterval
    let plotStart: Date
    let plotEnd: Date

    init(start: Date, end: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let rawDuration = max(0, end.timeIntervalSince(start))
        if rawDuration > 24 * 60 * 60 {
            self.plotStart = calendar.startOfDay(for: start)
            let resetDay = calendar.startOfDay(for: end)
            self.plotEnd = calendar.date(byAdding: .day, value: 1, to: resetDay) ?? end
        } else {
            self.plotStart = calendar.dateInterval(of: .hour, for: start)?.start ?? start
            let paddedEnd = calendar.date(byAdding: .hour, value: 1, to: end) ?? end
            let lastHour = calendar.dateInterval(of: .hour, for: paddedEnd)?.start ?? paddedEnd
            self.plotEnd = abs(paddedEnd.timeIntervalSince(lastHour)) < 1
                ? lastHour
                : calendar.date(byAdding: .hour, value: 1, to: lastHour) ?? paddedEnd
        }
        let duration = max(0, self.plotEnd.timeIntervalSince(self.plotStart))
        self.duration = duration

        var boundaries: [Date] = []
        if duration > 24 * 60 * 60 {
            let dayStride = duration > 14 * 24 * 60 * 60
                ? max(1, Int(ceil(duration / (14 * 24 * 60 * 60))))
                : 1
            var day = self.plotStart
            while day < self.plotEnd {
                boundaries.append(day)
                guard let next = calendar.date(byAdding: .day, value: dayStride, to: day), next > day else { break }
                day = next
            }
        }
        self.dayBoundaries = boundaries

        var hourlyMarks: [Date] = []
        if rawDuration <= 24 * 60 * 60 {
            var hour = self.plotStart
            while hour <= self.plotEnd {
                hourlyMarks.append(hour)
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else { break }
                hour = next
            }
        }
        self.hourBoundaries = hourlyMarks

        if duration <= 24 * 60 * 60 {
            self.labelDates = hourlyMarks
        } else if boundaries.count <= 14 {
            self.labelDates = boundaries
        } else {
            let stride = max(1, Int(ceil(Double(boundaries.count) / 4)))
            let selected = boundaries.enumerated().compactMap { index, date in
                index.isMultiple(of: stride) ? date : nil
            }
            self.labelDates = selected.count >= 2 ? selected : [start, end]
        }
    }

    var markDates: [Date] {
        Array(Set(self.labelDates + self.dayBoundaries + self.hourBoundaries)).sorted()
    }

    func isDayBoundary(_ date: Date) -> Bool {
        self.dayBoundaries.contains { abs($0.timeIntervalSince(date)) < 1 }
    }

    func isHourBoundary(_ date: Date) -> Bool {
        self.hourBoundaries.contains { abs($0.timeIntervalSince(date)) < 1 }
    }

    func isLabelDate(_ date: Date) -> Bool {
        self.labelDates.contains { abs($0.timeIntervalSince(date)) < 1 }
    }

    func label(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        let template: String
        if self.duration <= 24 * 60 * 60 {
            template = "Hm"
        } else if self.duration <= 14 * 24 * 60 * 60 {
            template = "EEEd"
        } else {
            template = "MMM d"
        }
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// Continuous, invertible time scale: session hours get room between compressed days.
/// No time is removed. Interpolated vertices at the joins preserve the original curves.
struct PlanUsageFocusAxis {
    let start: Date
    let end: Date
    let focusStart: Date
    let focusEnd: Date
    private let leadingWidth: Double
    private let trailingWidth: Double

    init(start: Date, end: Date, focusStart: Date, focusEnd: Date) {
        self.start = start
        self.end = max(end, start.addingTimeInterval(1))
        let lower = max(start, min(focusStart, self.end.addingTimeInterval(-1)))
        let upper = min(self.end, max(focusEnd, lower.addingTimeInterval(1)))
        let expanded = self.end.timeIntervalSince(start) > 86400 && upper > lower
        self.focusStart = expanded ? lower : start
        self.focusEnd = expanded ? upper : self.end
        leadingWidth = expanded && lower > start ? 0.18 : 0
        trailingWidth = expanded && upper < self.end ? 0.18 : 0
    }

    var breakDates: [Date] {
        (leadingWidth > 0 ? [focusStart] : []) + (trailingWidth > 0 ? [focusEnd] : [])
    }

    func position(_ date: Date) -> Double {
        if date < focusStart && leadingWidth > 0 {
            return date.timeIntervalSince(start) / focusStart.timeIntervalSince(start) * leadingWidth
        }
        if date > focusEnd && trailingWidth > 0 {
            return 1 - trailingWidth + date.timeIntervalSince(focusEnd) / end.timeIntervalSince(focusEnd) * trailingWidth
        }
        return leadingWidth + date.timeIntervalSince(focusStart) / focusEnd.timeIntervalSince(focusStart) * (1 - leadingWidth - trailingWidth)
    }

    func date(at position: Double) -> Date {
        if position < leadingWidth && leadingWidth > 0 {
            return start.addingTimeInterval(position / leadingWidth * focusStart.timeIntervalSince(start))
        }
        if position > 1 - trailingWidth && trailingWidth > 0 {
            return focusEnd.addingTimeInterval((position - (1 - trailingWidth)) / trailingWidth * end.timeIntervalSince(focusEnd))
        }
        return focusStart.addingTimeInterval((position - leadingWidth) / (1 - leadingWidth - trailingWidth) * focusEnd.timeIntervalSince(focusStart))
    }

    func isFocused(_ position: Double) -> Bool {
        let date = date(at: position)
        return date >= focusStart.addingTimeInterval(-1) && date <= focusEnd.addingTimeInterval(1)
    }

    func vertices(_ samples: [PlanUsageGraph.Sample]) -> [PlanUsageGraph.Sample] {
        guard samples.count > 1 else { return samples }
        var result = [samples[0]]
        for (a, b) in zip(samples, samples.dropFirst()) {
            for boundary in breakDates where boundary > a.date && boundary < b.date {
                let fraction = boundary.timeIntervalSince(a.date) / b.date.timeIntervalSince(a.date)
                result.append(.init(date: boundary, remaining: a.remaining + (b.remaining - a.remaining) * fraction))
            }
            result.append(b)
        }
        return result
    }
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
        let entries = Self.sorted(series.entries)
        guard series.windowMinutes > 0, let latest = entries.last,
              latest.capturedAt <= now, latest.usedPercent.isFinite,
              let reset = latest.resetsAt, reset > now else { return nil }
        let start = reset.addingTimeInterval(-Double(series.windowMinutes) * 60)
        guard start <= latest.capturedAt else { return nil }
        let segment = Self.segment(entries, start: start, through: latest.capturedAt, reset: reset, allowMissingReset: true)
        guard !segment.isEmpty else { return nil }
        self.start = start
        self.reset = reset
        self.samples = segment.map { Sample(date: $0.capturedAt, remaining: min(100, max(0, 100 - $0.usedPercent))) }
    }

    /// A finished window, for display context only. Entries must name this reset explicitly.
    private init?(series: PlanUsageSeries, finishedAt reset: Date) {
        guard series.windowMinutes > 0 else { return nil }
        let start = reset.addingTimeInterval(-Double(series.windowMinutes) * 60)
        let segment = Self.segment(Self.sorted(series.entries), start: start, through: reset, reset: reset, allowMissingReset: false)
        guard !segment.isEmpty else { return nil }
        self.start = start
        self.reset = reset
        self.samples = segment.map { Sample(date: $0.capturedAt, remaining: min(100, max(0, 100 - $0.usedPercent))) }
    }

    /// The window captured immediately before `current`, even if it was reset early, so its
    /// scheduled reset can lie after `current.start`. Idle windows (0% used throughout) are
    /// skipped: Codex reports a rolling reset for them, so they are not real windows.
    /// Display context only; forecasts never use it.
    static func previous(series: PlanUsageSeries, before current: PlanUsageGraph) -> PlanUsageGraph? {
        let boundary = current.start.addingTimeInterval(120)
        var tried: [Date] = []
        for entry in sorted(series.entries).reversed() where entry.capturedAt <= boundary {
            guard let reset = entry.resetsAt, abs(reset.timeIntervalSince(current.reset)) > 120,
                  !tried.contains(where: { abs($0.timeIntervalSince(reset)) <= 120 }) else { continue }
            tried.append(reset)
            if let window = PlanUsageGraph(series: series, finishedAt: reset), window.samples.contains(where: { $0.remaining < 100 }) {
                return window
            }
            if tried.count >= 64 { break }
        }
        return nil
    }

    /// The scheduled reset lay after `next` began: the provider reset this window early.
    func resetEarly(before next: PlanUsageGraph) -> Bool {
        reset.timeIntervalSince(next.start) > 300
    }

    private static func sorted(_ entries: [PlanUsageEntry]) -> [PlanUsageEntry] {
        entries.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            if $0.usedPercent != $1.usedPercent { return $0.usedPercent < $1.usedPercent }
            return ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast)
        }
    }

    /// Captures for one reset boundary (120-second equivalence); a usage drop restarts the line.
    private static func segment(_ entries: [PlanUsageEntry], start: Date, through end: Date, reset: Date, allowMissingReset: Bool) -> [PlanUsageEntry] {
        var segment: [PlanUsageEntry] = []
        for entry in entries {
            guard entry.capturedAt >= start, entry.capturedAt <= end,
                  entry.usedPercent.isFinite,
                  entry.resetsAt.map({ abs($0.timeIntervalSince(reset)) <= 120 }) ?? allowMissingReset else { continue }
            if let last = segment.last {
                if entry.capturedAt == last.capturedAt { segment[segment.count - 1] = entry; continue }
                if entry.usedPercent < last.usedPercent { segment.removeAll() }
            }
            segment.append(entry)
        }
        return segment
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

/// Deterministic, collision-aware placement for in-chart labels.
/// Lane labels (Now, resets, run-outs) live in reserved bands above and below the data;
/// floating labels (provider tags) try a fixed list of offsets around their point.
/// Text never decides data: every label stays in the detail rows below the chart.
struct PlanUsageAnnotationLayout {
    enum Band: Equatable { case top, bottom }
    enum Kind: Equatable { case lane(Band), floating(CGPoint) }

    struct Label: Equatable {
        let id: String
        /// Preferred text first; later variants are shorter. The last one is the minimum.
        let variants: [String]
        /// Plot-space x the label must stay attached to.
        let anchorX: CGFloat
        let kind: Kind
    }

    struct Placement: Equatable {
        let id: String
        let text: String
        let variant: Int
        let frame: CGRect
        /// Lane index from the data edge outwards; nil for floating labels.
        let lane: Int?
    }

    struct Result: Equatable {
        let placements: [Placement]
        let dropped: [String]
    }

    static let laneHeight: CGFloat = 18
    static let gap: CGFloat = 4

    let plot: CGRect
    let topLanes: Int
    let bottomLanes: Int
    let measure: (String) -> CGFloat

    /// Top lanes stack upwards from the 100% line; bottom lanes stack downwards from the 0% line.
    func laneRect(_ band: Band, _ lane: Int) -> CGRect {
        let height = Self.laneHeight
        let y = band == .top
            ? plot.minY + CGFloat(topLanes - 1 - lane) * height
            : plot.maxY - CGFloat(bottomLanes - lane) * height
        return CGRect(x: plot.minX, y: y, width: plot.width, height: height)
    }

    /// Labels are placed in array order (priority). Each pass tries every lane/offset before
    /// shortening; if any label is dropped, the next pass starts every label one variant shorter.
    func solve(_ labels: [Label], obstacles: [CGRect] = []) -> Result {
        let levels = max(1, labels.map(\.variants.count).max() ?? 1)
        var best: Result?
        for level in 0..<levels {
            let result = pass(labels, startLevel: level, obstacles: obstacles)
            if result.dropped.isEmpty { return result }
            if best == nil || result.dropped.count < best!.dropped.count { best = result }
        }
        return best ?? Result(placements: [], dropped: labels.map(\.id))
    }

    private func pass(_ labels: [Label], startLevel: Int, obstacles: [CGRect]) -> Result {
        var placed: [Placement] = []
        var dropped: [String] = []
        for label in labels {
            var chosen: Placement?
            search: for variant in min(startLevel, label.variants.count - 1)..<label.variants.count {
                let text = label.variants[variant]
                let size = CGSize(width: ceil(measure(text)), height: Self.laneHeight - 2)
                for (frame, lane) in candidates(label, size: size) {
                    let padded = frame.insetBy(dx: -Self.gap / 2, dy: 0)
                    let fitsLabels = !placed.contains { $0.frame.insetBy(dx: -Self.gap / 2, dy: 0).intersects(padded) }
                    let fitsObstacles = lane != nil || !obstacles.contains { $0.intersects(frame) }
                    if fitsLabels && fitsObstacles {
                        chosen = Placement(id: label.id, text: text, variant: variant, frame: frame, lane: lane)
                        break search
                    }
                }
            }
            if let chosen { placed.append(chosen) } else { dropped.append(label.id) }
        }
        return Result(placements: placed, dropped: dropped)
    }

    private func candidates(_ label: Label, size: CGSize) -> [(CGRect, Int?)] {
        guard size.width <= plot.width else { return [] }
        func clamped(_ frame: CGRect) -> CGRect {
            var frame = frame
            frame.origin.x = min(max(frame.minX, plot.minX), plot.maxX - frame.width)
            return frame
        }
        switch label.kind {
        case .lane(let band):
            let lanes = band == .top ? topLanes : bottomLanes
            var output: [(CGRect, Int?)] = []
            for lane in 0..<lanes {
                let row = laneRect(band, lane)
                let y = row.midY - size.height / 2
                // Centered, then starting at the rule, then ending at it: every option touches the rule.
                for x in [label.anchorX - size.width / 2, label.anchorX - 6, label.anchorX - size.width + 6] {
                    output.append((clamped(CGRect(x: x, y: y, width: size.width, height: size.height)), lane))
                }
            }
            return output
        case .floating(let point):
            let offset: CGFloat = 8
            let raw = [
                CGPoint(x: point.x + offset, y: point.y - offset - size.height),
                CGPoint(x: point.x + offset, y: point.y + offset),
                CGPoint(x: point.x - offset - size.width, y: point.y - offset - size.height),
                CGPoint(x: point.x - offset - size.width, y: point.y + offset),
                CGPoint(x: point.x - size.width / 2, y: point.y - offset - 6 - size.height),
                CGPoint(x: point.x - size.width / 2, y: point.y + offset + 6),
                CGPoint(x: point.x + offset, y: point.y - offset - 2 * size.height),
                CGPoint(x: point.x - offset - size.width, y: point.y + offset + size.height)
            ]
            // Floating labels stay between the reserved bands so they never cover lane labels.
            let dataTop = plot.minY + CGFloat(topLanes) * Self.laneHeight
            let dataBottom = plot.maxY - CGFloat(bottomLanes) * Self.laneHeight
            return raw.map { CGRect(origin: $0, size: size) }
                .filter { $0.minX >= plot.minX && $0.maxX <= plot.maxX && $0.minY >= dataTop && $0.maxY <= dataBottom }
                .map { ($0, nil) }
        }
    }

    /// Keeps axis labels at least `minimumGap` apart (in plot fraction), always keeping the first.
    static func thinned(_ positions: [Double], minimumGap: Double) -> [Double] {
        var output: [Double] = []
        for position in positions.sorted() where output.last.map({ position - $0 >= minimumGap }) ?? true {
            output.append(position)
        }
        return output
    }
}

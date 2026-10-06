import Foundation

@main enum PlanUsageChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        func entry(_ age: Double, _ used: Double, _ end: Date? = nil) -> PlanUsageEntry {
            PlanUsageEntry(capturedAt: now.addingTimeInterval(-age), usedPercent: used, resetsAt: end ?? reset)
        }
        func graph(_ entries: [PlanUsageEntry], minutes: Int = 300) -> PlanUsageGraph? {
            PlanUsageGraph(series: PlanUsageSeries(name: "session", windowMinutes: minutes, entries: entries), now: now)
        }
        let g = graph([entry(1200, 10), entry(600, 20)])!
        precondition(g.samples.count == 2 && g.last.date == now.addingTimeInterval(-600))
        precondition(g.last.remaining == 80 && g.progress(g.start) == 0 && g.progress(g.reset) == 100)
        let shortAxis = PlanUsageTimeAxis(start: now.addingTimeInterval(-5 * 3600), end: now)
        precondition(shortAxis.labelDates == shortAxis.hourBoundaries && shortAxis.labelDates.count > 5 && shortAxis.dayBoundaries.isEmpty)
        precondition(shortAxis.label(for: shortAxis.labelDates[0]).contains(":"))

        let vienna = TimeZone(identifier: "Europe/Vienna")!
        let fallBackStart = ResetCountdown.date(from: "2026-10-23T22:00:00Z")!
        let fallBackEnd = ResetCountdown.date(from: "2026-10-26T23:00:00Z")!
        let calendarAxis = PlanUsageTimeAxis(start: fallBackStart, end: fallBackEnd, timeZone: vienna)
        precondition(calendarAxis.dayBoundaries.count == 4)
        precondition(calendarAxis.dayBoundaries[2].timeIntervalSince(calendarAxis.dayBoundaries[1]) == 25 * 3600)
        precondition(calendarAxis.labelDates.count == 4)
        precondition(calendarAxis.labelDates == calendarAxis.dayBoundaries)
        let focusStart = fallBackStart.addingTimeInterval(24 * 3600)
        let focusEnd = focusStart.addingTimeInterval(8 * 3600)
        let focused = PlanUsageFocusAxis(start: fallBackStart, end: fallBackEnd, focusStart: focusStart, focusEnd: focusEnd)
        precondition(focused.breakDates == [focusStart, focusEnd])
        precondition(abs(focused.position(focusEnd) - focused.position(focusStart) - 0.64) < 0.000001)
        var previous = -Double.infinity
        for hour in 0...Int(fallBackEnd.timeIntervalSince(fallBackStart) / 3600) {
            let date = fallBackStart.addingTimeInterval(Double(hour) * 3600)
            let position = focused.position(date)
            precondition(position > previous)
            precondition(abs(focused.date(at: position).timeIntervalSince(date)) < 0.001)
            previous = position
        }
        let vertices = focused.vertices([.init(date: fallBackStart, remaining: 100), .init(date: fallBackEnd, remaining: 0)])
        precondition(vertices.map(\.date) == [fallBackStart, focusStart, focusEnd, fallBackEnd])
        for point in vertices {
            let expected = 100 * (1 - point.date.timeIntervalSince(fallBackStart) / fallBackEnd.timeIntervalSince(fallBackStart))
            precondition(abs(point.remaining - expected) < 0.000001)
        }
        let shortFocus = PlanUsageFocusAxis(start: now, end: reset, focusStart: now, focusEnd: reset)
        precondition(shortFocus.breakDates.isEmpty && shortFocus.position(now) == 0 && shortFocus.position(reset) == 1)
        precondition(calendarAxis.label(for: calendarAxis.labelDates[0], timeZone: vienna).contains("Sat"))
        precondition(calendarAxis.label(for: calendarAxis.labelDates[1], timeZone: vienna).contains("Sun"))
        precondition(calendarAxis.label(for: calendarAxis.labelDates[2], timeZone: vienna).contains("Mon"))
        precondition(calendarAxis.label(for: calendarAxis.labelDates[3], timeZone: vienna).contains("Tue"))
        let mondayReset = ResetCountdown.date(from: "2026-10-12T08:59:00Z")!
        let extendedAxis = PlanUsageTimeAxis(start: ResetCountdown.date(from: "2026-10-02T22:00:00Z")!, end: mondayReset, timeZone: vienna)
        precondition(extendedAxis.plotEnd > mondayReset)
        precondition(extendedAxis.labelDates.contains { extendedAxis.label(for: $0, timeZone: vienna).contains("Mon") })
        precondition(graph([]) == nil && graph([entry(600, .nan)]) == nil)
        precondition(graph([entry(600, 0, now)]) == nil)
        precondition(graph([entry(-600, 0)]) == nil)
        precondition(graph([entry(600, 0)], minutes: 0) == nil)
        let restarted = graph([entry(1200, 80), entry(900, 2), entry(600, 3)])!
        precondition(restarted.samples.count == 2 && restarted.samples.first!.remaining == 98)
        let shifted = graph([entry(1200, 60, reset.addingTimeInterval(-600)), entry(600, 3)])!
        precondition(shifted.samples.count == 1)
        let duplicate = graph([entry(600, 20), entry(600, 30)])!
        precondition(duplicate.samples.count == 1 && duplicate.last.remaining == 70)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let empty = "{\"version\":1,\"preferredAccountKey\":\"missing\",\"unscoped\":[],\"accounts\":{\"other\":[]}}"
        let document = try decoder.decode(PlanUsageHistoryDocument.self, from: Data(empty.utf8))
        precondition(document.selected.isEmpty)
        precondition(ResetCountdown.subscriptionDate("2026-11-05") == "Thu, Nov 5, 2026")
        precondition(ResetCountdown.subscriptionDate("2026-02-30") == nil)
        precondition(ResetCountdown.subscriptionDate("2026-11-05T07:59:00Z") != nil)
        let dated = Data(#"{"updatedAt":"2026-10-05T00:00:00Z","subscriptionRenewsAt":"2026-11-05T00:00:00Z","subscriptionRenewsAtIsDateOnly":true}"#.utf8)
        let billing = try JSONDecoder().decode(Usage.self, from: dated)
        precondition(billing.subscriptionRenewalValue == "2026-11-05")
        let legacy = try JSONDecoder().decode(Usage.self, from: Data("{}".utf8))
        precondition(legacy.subscriptionRenewalValue == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-history-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ key: String, version: Int = 1) throws {
            let value = "{\"version\":\(version),\"preferredAccountKey\":\"\(key)\",\"unscoped\":[],\"accounts\":{\"one\":[{\"name\":\"session\",\"windowMinutes\":300,\"entries\":[{\"capturedAt\":\"2026-10-05T00:00:00Z\",\"usedPercent\":20,\"resetsAt\":\"2026-10-05T05:00:00Z\"}]}],\"two\":[{\"name\":\"session\",\"windowMinutes\":300,\"entries\":[{\"capturedAt\":\"2026-10-05T00:00:00Z\",\"usedPercent\":70,\"resetsAt\":\"2026-10-05T05:00:00Z\"}]}]}}"
            try Data(value.utf8).write(to: dir.appendingPathComponent("codex.json"))
        }
        let reader = PlanUsageHistoryReader(directory: dir)
        try write("one")
        precondition(reader.read(provider: "codex").first?.entries.first?.usedPercent == 20)
        try write("two")
        precondition(reader.read(provider: "codex").first?.entries.first?.usedPercent == 70)
        try write("missing")
        precondition(reader.read(provider: "codex").isEmpty)
        try write("one", version: 2)
        precondition(reader.read(provider: "codex").isEmpty)
        precondition(reader.read(provider: "unsupported").isEmpty)
        // Previous finished window: display context only, found by its own reset boundary.
        let oldReset = now.addingTimeInterval(-600)
        let history = PlanUsageSeries(name: "session", windowMinutes: 300, entries: [
            PlanUsageEntry(capturedAt: oldReset.addingTimeInterval(-7200), usedPercent: 40, resetsAt: oldReset),
            PlanUsageEntry(capturedAt: oldReset.addingTimeInterval(-60), usedPercent: 90, resetsAt: oldReset),
            PlanUsageEntry(capturedAt: now.addingTimeInterval(-60), usedPercent: 0, resetsAt: now.addingTimeInterval(300 * 60 - 600))])
        let fresh = PlanUsageGraph(series: history, now: now)!
        precondition(fresh.samples.count == 1, "current window ignores the finished one")
        let finished = PlanUsageGraph.previous(series: history, before: fresh)!
        precondition(finished.reset == oldReset && finished.samples.map(\.remaining) == [60, 10])
        precondition(PlanUsageGraph.previous(series: PlanUsageSeries(name: "session", windowMinutes: 300, entries: [history.entries[2]]), before: fresh) == nil)
        print("Plan Usage checks passed: actual-time ticks and DST day boundaries, recorded endpoints, normalized progress, expired/future/missing windows, reset segments, duplicate captures, account isolation, date precision, previous window")
    }
}

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
        print("Plan Usage checks passed: recorded endpoints, normalized progress, expired/future/missing windows, reset segments, duplicate captures, account isolation, date precision")
    }
}

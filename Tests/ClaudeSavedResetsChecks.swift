import Foundation

@main enum ClaudeSavedResetsChecks {
    static func main() throws {
        func require(_ condition: Bool, line: UInt = #line) { precondition(condition, "Check failed at line \(line)") }
        let now = ResetCountdown.date(from: "2026-10-05T16:24:06Z")!
        let expiry = "Expires Oct 22 at 18:00"
        func usage(_ value: String? = "1 available", expiryText: String? = "Expires Oct 22 at 18:00",
                   capture: Date? = now, duplicate: Bool = false, legacy: Bool = false) throws -> Usage {
            var fields: [String: Any] = [:]
            if let capture { fields["updatedAt"] = ISO8601DateFormatter().string(from: capture) }
            if let value {
                var row: [String: Any] = ["label": "Limit Reset Credits", "value": value]
                if let expiryText { row["secondaryValue"] = expiryText }
                fields["details"] = [["rows": duplicate ? [row, row] : [row]]]
            }
            if legacy { fields["claudeResetCredits"] = ["availability": "available", "credits": [["label": "Full reset", "count": 99, "expiresAt": "2030-01-01", "clears": ["seven_day"]]]] }
            return try JSONDecoder().decode(Usage.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let vienna = TimeZone(identifier: "Europe/Vienna")!
        let estimated = ResetCountdown.estimatedSavedResetExpiry(expiry, capturedAt: now, timeZone: vienna)
        require(estimated == ResetCountdown.date(from: "2026-10-22T16:00:00Z"))
        require(ResetCountdown.estimatedSavedResetExpiry("Expires Oct 22 at 6:00 PM", capturedAt: now, timeZone: vienna) == estimated)
        require(ResetCountdown.estimatedSavedResetExpiry("Expires Feb 30 at 18:00", capturedAt: now, timeZone: vienna) == nil)
        require(ResetCountdown.estimatedSavedResetExpiry("Expires Oct 22 at 25:00", capturedAt: now, timeZone: vienna) == nil)
        require(ResetCountdown.estimatedSavedResetExpiry("Expires tomorrow", capturedAt: now, timeZone: vienna) == nil)
        let decemberCapture = ResetCountdown.date(from: "2026-12-31T12:00:00Z")!
        require(ResetCountdown.estimatedSavedResetExpiry("Expires Jan 2 at 18:00", capturedAt: decemberCapture, timeZone: vienna)
                == ResetCountdown.date(from: "2027-01-02T17:00:00Z"))
        let later = ResetCountdown.date(from: "2027-01-01T12:00:00Z")!
        require(ResetCountdown.estimatedSavedResetExpiryLine(expiry, capturedAt: now, now: later)?.contains("2026") == true)

        let fresh = try usage()
        let detail = fresh.claudeSavedResetDetail(at: now)!
        require(detail.count == 1 && detail.value == "1 available" && detail.expiryText == expiry)
        require(try usage("2 available").claudeSavedResetDetail(at: now)?.count == 2)
        require(try usage(expiryText: nil).claudeSavedResetDetail(at: now)?.expiryText == nil)
        for invalid in ["0 available", "Unavailable", "-1 available", "1.5 available", "01 available", "1", "2 available extra"] {
            require(try usage(invalid).claudeSavedResetDetail(at: now) == nil)
        }
        require(try usage(duplicate: true).claudeSavedResetDetail(at: now) == nil)
        require(try usage(capture: nil).claudeSavedResetDetail(at: now) == nil)
        require(try usage(capture: now.addingTimeInterval(1)).claudeSavedResetDetail(at: now) == nil)
        require(fresh.claudeSavedResetDetail(at: now.addingTimeInterval(119)) != nil)
        require(fresh.claudeSavedResetDetail(at: now.addingTimeInterval(120))?.isStale == true)
        require(fresh.claudeSavedResetDetail(at: now.addingTimeInterval(119))?.isStale == false)
        require(fresh.claudeSavedResetDetail(at: now.addingTimeInterval(3600))?.count == 1)
        let original = UsageEntry(provider: "claude", source: "web", account: "A", usage: fresh, error: nil)
        let refreshed = UsageEntry(provider: "claude", source: "codexbar-icloud", account: "A", usage: try usage("2 available"), error: nil)
        let switched = UsageEntry(provider: "claude", source: "web", account: "B", usage: try usage(nil), error: nil)
        require(original.rowIdentity == refreshed.rowIdentity)
        require(original.rowIdentity != switched.rowIdentity)
        require(switched.usage!.claudeSavedResetDetail(at: now) == nil)
        let redeemed = try usage(nil)
        require(redeemed.claudeSavedResetDetail(at: now) == nil)
        let legacy = try usage(nil, legacy: true)
        require(legacy.claudeSavedResetDetail(at: now) == nil)
        require(!String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("claudeResetCredits"))
        let payload = Payload(syncedAt: "2026-10-05T16:24:06Z", hostname: "Fixture", showUsed: false,
                              resetTimesShowAbsolute: false, usage: [UsageEntry(provider: "claude", source: "web", account: nil, usage: fresh, error: nil)])
        require(UsageJson.decodePayload(UsageJson.encode(payload)!) == payload)
        require(UsageJson.decodePayload(UsageJson.encode(payload)!)!.usage[0].usage!.claudeSavedResetDetail(at: now.addingTimeInterval(120))?.isStale == true)

        // Exercise the actual cache shape: generic details, numeric Foundation timestamps, no typed reset field.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-reset-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("engine-state.json")
        let sourceNow = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        func writeCache(_ row: Bool, capture: Date = sourceNow, legacyOnly: Bool = false) throws {
            let current = try usage(row ? "1 available" : nil, capture: capture, legacy: legacyOnly)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
            object["updatedAt"] = capture.timeIntervalSinceReferenceDate
            let snapshot: [String: Any] = ["schemaVersion": 1, "provider": "claude", "deviceID": "fixture", "displayLabel": "", "fetchedAt": sourceNow.timeIntervalSinceReferenceDate, "usage": object]
            try JSONSerialization.data(withJSONObject: ["fleetSnapshots": ["fixture": snapshot]]).write(to: file)
        }
        let reader = CodexBarCloudSyncReader(fileURL: file)
        try writeCache(true)
        require(reader.readPayload()!.usage[0].usage!.claudeSavedResetDetail(at: sourceNow)?.expiryText == expiry)
        try writeCache(false)
        require(reader.readPayload()!.usage[0].usage!.claudeSavedResetDetail(at: sourceNow) == nil)
        try writeCache(true, capture: sourceNow.addingTimeInterval(-180))
        // A new fetchedAt wrapper must not make old inventory appear freshly verified.
        require(reader.readPayload()!.usage[0].usage!.claudeSavedResetDetail(at: sourceNow)?.isStale == true)
        try writeCache(false, legacyOnly: true)
        require(reader.readPayload()!.usage[0].usage!.claudeSavedResetDetail(at: sourceNow) == nil)

        for path in CommandLine.arguments.dropFirst() {
            let entries = UsageJson.decode(try Data(contentsOf: URL(fileURLWithPath: path)))!
            let captured = entries.first!.usage!
            let at = ResetCountdown.date(from: captured.updatedAt!)!
            require(captured.claudeSavedResetDetail(at: at)?.count == 1)
            require(captured.claudeSavedResetDetail(at: at)?.expiryText?.hasPrefix("Expires ") == true)
        }
        print("PASS: actual CLI/cache shape, exact supplied count/expiry text, redemption clearing, stale/future/unknown captures, legacy compatibility, payload round trips")
    }
}

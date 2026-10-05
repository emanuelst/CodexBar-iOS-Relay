import Foundation

@main
struct CloudCreditsChecks {
    static func main() throws {
        let beforeExpiry = ResetCountdown.date(from: "2026-10-05T12:00:00Z")!
        let afterExpiry = ResetCountdown.date(from: "2026-11-06T12:00:00Z")!
        let json = #"[{"provider":"claude","usage":{"details":[{"title":"Cloud credits","rows":[{"id":"claude-cloud-credits","label":"Cloud credits","value":"$100.00 of $100.00 remaining","secondaryValue":"Expires 2026-11-05T07:59:00Z","usageValue":100,"progress":{"used":0,"total":100}}]}]}}]"#
        let entries = UsageJson.decode(Data(json.utf8))!
        let credit = entries[0].usage!.details![0].rows[0]
        precondition(credit.usageValue == 100)
        precondition(!credit.cloudCreditExpired(at: beforeExpiry))
        precondition(credit.cloudCreditExpired(at: afterExpiry))
        let payload = Payload(syncedAt: "2026-10-05T12:00:00Z", hostname: "Test", showUsed: false, resetTimesShowAbsolute: false, usage: entries)
        precondition(UsageJson.decodePayload(UsageJson.encode(payload)!) == payload)
        let legacyUsage = UsageJson.decode(Data(#"[{"provider":"claude","usage":{}}]"#.utf8))![0].usage!
        precondition(legacyUsage.details == nil)
        let zero = json.replacingOccurrences(of: "\"usageValue\":100", with: "\"usageValue\":0").replacingOccurrences(of: "\"used\":0", with: "\"used\":100")
        precondition(UsageJson.decode(Data(zero.utf8))![0].usage!.details![0].rows[0].usageValue == 0)
        // Exercise the preferred CloudKit-cache path with a synthetic, fresh snapshot.
        let usageObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries[0].usage!)) as! [String: Any]
        var snapshotUsage = usageObject
        snapshotUsage["updatedAt"] = Date().timeIntervalSinceReferenceDate
        let state: [String: Any] = ["fleetSnapshots": ["test": ["schemaVersion": 1, "provider": "claude", "deviceID": "test", "displayLabel": "", "fetchedAt": Date().timeIntervalSinceReferenceDate, "usage": snapshotUsage]]]
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: state).write(to: fixture)
        let cloudPayload = CodexBarCloudSyncReader(fileURL: fixture).readPayload()!
        precondition(cloudPayload.usage[0].usage!.details == entries[0].usage!.details)
        let devFixture = fixture.appendingPathExtension("dev")
        var devUsage = snapshotUsage
        devUsage["identity"] = ["accountID": "claude-owner-v1:dev-account"]
        devUsage["accountEmail"] = "dev@example.com"
        devUsage["subscriptionRenewsAt"] = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSinceReferenceDate
        devUsage["primary"] = ["usedPercent": 73]
        func writeDev(_ usage: [String: Any]?, generated: Date = Date()) throws {
            let selected: [String: Any] = usage.map { ["selected-claude": ["schemaVersion": 1, "provider": "claude", "deviceID": "dev", "displayLabel": "Dev", "fetchedAt": Date().timeIntervalSinceReferenceDate, "usage": $0]] } ?? [:]
            try JSONSerialization.data(withJSONObject: ["generatedAt": generated.timeIntervalSinceReferenceDate, "selectedOwnerID": "claude-owner-v1:dev-account", "fleetSnapshots": selected]).write(to: devFixture)
        }
        try writeDev(devUsage)
        let devPayload = CodexBarCloudSyncReader(fileURL: fixture, devFileURL: devFixture).readPayload()!
        precondition(devPayload.usage.count == 1)
        precondition(devPayload.usage[0].source == "codexbar-dev")
        precondition(devPayload.usage[0].usage!.accountEmail == "dev@example.com")
        precondition(devPayload.usage[0].usage!.primary!.usedPercent == 73)
        precondition(devPayload.usage[0].usage!.subscriptionRenewsAt != nil)
        devUsage["subscriptionRenewsAt"] = nil
        devUsage["subscriptionExpiresAt"] = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSinceReferenceDate
        devUsage["subscriptionExpiresAtIsDateOnly"] = true
        try writeDev(devUsage)
        let canceled = CodexBarCloudSyncReader(fileURL: fixture, devFileURL: devFixture).readPayload()!.usage[0].usage!
        precondition(canceled.subscriptionRenewsAt == nil && canceled.subscriptionExpiresAtIsDateOnly == true)
        try writeDev(nil)
        let cleared = CodexBarCloudSyncReader(fileURL: fixture, devFileURL: devFixture).readPayload()!.usage[0]
        precondition(cleared.source == "codexbar-icloud" && cleared.usage!.subscriptionRenewsAt == nil)
        try writeDev(devUsage, generated: Date().addingTimeInterval(-301))
        let fallback = CodexBarCloudSyncReader(fileURL: fixture, devFileURL: devFixture).readPayload()!.usage[0]
        precondition(fallback.source == "codexbar-icloud" && fallback.usage!.subscriptionExpiresAt == nil)
        print("PASS: selected Dev account replaces complete usage, cancellation precision, clear selection, stale fallback")
        print("PASS: legacy/cloud detail decoding, cloud cache forwarding, zero balance, expiry")
    }
}

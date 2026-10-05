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
        precondition(UsageJson.decode(Data(#"[{"provider":"claude","usage":{}}]"#.utf8))![0].usage!.details == nil)
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
        print("PASS: CLI decoding, old payloads, zero balance, expiry, JSON round-trip, CloudKit cache")
    }
}

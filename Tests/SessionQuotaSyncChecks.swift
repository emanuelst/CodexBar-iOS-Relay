import Foundation

@main enum SessionQuotaSyncChecks {
    static func main() throws {
        let legacy = Data(#"{"syncedAt":"2026-10-23T12:00:00Z","hostname":"Fixture","showUsed":false,"resetTimesShowAbsolute":false,"usage":[{"provider":"codex"}]}"#.utf8)
        let oldPayload = UsageJson.decodePayload(legacy)!
        precondition(oldPayload.usage[0].estimatedSessionQuotasLeft == nil)

        let entry = UsageEntry(provider: "claude", source: "fixture", account: nil,
                               usage: nil, error: nil, estimatedSessionQuotasLeft: 2.5)
        let payload = Payload(syncedAt: "2026-10-23T12:00:00Z", hostname: "Fixture",
                              showUsed: false, resetTimesShowAbsolute: false, usage: [entry])
        let roundTrip = UsageJson.decodePayload(UsageJson.encode(payload)!)!
        precondition(roundTrip.usage[0].estimatedSessionQuotasLeft == 2.5)
        print("PASS: legacy sync payloads decode and Mac forecast values round-trip for iOS")
    }
}

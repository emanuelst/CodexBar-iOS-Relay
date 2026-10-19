import Foundation

/// Owner and date-precision checks; no app startup, provider fetches, or user-data writes.
@main enum PlanUsageExpiryChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.addingTimeInterval(3600)
        let window = now.addingTimeInterval(-3600)...now.addingTimeInterval(7200)
        let iso = ISO8601DateFormatter()
        let key = "codex:v1:email-hash:143b53b0840f6e1fcf8537a38513b59a9f326c72f577f17d1da67393eff1d413"
        let claudeKey = "f6c23871d4b99436fbb7ec2a47da30fbe147d5377921967a2f619691339a0b51"
        func entry(_ provider: String = "codex", email: String? = "person@example.test", date: String? = nil,
                   dateOnly: Bool = false, capture: Date? = nil, plan: String? = "Pro", error: ApiError? = nil, identity: UsageIdentity? = nil) -> UsageEntry {
            UsageEntry(provider: provider, source: "test", account: nil,
                       usage: Usage(accountEmail: email, updatedAt: iso.string(from: capture ?? now), loginMethod: plan,
                                    primary: nil, secondary: nil, tertiary: nil, codexResetCredits: nil,
                                    subscriptionExpiresAt: date ?? iso.string(from: expiry), subscriptionExpiresAtIsDateOnly: dateOnly, identity: identity), error: error)
        }
        func result(_ entries: [UsageEntry], owner: String? = nil, provider: String = "codex",
                    range: ClosedRange<Date>? = nil, at: Date? = nil,
                    additionalHistoryKeys: Set<String> = []) -> Date? {
            let payload = Payload(syncedAt: iso.string(from: now), hostname: "Test", showUsed: false,
                                  resetTimesShowAbsolute: false, usage: entries)
            return PlanUsageExpiry.date(provider: provider, accountKey: owner ?? key, payload: payload,
                                        additionalHistoryKeys: additionalHistoryKeys,
                                        window: range ?? window, now: at ?? now)
        }
        precondition(result([entry()]) == expiry, "canonical email ownership retains the exact expiry")
        precondition(result([entry()], owner: "143b53b0840f6e1fcf8537a38513b59a9f326c72f577f17d1da67393eff1d413") == expiry, "legacy Codex email hash")
        precondition(result([entry(email: "  PERSON@example.test  ")]) == expiry)
        precondition(result([entry("claude")], owner: claudeKey, provider: "claude") == expiry)
        precondition(result([entry("claude", plan: "Max")], owner: claudeKey, provider: "claude") == nil, "plan scope must match")
        precondition(result([entry(email: "other@example.test")]) == nil, "do not borrow another account's date")
        precondition(result([entry()], owner: "codex:v1:provider-account:another-owner") == nil, "unverified managed ownership is omitted")
        let managedKey = "codex:v1:provider-account:5304f0d0-82a0-49c2-8337-26483056f692"
        let accountCache = Data("""
        {"version":1,"records":[{"accountIdentity":{"normalizedEmail":"person@example.test","workspaceAccountID":"5304f0d0-82a0-49c2-8337-26483056f692"}}]}
        """.utf8)
        let aliases = PlanUsageExpiry.managedCodexHistoryKeys(
            payload: Payload(syncedAt: iso.string(from: now), hostname: "Test", showUsed: false,
                             resetTimesShowAbsolute: false, usage: [entry()]), cacheData: accountCache)
        precondition(aliases == [managedKey], "email-only sync identity resolves through the unique managed account cache")
        precondition(result([entry()], owner: managedKey, additionalHistoryKeys: aliases) == expiry)
        let ambiguousCache = Data("""
        {"version":1,"records":[{"accountIdentity":{"normalizedEmail":"person@example.test","workspaceAccountID":"workspace-a"}},{"accountIdentity":{"normalizedEmail":"person@example.test","workspaceAccountID":"workspace-b"}}]}
        """.utf8)
        precondition(PlanUsageExpiry.managedCodexHistoryKeys(
            payload: Payload(syncedAt: iso.string(from: now), hostname: "Test", showUsed: false,
                             resetTimesShowAbsolute: false, usage: [entry()]), cacheData: ambiguousCache).isEmpty,
                     "ambiguous email-to-workspace mappings do not expose a date on the wrong graph")
        precondition(result([entry()], owner: "__codexbar_unscoped__") == nil)
        precondition(result([entry(), entry()]) == nil, "ambiguous duplicate providers")
        precondition(result([entry("claude")]) == nil, "providers stay separate")
        precondition(result([entry(dateOnly: true)]) == nil, "date-only timestamps cannot invent a cutoff time")
        precondition(result([entry(date: "2027-01-15")]) == nil)
        precondition(result([entry(date: "invalid")]) == nil)
        precondition(result([entry(capture: now.addingTimeInterval(-301))]) == nil, "stale snapshot")
        precondition(result([entry(capture: now.addingTimeInterval(1))]) == nil, "future capture")
        precondition(result([entry(error: ApiError(kind: "test", code: nil, message: "offline"))]) == nil)
        precondition(result([entry()], at: expiry) == nil, "expired plan")
        precondition(result([entry()], range: now...expiry.addingTimeInterval(-1)) == nil, "expiry outside this quota window")
        precondition(result([entry()], range: now...expiry) == expiry, "cutoff equal to reset is visible")
        precondition(result([entry(date: "2027-01-15T10:00:00+01:00")]) == expiry, "timezone offset is preserved")
        precondition(result([entry(date: "2027-01-15T09:00:00.000Z")]) == expiry, "fractional seconds")
        precondition(PlanUsageExpiry.date(provider: "codex", accountKey: nil, payload: nil, window: window, now: now) == nil)
        let organizationKey = "5c0b23ac5837a615966b84550c597e0c9f92e30560a625528c7984b650c3a064"
        let org = UsageIdentity(providerID: "claude", accountEmail: "person@example.test", accountOrganization: "Example organization", loginMethod: "Claude Pro", accountID: nil)
        let owned = entry("claude", identity: org)
        precondition(result([owned], owner: organizationKey, provider: "claude") == expiry, "organization takes precedence over plan")
        precondition(result([owned], owner: claudeKey, provider: "claude") == nil, "organization must not fall back to plan ownership")
        precondition(result([entry("claude", plan: "Claude Pro")], owner: claudeKey, provider: "claude") == expiry, "branded plan")
        let wrongProvider = UsageIdentity(providerID: "claude", accountEmail: "person@example.test", accountOrganization: nil, loginMethod: nil, accountID: nil)
        precondition(result([entry(identity: wrongProvider)]) == nil, "identity provider mismatch")
        let conflictingEmail = UsageIdentity(providerID: "codex", accountEmail: "another@example.test", accountOrganization: nil, loginMethod: nil, accountID: nil)
        precondition(result([entry(identity: conflictingEmail)]) == nil, "conflicting direct and nested ownership")
        let managed = UsageIdentity(providerID: "codex", accountEmail: "person@example.test", accountOrganization: nil, loginMethod: nil, accountID: "workspace-example")
        precondition(result([entry(identity: managed)], owner: "codex:v1:provider-account:workspace-example") == expiry)
        precondition(result([entry(identity: managed)]) == nil, "workspace ownership must not fall back to email")
        let encoded = try JSONEncoder().encode(owned)
        let decoded = try JSONDecoder().decode(UsageEntry.self, from: encoded)
        precondition(decoded.usage?.identity == org, "Relay payload preserves the display-safe identity")
        print("PASS: plan-expiry account/provider/plan matching, canonical and legacy owners, exact dates, duplicates, stale snapshots and quota boundaries")
    }
}

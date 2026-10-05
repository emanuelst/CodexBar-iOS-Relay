import Foundation

// Subset of `codexbar usage --format json --provider all` payload.
// Extra keys are ignored by Codable.

public struct UsageEntry: Codable, Hashable {
    public let provider: String
    public let source: String?
    public let account: String?
    public let usage: Usage?
    public let error: ApiError?

    public init(provider: String, source: String?, account: String?, usage: Usage?, error: ApiError?) {
        self.provider = provider
        self.source = source
        self.account = account
        self.usage = usage
        self.error = error
    }

    public var hasUsage: Bool { usage != nil }

    /// Snapshot changes update the existing row; an account change creates a new row.
    public var rowIdentity: [String] {
        [provider, account ?? "", usage?.accountEmail ?? "", usage?.loginMethod ?? ""]
    }
}

public struct Usage: Codable, Hashable {
    public let accountEmail: String?
    public let updatedAt: String?
    public let loginMethod: String?
    public let primary: Limit?
    public let secondary: Limit?
    public let tertiary: Limit?
    /// Optional named quota lanes from CodexBar, such as GPT Reserve.
    public let extraRateWindows: [NamedLimit]?
    public let details: [UsageDetailSection]?
    public let codexResetCredits: CodexResetCredits?
    /// Optional provider-supplied subscription metadata. CodexBar may omit these.
    public let subscriptionRenewsAt: String?
    public let subscriptionExpiresAt: String?
    public let subscriptionRenewsAtIsDateOnly: Bool?
    public let subscriptionExpiresAtIsDateOnly: Bool?

    public init(accountEmail: String?, updatedAt: String?, loginMethod: String?, primary: Limit?, secondary: Limit?, tertiary: Limit?, extraRateWindows: [NamedLimit]? = nil, codexResetCredits: CodexResetCredits?, subscriptionRenewsAt: String? = nil, subscriptionExpiresAt: String? = nil, details: [UsageDetailSection]? = nil, subscriptionRenewsAtIsDateOnly: Bool? = nil, subscriptionExpiresAtIsDateOnly: Bool? = nil) {
        self.accountEmail = accountEmail
        self.updatedAt = updatedAt
        self.loginMethod = loginMethod
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraRateWindows = extraRateWindows
        self.details = details
        self.codexResetCredits = codexResetCredits
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionRenewsAtIsDateOnly = subscriptionRenewsAtIsDateOnly
        self.subscriptionExpiresAtIsDateOnly = subscriptionExpiresAtIsDateOnly
    }
    public var subscriptionRenewalValue: String? {
        billingValue(subscriptionRenewsAt, dateOnly: subscriptionRenewsAtIsDateOnly)
    }
    public var subscriptionExpirationValue: String? {
        billingValue(subscriptionExpiresAt, dateOnly: subscriptionExpiresAtIsDateOnly)
    }
    private func billingValue(_ value: String?, dateOnly: Bool?) -> String? {
        guard dateOnly == true, let value, let date = ResetCountdown.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public struct NamedLimit: Codable, Hashable {
    public let id: String
    public let title: String
    public let window: Limit
    /// Older Relay payloads omitted this field; absence means the usage is known.
    public let usageKnown: Bool?
}

/// Codex rate-limit reset credits (codex provider only). Lives under `usage`.
/// Modeled from the live CLI JSON — newer than the March source snapshot.
public struct CodexResetCredits: Codable, Hashable {
    public let availableCount: Int?
    public let credits: [ResetCredit]?
}

/// Display-only inventory supplied by current upstream's generic detail row.
/// The expiry is presentation text, not a machine-readable date or a redemption handle.
public struct ClaudeSavedResetDetail: Equatable {
    public let label: String
    public let value: String
    public let count: Int
    public let expiryText: String?
    public let isStale: Bool
}

extension Usage {
    /// This threshold marks inventory as last reported; it does not erase source data.
    /// A fresh wrapper timestamp never refreshes the underlying usage capture.
    public static let savedResetMaximumAge: TimeInterval = 120

    public func claudeSavedResetDetail(at now: Date) -> ClaudeSavedResetDetail? {
        guard let updatedAt, let capture = ResetCountdown.date(from: updatedAt),
              now.timeIntervalSince(capture) >= 0,
              let rows = details?.flatMap(\.rows).filter({ $0.label == "Limit Reset Credits" }),
              rows.count == 1, let row = rows.first
        else { return nil }
        let components = row.value.split(separator: " ", omittingEmptySubsequences: false)
        guard components.count == 2, components[1] == "available",
              let count = Int(components[0]), count > 0,
              String(count) == components[0] else { return nil }
        return ClaudeSavedResetDetail(label: row.label, value: row.value, count: count,
                                      expiryText: row.secondaryValue,
                                      isStale: now.timeIntervalSince(capture) >= Self.savedResetMaximumAge)
    }
}

public struct ResetCredit: Codable, Hashable {
    public let title: String?
    public let status: String?
    public let description: String?
    public let expiresAt: String?
    public let grantedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, status, description
        case expiresAt = "expires_at"
        case grantedAt = "granted_at"
    }
}

public struct Limit: Codable, Hashable {
    public let windowMinutes: Int?
    public let resetsAt: String?
    public let resetDescription: String?
    public let usedPercent: Double?
}

public struct ApiError: Codable, Hashable {
    public let kind: String?
    public let code: FlexStr?
    public let message: String?
}

/// Wrapper the macOS host serves to iOS over the LAN.
public struct Payload: Codable, Hashable {
    public let syncedAt: String      // ISO8601
    public let hostname: String
    public let showUsed: Bool        // false = show remaining (CodexBar default), true = bars fill as used
    public let resetTimesShowAbsolute: Bool  // false = countdown "in 2h 27m" (CodexBar default), true = absolute clock
    public let usage: [UsageEntry]
}

/// Accepts a JSON string or number and stores it as a String.
/// ponytail: codexbar's `error.code` is sometimes an int, sometimes a string.
public struct FlexStr: Codable, Hashable {
    public let value: String
    public init(_ s: String) { self.value = s }
    public init(from d: Decoder) throws {
        var c = try d.singleValueContainer()
        if let v: String = try? c.decode(String.self) { self.value = v; return }
        if let v: Double = try? c.decode(Double.self) { self.value = "\(v)"; return }
        self.value = ""
    }
    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        try c.encode(value)
    }
}

public enum UsageJson {
    public static func decode(_ data: Data) -> [UsageEntry]? {
        try? JSONDecoder().decode([UsageEntry].self, from: data)
    }

    public static func decodePayload(_ data: Data) -> Payload? {
        try? JSONDecoder().decode(Payload.self, from: data)
    }

    public static func encode(_ p: Payload) -> Data? {
        try? JSONEncoder().encode(p)
    }
}

/// Optional provider details shared by CLI and CodexBar's sync cache.
public struct UsageDetailSection: Codable, Hashable {
    public let title: String?
    public let rows: [UsageDetailRow]
}

public struct UsageDetailRow: Codable, Hashable {
    public let id: String?
    public let label: String
    public let value: String
    public let secondaryValue: String?
    public let usageValue: Double?
    public let progress: UsageDetailProgress?

    public var cloudCreditExpiry: String? {
        guard let secondaryValue, secondaryValue.hasPrefix("Expires ") else { return nil }
        let iso = String(secondaryValue.dropFirst("Expires ".count))
        return ResetCountdown.date(from: iso) != nil ? iso : nil
    }

    public func cloudCreditExpired(at now: Date) -> Bool {
        guard let iso = cloudCreditExpiry, let date = ResetCountdown.date(from: iso) else { return false }
        return date <= now
    }
}

public struct UsageDetailProgress: Codable, Hashable {
    public let used: Double
    public let total: Double
}

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
}

public struct Usage: Codable, Hashable {
    public let accountEmail: String?
    public let updatedAt: String?
    public let loginMethod: String?
    public let primary: Limit?
    public let secondary: Limit?
    public let tertiary: Limit?
    public let codexResetCredits: CodexResetCredits?

    public init(accountEmail: String?, updatedAt: String?, loginMethod: String?, primary: Limit?, secondary: Limit?, tertiary: Limit?, codexResetCredits: CodexResetCredits?) {
        self.accountEmail = accountEmail
        self.updatedAt = updatedAt
        self.loginMethod = loginMethod
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.codexResetCredits = codexResetCredits
    }
}

/// Codex rate-limit reset credits (codex provider only). Lives under `usage`.
/// Modeled from the live CLI JSON — newer than the March source snapshot.
public struct CodexResetCredits: Codable, Hashable {
    public let availableCount: Int?
    public let credits: [ResetCredit]?
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

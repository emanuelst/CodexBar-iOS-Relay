import Foundation

/// Reads the non-secret usage-snapshot cache maintained by CodexBar 0.47.0's
/// signed iCloud/CloudKit client. The Relay never talks to CloudKit directly;
/// CodexBar remains the entitled CloudKit client and this reader only consumes
/// its local, owner-readable cache.
struct CodexBarCloudSyncReader {
    /// A stale CloudKit cache must not mask a live local CodexBar CLI result.
    /// Relay polls every minute, so five minutes allows normal propagation while
    /// still letting the CLI fallback recover when CodexBar is not syncing.
    private static let maximumSnapshotAge: TimeInterval = 5 * 60

    private struct EngineState: Decodable {
        let generatedAt: Date?
        let selectedOwnerID: String?
        let fleetDevices: [String: Device]?
        let fleetSnapshots: [String: Snapshot]?
    }

    private struct Device: Decodable {
        let hostName: String
    }

    private struct Snapshot: Decodable {
        let schemaVersion: Int
        let provider: String
        let deviceID: String
        let displayLabel: String
        let fetchedAt: Date
        let usage: SnapshotUsage
    }

    private struct SnapshotUsage: Decodable {
        let details: [UsageDetailSection]?
        let primary: SnapshotLimit?
        let secondary: SnapshotLimit?
        let tertiary: SnapshotLimit?
        let extraRateWindows: [SnapshotNamedLimit]?
        let accountEmail: String?
        let loginMethod: String?
        let codexResetCredits: SnapshotResetCredits?
        let subscriptionRenewsAt: Date?
        let subscriptionExpiresAt: Date?
        let subscriptionRenewsAtIsDateOnly: Bool?
        let subscriptionExpiresAtIsDateOnly: Bool?
        let updatedAt: Date
    }

    private struct SnapshotLimit: Decodable {
        let windowMinutes: Int?
        let resetsAt: Date?
        let resetDescription: String?
        let usedPercent: Double?
        let isSyntheticPlaceholder: Bool?
    }

    private struct SnapshotNamedLimit: Decodable {
        let id: String
        let title: String
        let window: SnapshotLimit
        let usageKnown: Bool?
    }

    private struct SnapshotResetCredits: Decodable {
        let availableCount: Int?
        let credits: [SnapshotResetCredit]?
    }

    private struct SnapshotResetCredit: Decodable {
        let title: String?
        let status: String?
        let description: String?
        let expiresAt: Date?
        let grantedAt: Date?
        let id: String?
        let resetType: String?

        private enum CodingKeys: String, CodingKey {
            case title, status, description, id
            case expiresAt = "expires_at"
            case grantedAt = "granted_at"
            case resetType = "reset_type"
        }
    }

    private let fileURL: URL
    private let devFileURL: URL?
    private let decoder: JSONDecoder

    init(fileURL: URL = Self.defaultFileURL(), devFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.devFileURL = devFileURL ?? (fileURL == Self.defaultFileURL()
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/com.steipete.codexbar.debug/relay/selected-usage.json") : nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            if let string = try? container.decode(String.self),
               let date = ISO8601DateFormatter().date(from: string)
            {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected CloudKit snapshot date as seconds or ISO-8601 string")
        }
        self.decoder = decoder
    }

    func readPayload() -> Payload? {
        let state: EngineState
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? self.decoder.decode(EngineState.self, from: data) {
            state = decoded
        } else {
            state = EngineState(generatedAt: nil, selectedOwnerID: nil, fleetDevices: nil, fleetSnapshots: [:])
        }
        let snapshots = state.fleetSnapshots ?? [:]

        let now = Date()
        var freshSnapshots = snapshots.values.filter {
            $0.schemaVersion <= 1 && (0...Self.maximumSnapshotAge).contains(now.timeIntervalSince($0.fetchedAt))
        }
        // Dev supplies its own selected complete Claude snapshot. Never copy its dates
        // onto a signed producer's account, quota windows, or stale retained snapshot.
        var devSelected: Snapshot?
        if let devFileURL, let data = try? Data(contentsOf: devFileURL),
           let dev = try? decoder.decode(EngineState.self, from: data),
           let generatedAt = dev.generatedAt,
           (0...Self.maximumSnapshotAge).contains(now.timeIntervalSince(generatedAt)) {
            if let selected = dev.fleetSnapshots?["selected-claude"],
               selected.provider == "claude", selected.schemaVersion <= 1,
               dev.selectedOwnerID?.hasPrefix("claude-owner-v1:") == true,
               (0...Self.maximumSnapshotAge).contains(now.timeIntervalSince(selected.usage.updatedAt)) {
                freshSnapshots.removeAll { $0.provider == "claude" }
                freshSnapshots.append(selected)
                devSelected = selected
            }
        }
        guard !freshSnapshots.isEmpty else {
            let latest = snapshots.values.map(\.fetchedAt).max() ?? now
            FileHandle.standardError.write(
                Data(("[codexbarsync] CodexBar iCloud snapshot stale (\(Int(now.timeIntervalSince(latest)))s); using live CLI fallback\n").utf8))
            return nil
        }

        let devices = state.fleetDevices ?? [:]
        // The fleet cache can retain inactive account snapshots. CodexBar's main
        // menu shows one selected account per provider, so mirror that surface by
        // using the newest snapshot for each provider rather than rendering every
        // retained account as a duplicate provider row.
        let entries = Dictionary(grouping: freshSnapshots, by: \.provider)
            .compactMap { _, providerSnapshots in providerSnapshots.max { $0.fetchedAt < $1.fetchedAt } }
            .sorted { $0.provider < $1.provider }
            .map { snapshot in
                self.entry(for: snapshot, source: snapshot.provider == "claude" && devSelected != nil ? "codexbar-dev" : "codexbar-icloud")
            }

        guard !entries.isEmpty else { return nil }
        let latest = freshSnapshots.map(\.fetchedAt).max() ?? now
        let hostname = devices.values.first?.hostName
            ?? Host.current().localizedName
            ?? "Mac"
        return Payload(
            syncedAt: Self.iso8601.string(from: latest),
            hostname: hostname,
            showUsed: Self.codexbarShowUsed,
            resetTimesShowAbsolute: Self.codexbarResetAbsolute,
            usage: entries)
    }

    private func entry(for snapshot: Snapshot, source: String) -> UsageEntry {
        let usage = snapshot.usage
        return UsageEntry(
            provider: snapshot.provider,
            source: source,
            account: snapshot.displayLabel.isEmpty ? nil : snapshot.displayLabel,
            usage: Usage(
                accountEmail: usage.accountEmail,
                updatedAt: Self.iso8601.string(from: usage.updatedAt),
                loginMethod: usage.loginMethod,
                primary: self.knownLimit(usage.primary),
                secondary: self.knownLimit(usage.secondary),
                tertiary: self.knownLimit(usage.tertiary),
                extraRateWindows: usage.extraRateWindows?.map(self.namedLimit),
                codexResetCredits: usage.codexResetCredits.map(self.resetCredits),
                subscriptionRenewsAt: usage.subscriptionRenewsAt.map(Self.iso8601.string),
                subscriptionExpiresAt: usage.subscriptionExpiresAt.map(Self.iso8601.string),
                details: usage.details,
                subscriptionRenewsAtIsDateOnly: usage.subscriptionRenewsAtIsDateOnly,
                subscriptionExpiresAtIsDateOnly: usage.subscriptionExpiresAtIsDateOnly),
            error: nil)
    }

    private func resetCredits(_ value: SnapshotResetCredits) -> CodexResetCredits {
        CodexResetCredits(
            availableCount: value.availableCount,
            credits: value.credits?.map { credit in
                ResetCredit(
                    title: credit.title,
                    status: credit.status,
                    description: credit.description,
                    expiresAt: credit.expiresAt.map(Self.iso8601.string),
                    grantedAt: credit.grantedAt.map(Self.iso8601.string))
            })
    }

    private func limit(_ value: SnapshotLimit) -> Limit {
        Limit(
            windowMinutes: value.windowMinutes,
            resetsAt: value.resetsAt.map(Self.iso8601.string),
            resetDescription: value.resetDescription,
            usedPercent: value.usedPercent)
    }

    private func knownLimit(_ value: SnapshotLimit?) -> Limit? {
        guard let value, value.isSyntheticPlaceholder != true else { return nil }
        return self.limit(value)
    }

    private func namedLimit(_ value: SnapshotNamedLimit) -> NamedLimit {
        NamedLimit(
            id: value.id,
            title: value.title,
            window: self.limit(value.window),
            usageKnown: value.usageKnown)
    }

    static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.steipete.codexbar/sync/engine-state.json")
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var codexbarShowUsed: Bool {
        preference("usageBarsShowUsed", default: false)
    }

    private static var codexbarResetAbsolute: Bool {
        preference("resetTimesShowAbsolute", default: false)
    }

    private static func preference(_ key: String, default fallback: Bool) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.steipete.codexbar.plist")
        guard let values = NSDictionary(contentsOf: url) as? [String: Any] else { return fallback }
        return values[key] as? Bool ?? fallback
    }
}

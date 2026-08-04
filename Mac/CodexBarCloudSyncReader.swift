import Foundation

/// Reads the non-secret usage-snapshot cache maintained by CodexBar 0.47.0's
/// signed iCloud/CloudKit client. The Relay never talks to CloudKit directly;
/// CodexBar remains the entitled CloudKit client and this reader only consumes
/// its local, owner-readable cache.
struct CodexBarCloudSyncReader {
    private struct EngineState: Decodable {
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
        let primary: SnapshotLimit?
        let secondary: SnapshotLimit?
        let tertiary: SnapshotLimit?
        let accountEmail: String?
        let loginMethod: String?
        let codexResetCredits: SnapshotResetCredits?
        let subscriptionRenewsAt: Date?
        let subscriptionExpiresAt: Date?
        let updatedAt: Date
    }

    private struct SnapshotLimit: Decodable {
        let windowMinutes: Int?
        let resetsAt: Date?
        let resetDescription: String?
        let usedPercent: Double?
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
    private let decoder: JSONDecoder

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
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
        guard let data = try? Data(contentsOf: self.fileURL) else {
            return nil
        }
        let state: EngineState
        do {
            state = try self.decoder.decode(EngineState.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data(("[codexbarsync] CodexBar iCloud snapshot decode failed: \(error)\n").utf8))
            return nil
        }
        guard let snapshots = state.fleetSnapshots, !snapshots.isEmpty else {
            return nil
        }

        let devices = state.fleetDevices ?? [:]
        let entries = snapshots.values
            .filter { $0.schemaVersion <= 1 }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
                return lhs.fetchedAt > rhs.fetchedAt
            }
            .map { snapshot in
                self.entry(for: snapshot)
            }

        guard !entries.isEmpty else { return nil }
        let latest = snapshots.values.map(\.fetchedAt).max() ?? Date()
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

    private func entry(for snapshot: Snapshot) -> UsageEntry {
        let source = "codexbar-icloud"
        let usage = snapshot.usage
        return UsageEntry(
            provider: snapshot.provider,
            source: source,
            account: snapshot.displayLabel.isEmpty ? nil : snapshot.displayLabel,
            usage: Usage(
                accountEmail: usage.accountEmail,
                updatedAt: Self.iso8601.string(from: usage.updatedAt),
                loginMethod: usage.loginMethod,
                primary: usage.primary.map(self.limit),
                secondary: usage.secondary.map(self.limit),
                tertiary: usage.tertiary.map(self.limit),
                codexResetCredits: usage.codexResetCredits.map(self.resetCredits),
                subscriptionRenewsAt: usage.subscriptionRenewsAt.map(Self.iso8601.string),
                subscriptionExpiresAt: usage.subscriptionExpiresAt.map(Self.iso8601.string)),
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

import Foundation

/// Sync source preference.
/// ponytail: four explicit options, one disabled. No silent failure-triggered
/// fallback — `.auto` merges by freshest syncedAt among available sources, it
/// never swaps because a source errored.
public enum SyncSource: String, CaseIterable, Identifiable {
    case auto, lan, icloudDrive, icloudCloudKit
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Automatic"
        case .lan: "Local network"
        case .icloudDrive: "iCloud Drive"
        case .icloudCloudKit: "iCloud Sync"
        }
    }
    /// False for the CloudKit path that needs a paid account (shown greyed/coming-soon).
    public var isAvailable: Bool {
        switch self {
        case .icloudCloudKit: return false
        default: return true
        }
    }
    public var availabilityNote: String? {
        switch self {
        case .icloudCloudKit: return "Requires a paid Apple Developer account. Coming soon."
        default: return nil
        }
    }
}

public enum SyncPick {
    /// `.auto` = freshest syncedAt among the available sources (LAN + iCloud Drive).
    /// iCloud Drive edges ties so off-LAN stays usable. Other sources = that source only.
    public static func choose(_ source: SyncSource, lan: Payload?, iCloudDrive: Payload?) -> Payload? {
        switch source {
        case .lan: return lan
        case .icloudDrive: return iCloudDrive
        case .icloudCloudKit: return nil  // not available
        case .auto: return newer(lan, iCloudDrive)
        }
    }

    public static func newer(_ a: Payload?, _ b: Payload?) -> Payload? {
        guard let a else { return b }
        guard let b else { return a }
        let f = ISO8601DateFormatter()
        let ta = f.date(from: a.syncedAt)?.timeIntervalSince1970 ?? 0
        let tb = f.date(from: b.syncedAt)?.timeIntervalSince1970 ?? 0
        return tb >= ta ? b : a  // iCloud Drive wins ties
    }
}

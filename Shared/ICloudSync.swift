import Foundation

public enum RelayNetwork {
    /// Stable TCP port used by both Bonjour and direct/Tailscale connections.
    public static let defaultPort: UInt16 = 47892
}

/// Sync source preference.
/// `.auto` compares Bonjour LAN and iCloud Drive snapshots. Tailscale is explicit
/// because it needs a one-time MagicDNS host or tailnet IP in Settings.
public enum SyncSource: String, CaseIterable, Identifiable {
    case auto, lan, tailscale, icloudDrive, icloudCloudKit
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Automatic"
        case .lan: "Local network"
        case .tailscale: "Tailscale / direct"
        case .icloudDrive: "iCloud Drive"
        case .icloudCloudKit: "iCloud Sync"
        }
    }

    /// False for the CloudKit path that needs a paid account (shown greyed/coming-soon).
    public var isAvailable: Bool {
        switch self {
        case .icloudCloudKit: false
        default: true
        }
    }

    public var availabilityNote: String? {
        switch self {
        case .icloudCloudKit: "Requires a paid Apple Developer account. Coming soon."
        default: nil
        }
    }
}

public enum SyncPick {
    /// `.auto` = freshest syncedAt among Bonjour LAN and iCloud Drive.
    /// Tailscale/direct is an explicit source because it needs configured routing.
    public static func choose(
        _ source: SyncSource,
        lan: Payload?,
        tailscale: Payload?,
        iCloudDrive: Payload?) -> Payload?
    {
        switch source {
        case .lan: lan
        case .tailscale: tailscale
        case .icloudDrive: iCloudDrive
        case .icloudCloudKit: nil
        case .auto: newer(lan, iCloudDrive)
        }
    }

    public static func newer(_ a: Payload?, _ b: Payload?) -> Payload? {
        guard let a else { return b }
        guard let b else { return a }
        let f = ISO8601DateFormatter()
        let ta = f.date(from: a.syncedAt)?.timeIntervalSince1970 ?? 0
        let tb = f.date(from: b.syncedAt)?.timeIntervalSince1970 ?? 0
        return tb >= ta ? b : a
    }
}

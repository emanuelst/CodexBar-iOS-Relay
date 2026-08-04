import Foundation

public enum RelayNetwork {
    /// Stable TCP port used by both Bonjour and direct/Tailscale connections.
    public static let defaultPort: UInt16 = 47892
}

/// Sync source preference.
/// `.auto` is the user-facing Network mode: Bonjour first, optional Tailscale
/// fallback, then iCloud Drive when no network snapshot is available.
public enum SyncSource: String, CaseIterable, Identifiable {
    case auto, icloudDrive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Network"
        case .icloudDrive: "iCloud Drive"
        }
    }

    public var isAvailable: Bool { true }
    public var availabilityNote: String? { nil }
}

public enum SyncPick {
    /// `.auto` prefers a reachable network snapshot and falls back to iCloud Drive.
    public static func choose(
        _ source: SyncSource,
        lan: Payload?,
        tailscale: Payload?,
        iCloudDrive: Payload?) -> Payload?
    {
        switch source {
        case .icloudDrive: iCloudDrive
        case .auto: lan ?? tailscale ?? iCloudDrive
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

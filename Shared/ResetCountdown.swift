import Foundation

/// Reset-time formatting matching CodexBar's `UsageFormatter.resetCountdownDescription`.
/// ponytail: replicated rather than parsing CodexBar's display string, since the CLI
/// payload only carries `resetsAt` (ISO) — the countdown is computed at display time.
public enum ResetCountdown {
    /// Accept both CodexBar's fractional-second timestamps and ordinary ISO-8601.
    public static func date(from iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
    /// "in 2h 27m", "in 5d 3h", "in 30m", "now". Matches CodexBar (ceil to minutes).
    public static func countdown(from iso: String, now: Date = .init()) -> String? {
        guard let d = date(from: iso) else { return nil }
        let seconds = max(0, d.timeIntervalSince(now))
        if seconds < 1 { return "now" }
        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }
        return "in \(totalMinutes)m"
    }

    /// Absolute clock form: today → "6:30 PM", tomorrow → "tomorrow, 6:30 PM",
    /// else abbreviated date+time. Matches CodexBar's `resetDescription`.
    public static func absolute(from iso: String, now: Date = .init()) -> String? {
        guard let d = date(from: iso) else { return nil }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) {
            return d.formatted(date: .omitted, time: .shortened)
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(d, inSameDayAs: tomorrow) {
            return "tomorrow, \(d.formatted(date: .omitted, time: .shortened))"
        }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    /// Full reset line honoring the style. Prefers `resetsAt`; falls back to the
    /// provider's `resetDescription` (e.g. "0 / 5000 messages") when no ISO time.
    public static func resetLine(for limit: Limit, showAbsolute: Bool, now: Date = .init()) -> String? {
        if let iso = limit.resetsAt,
           let absolute = absolute(from: iso, now: now),
           let relative = countdown(from: iso, now: now) {
            return "resets \(absolute) · \(relative)"
        }
        if let desc = limit.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            if desc.lowercased().hasPrefix("resets") { return desc }
            return "resets \(desc)"
        }
        return nil
    }
}


/// Shared freshness policy for snapshots written by the Mac host.
public enum SyncFreshness {
    public enum Level: Equatable {
        case fresh
        case aging
        case stale
        case unknown
    }

    public static let warningAfter: TimeInterval = 5 * 60
    public static let staleAfter: TimeInterval = 15 * 60

    public static func age(from iso: String, now: Date = .now) -> TimeInterval? {
        guard let date = ResetCountdown.date(from: iso) else { return nil }
        return max(0, now.timeIntervalSince(date))
    }

    public static func level(from iso: String, now: Date = .now) -> Level {
        guard let age = age(from: iso, now: now) else { return .unknown }
        if age >= staleAfter { return .stale }
        if age >= warningAfter { return .aging }
        return .fresh
    }

    public static func label(from iso: String, now: Date = .now) -> String {
        guard let age = age(from: iso, now: now) else { return "last sync unknown" }
        let prefix = age >= staleAfter ? "last synced" : "synced"
        if age < 5 { return "\(prefix) just now" }
        if age < 60 { return "\(prefix) \(Int(age))s ago" }
        if age < 3600 { return "\(prefix) \(Int(age / 60))m ago" }
        if age < 86400 { return "\(prefix) \(Int(age / 3600))h ago" }
        return "\(prefix) \(Int(age / 86400))d ago"
    }
}

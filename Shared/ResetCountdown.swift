import Foundation

/// Reset-time formatting matching CodexBar's `UsageFormatter.resetCountdownDescription`.
/// ponytail: replicated rather than parsing CodexBar's display string, since the CLI
/// payload only carries `resetsAt` (ISO) — the countdown is computed at display time.
public enum ResetCountdown {
    /// Labels the local timezone used when rendering absolute dates.
    public static func localTimeZoneLabel() -> String {
        let timeZone = TimeZone.current
        let offset = timeZone.secondsFromGMT()
        return "\(timeZone.identifier) \(localTimeZoneOffsetLabel(for: offset))"
    }

    /// Returns the local UTC offset used beside individual absolute dates.
    public static func localTimeZoneOffsetLabel() -> String {
        localTimeZoneOffsetLabel(for: TimeZone.current.secondsFromGMT())
    }

    private static func localTimeZoneOffsetLabel(for offset: Int) -> String {
        let sign = offset < 0 ? "-" : "+"
        let absoluteOffset = abs(offset)
        let hours = absoluteOffset / 3600
        let minutes = (absoluteOffset % 3600) / 60
        let minuteText = minutes == 0 ? "" : String(format: ":%02d", minutes)
        return "(UTC\(sign)\(hours)\(minuteText))"
    }

    /// Accept both CodexBar's fractional-second timestamps and ordinary ISO-8601.
    public static func date(from iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
    /// "in 2h 27m", "in 5d 3h", "in 30m", "now". Matches CodexBar (ceil to minutes).
    public static func countdown(from iso: String, now: Date = .init()) -> String? {
        guard let d = date(from: iso) else { return nil }
        return countdown(to: d, now: now)
    }

    /// Returns a compact countdown for an already decoded reset date.
    public static func countdown(to date: Date, now: Date = .init()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
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

    /// Consistent absolute form: "Sat, Oct 3 · 19:10 (UTC+2)".
    /// The year is included when it differs from the current year.
    public static func absolute(from iso: String, now: Date = .init()) -> String? {
        guard let d = date(from: iso) else { return nil }
        return absoluteDateTime(d, now: now)
    }

    /// Formats an absolute date consistently across reset, credit, and plan rows.
    public static func absoluteDateTime(_ date: Date, now: Date = .init()) -> String {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? "EEE, MMM d"
            : "EEE, MMM d, yyyy"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "HH:mm"

        let offset = TimeZone.current.secondsFromGMT(for: date)
        return "\(dateFormatter.string(from: date)) · \(timeFormatter.string(from: date)) \(localTimeZoneOffsetLabel(for: offset))"
    }

    /// Best-effort interpretation of upstream display text in the viewing device's timezone.
    /// Anchor the inferred year to the original capture so an old offer cannot roll forward on redraw.
    public static func estimatedSavedResetExpiry(_ text: String, capturedAt: Date,
                                                 timeZone: TimeZone = .current) -> Date? {
        let pattern = #"^Expires ([A-Za-z]{3}) ([0-9]{1,2}) at ([0-9]{1,2}):([0-9]{2})(?: (AM|PM))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let monthText = part(1), let index = months.firstIndex(of: monthText),
              let dayText = part(2), let day = Int(dayText), (1...31).contains(day),
              let hourText = part(3), var hour = Int(hourText),
              let minuteText = part(4), let minute = Int(minuteText), (0...59).contains(minute) else { return nil }
        if let period = part(5) {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (period == "PM" ? 12 : 0)
        } else if !(0...23).contains(hour) { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let capture = calendar.dateComponents([.year, .month, .day], from: capturedAt)
        guard var year = capture.year, let captureMonth = capture.month, let captureDay = capture.day else { return nil }
        let month = index + 1
        if month < captureMonth || (month == captureMonth && day < captureDay) { year += 1 }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date) == components else { return nil }
        return date
    }

    public static func estimatedSavedResetExpiryLine(_ text: String, capturedAt: Date,
                                                     now: Date = .init()) -> String? {
        guard let date = estimatedSavedResetExpiry(text, capturedAt: capturedAt) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            ? "EEE, MMM d · HH:mm" : "EEE, MMM d, yyyy · HH:mm"
        let iso = ISO8601DateFormatter().string(from: date)
        guard let countdown = countdown(from: iso, now: now) else { return nil }
        let estimate = countdown == "now" ? "around now" : countdown.replacingOccurrences(of: "in ", with: "in ~")
        return "expires \(formatter.string(from: date)) · \(estimate)"
    }

    /// Billing dates may be calendar dates. Preserve that precision without a timezone conversion.
    public static func subscriptionDate(_ value: String, now: Date = .init()) -> String? {
        if value.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
            formatter.dateFormat = "EEE, MMM d, yyyy"
            return formatter.string(from: date)
        }
        return absolute(from: value, now: now)
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

    public static func relativeAgeLabel(from iso: String, now: Date = .now) -> String {
        guard let age = age(from: iso, now: now) else { return "unknown" }
        if age < 5 { return "just now" }
        if age < 60 { return "\(Int(age))s ago" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        if age < 86400 { return "\(Int(age / 3600))h ago" }
        return "\(Int(age / 86400))d ago"
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

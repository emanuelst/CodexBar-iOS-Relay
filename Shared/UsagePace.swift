import Foundation

/// Run-out / pace intelligence, ported from CodexBar's `UsagePace` + `UsagePaceText`.
/// Pure math on fields the CLI payload already carries (usedPercent, resetsAt, windowMinutes).
/// ponytail: computed at display time (time-dependent ETA), same as ResetCountdown.
public struct UsagePace: Sendable {
    public enum Stage: Sendable, Equatable {
        case onTrack, slightlyAhead, ahead, farAhead, slightlyBehind, behind, farBehind
    }

    public let stage: Stage
    public let deltaPercent: Double
    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool

    /// Compute pace for any rate window. (Named `compute`, not `weekly` — the
    /// formula is window-agnostic; works for 5h primary or 7d secondary.)
    public static func compute(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: String,
        now: Date = .init(),
        defaultWindowMinutes: Int = 10080
    ) -> UsagePace? {
        guard let minutes = windowMinutes, minutes > 0 else { return nil }
        guard let reset = ISO8601DateFormatter().date(from: resetsAt) else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = reset.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset <= duration else { return nil }

        let elapsed = clamp(duration - timeUntilReset, lower: 0, upper: duration)
        let expected = clamp((elapsed / duration) * 100, lower: 0, upper: 100)
        let actual = clamp(usedPercent, lower: 0, upper: 100)
        if elapsed == 0, actual > 0 { return nil }

        let delta = actual - expected
        let stage = Self.stage(for: delta)

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        if elapsed > 0, actual > 0 {
            let rate = actual / elapsed
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let candidate = remaining / rate
                if candidate >= timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if elapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage,
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset)
    }

    private static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}

public enum UsagePaceText {
    /// Minimum expected usage before pace is shown (avoids early-window noise).
    /// Matches CodexBar's `minimumExpectedPercent`.
    private static let minimumExpectedPercent: Double = 3

    /// Full "Pace: … · …" line for a single rate window, or nil if pace isn't
    /// applicable. Per-window (primary/secondary/tertiary) — the math is identical
    /// for any window carrying windowMinutes + resetsAt with remaining > 0.
    /// Matches CodexBar 0.37+ which computes pace per window, not weekly-only.
    public static func summary(
        for limit: Limit,
        now: Date = .init()
    ) -> String? {
        guard let used = limit.usedPercent else { return nil }
        let remaining = max(0, 100 - used)
        guard remaining > 0 else { return nil }
        guard let resetsAt = limit.resetsAt else { return nil }

        guard let pace = UsagePace.compute(
            usedPercent: used,
            windowMinutes: limit.windowMinutes,
            resetsAt: resetsAt,
            now: now
        ) else { return nil }
        guard pace.expectedUsedPercent >= minimumExpectedPercent else { return nil }

        let left = leftLabel(for: pace)
        if let right = rightLabel(for: pace, now: now) {
            return "Pace: \(left) · \(right)"
        }
        return "Pace: \(left)"
    }

    private static func leftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        switch pace.stage {
        case .onTrack: return "On pace"
        case .slightlyAhead, .ahead, .farAhead: return "\(deltaValue)% in deficit"
        case .slightlyBehind, .behind, .farBehind: return "\(deltaValue)% in reserve"
        }
    }

    private static func rightLabel(for pace: UsagePace, now: Date) -> String? {
        if pace.willLastToReset { return "Lasts until reset" }
        guard let etaSeconds = pace.etaSeconds else { return nil }
        let date = now.addingTimeInterval(etaSeconds)
        let countdown = ResetCountdown.countdown(from: ISO8601DateFormatter().string(from: date), now: now) ?? "now"
        if countdown == "now" { return "Runs out now" }
        // countdown is "in 2h 30m" — strip "in " prefix to match CodexBar's durationText
        let dur = countdown.hasPrefix("in ") ? String(countdown.dropFirst(3)) : countdown
        return "Runs out in \(dur)"
    }
}

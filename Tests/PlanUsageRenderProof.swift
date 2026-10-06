import AppKit
import SwiftUI

/// Isolated native-hosted proof. No Relay controller, provider requests, sync writes or app relaunch.
@main enum PlanUsageRenderProof {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let now = Date()
        func history(_ name: String, _ duration: Int, _ offset: Double, _ used: [Double], fresh: Bool = false) -> PlanUsageSeries {
            let reset = now.addingTimeInterval(offset)
            let start = reset.addingTimeInterval(-Double(duration) * 60)
            let elapsed = now.timeIntervalSince(start)
            // `fresh` puts the last capture a minute before now, like a live recording.
            let entries = used.enumerated().map { i, value in
                let fraction = fresh ? Double(i + 1) / Double(used.count) : Double(i + 1) / Double(used.count + 1)
                return PlanUsageEntry(capturedAt: start.addingTimeInterval((fresh ? elapsed - 60 : elapsed) * fraction), usedPercent: value, resetsAt: reset)
            }
            return PlanUsageSeries(name: name, windowMinutes: duration, entries: entries)
        }
        var fixture = ["codex": [history("session", 300, 7200, [3, 8, 14, 25, 36, 48]), history("weekly", 10080, 3 * 86400, [5, 12, 20, 28])],
                       "claude": [history("session", 300, 11000, [2, 4, 9, 17]), history("weekly", 10080, 5 * 86400, [1, 3, 10, 18])]]
        // Mirrors the crowded live case: Now, a reset two minutes out, and two run-outs a minute apart.
        let collision = ["codex": [history("session", 300, 1800, [10, 20, 40, 75, 90, 97], fresh: true), history("weekly", 10080, 3 * 86400 + 1320, [15, 16, 18, 43, 60, 70], fresh: true)],
                         "claude": [history("session", 300, 120, [5, 10, 77, 91, 96, 97], fresh: true), history("weekly", 10080, 5 * 86400 + 43920, [10, 25, 30, 39], fresh: true)]]
        // A session that reset two minutes ago: one capture, nothing to draw a line from yet.
        var fresh = collision
        // History keeps the finished window, so Session can show it faintly for context.
        let finished = history("session", 300, -120, [10, 30, 55, 80, 97])
        let current = history("session", 300, 300 * 60 - 120, [0], fresh: true)
        fresh["codex"]![0] = PlanUsageSeries(name: "session", windowMinutes: 300, entries: finished.entries + current.entries)
        if CommandLine.arguments.contains("--recorded") {
            let reader = PlanUsageHistoryReader()
            fixture = ["codex": reader.read(provider: "codex"), "claude": reader.read(provider: "claude")]
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, provider, normalized, lane) in [
                ("codex", "Codex", false, "session"), ("claude", "Claude", false, "session"),
                ("combined", "Combined", false, "session"), ("normalized", "Combined", true, "session"),
                ("weekly", "Combined", false, "weekly"), ("weekly-normalized", "Combined", true, "weekly"),
                ("both", "Combined", false, "both"), ("both-small", "Combined", false, "both"),
                ("both-normalized", "Combined", true, "both"),
                ("collision-codex", "Codex", false, "session"), ("collision-codex-weekly", "Codex", false, "weekly"),
                ("collision-session", "Combined", false, "session"), ("collision-session-small", "Combined", false, "session"),
                ("collision-weekly", "Combined", false, "weekly"),
                ("collision-both", "Combined", false, "both"), ("collision-both-small", "Combined", false, "both"),
                ("fresh-session", "Combined", false, "session"), ("fresh-both", "Combined", false, "both"),
                ("fresh-codex", "Codex", false, "session")
            ] {
                let synthetic = name.hasPrefix("collision") ? collision : name.hasPrefix("fresh") ? fresh : fixture
                let data = CommandLine.arguments.contains("--recorded") ? fixture : synthetic
                let view = NSHostingView(rootView: PlanUsageWindow(fixture: data, provider: provider, normalized: normalized, lane: lane))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: name.hasSuffix("small") ? 580 : 680, height: 880), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Plan Usage"
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let capture = window.contentView!.superview!
                capture.layoutSubtreeIfNeeded()
                guard let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { fatalError("No bitmap") }
                capture.cacheDisplay(in: capture.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                try png.write(to: output.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                // Closing a newly created proof window only; no installed application is touched.
                window.orderOut(nil)
            }
        }
        print("Native hosted proofs saved to \(output.path)")
    }
}

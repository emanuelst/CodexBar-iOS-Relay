import AppKit
import SwiftUI

/// Isolated native-hosted proof. No Relay controller, provider requests, sync writes or app relaunch.
@main enum PlanUsageRenderProof {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let now = Date()
        func history(_ name: String, _ duration: Int, _ offset: Double, _ used: [Double]) -> PlanUsageSeries {
            let reset = now.addingTimeInterval(offset)
            let start = reset.addingTimeInterval(-Double(duration) * 60)
            let elapsed = now.timeIntervalSince(start)
            let entries = used.enumerated().map { i, value in
                PlanUsageEntry(capturedAt: start.addingTimeInterval(elapsed * Double(i + 1) / Double(used.count + 1)), usedPercent: value, resetsAt: reset)
            }
            return PlanUsageSeries(name: name, windowMinutes: duration, entries: entries)
        }
        var fixture = ["codex": [history("session", 300, 7200, [3, 8, 14, 25, 36, 48]), history("weekly", 10080, 3 * 86400, [5, 12, 20, 28])],
                       "claude": [history("session", 300, 11000, [2, 4, 9, 17]), history("weekly", 10080, 5 * 86400, [1, 3, 10, 18])]]
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
                ("weekly", "Combined", false, "weekly"), ("weekly-normalized", "Combined", true, "weekly")
            ] {
                let view = NSHostingView(rootView: PlanUsageWindow(fixture: fixture, provider: provider, normalized: normalized, lane: lane))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 880), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
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

import AppKit
import SwiftUI

/// Isolated synthetic view renders: no Relay controller, provider fetches, or sync writes.
@main enum PlanUsageExpiryRenderProof {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let now = Date()
        let iso = ISO8601DateFormatter()
        let providers = ["codex", "claude"]
        let entries = providers.map { id in
            UsageEntry(provider: id, source: "fixture", account: nil,
                       usage: Usage(accountEmail: "person@example.test", updatedAt: iso.string(from: now), loginMethod: "Pro",
                                    primary: nil, secondary: nil, tertiary: nil, codexResetCredits: nil,
                                    subscriptionExpiresAt: iso.string(from: now.addingTimeInterval(id == "codex" ? 3600 : 5400))), error: nil)
        }
        let payload = Payload(syncedAt: iso.string(from: now), hostname: "Test", showUsed: false, resetTimesShowAbsolute: false, usage: entries)
        let keys = Dictionary(uniqueKeysWithValues: entries.map { ($0.provider, PlanUsageExpiry.historyKeys(provider: $0.provider, usage: $0.usage!).sorted().first!) })
        func series(_ lane: String, minutes: Int, offset: Double) -> PlanUsageSeries {
            let reset = now.addingTimeInterval(offset)
            let start = reset.addingTimeInterval(-Double(minutes) * 60)
            let elapsed = now.timeIntervalSince(start)
            return PlanUsageSeries(name: lane, windowMinutes: minutes, entries: [10.0, 20, 28].enumerated().map { index, used in
                PlanUsageEntry(capturedAt: start.addingTimeInterval((elapsed - 30) * Double(index + 1) / 3), usedPercent: used, resetsAt: reset)
            })
        }
        let histories = Dictionary(uniqueKeysWithValues: providers.map { id in
            (id, [series("session", minutes: 300, offset: id == "codex" ? 7200 : 9000), series("weekly", minutes: 10080, offset: id == "codex" ? 3 * 86400 : 5 * 86400)])
        })
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, provider, lane, normalized) in [("single-session", "Codex", "session", false), ("combined-weekly", "Combined", "weekly", false), ("combined-both", "Combined", "both", false), ("normalized-weekly", "Combined", "weekly", true)] {
                let root = PlanUsageWindow(fixture: histories, provider: provider, normalized: normalized, lane: lane, payload: payload, accountKeys: keys)
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 880), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.title = "Plan Usage · Synthetic expiry fixture"
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let capture = window.contentView!.superview!
                capture.layoutSubtreeIfNeeded()
                guard let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { fatalError("No bitmap") }
                capture.cacheDisplay(in: capture.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                try png.write(to: output.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                window.orderOut(nil)
            }
        }
        print("Synthetic expiry view renders saved to \(output.path)")
    }
}

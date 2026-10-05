import AppKit
import SwiftUI

/// Native render of the inspected CLI data, frozen at its own capture time.
/// Does not launch Relay, redeem a reset, fetch provider data, or write sync state.
@main enum ClaudeSavedResetsRenderProof {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let entries = UsageJson.decode(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
        let entry = entries.first { $0.provider == "claude" }!
        let capturedAt = ResetCountdown.date(from: entry.usage!.updatedAt!)!
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: ProviderRow(entry: entry, showAbsolute: true, hidePersonalInfo: true, now: capturedAt).padding(20))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 390), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Claude usage"
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let capture = window.contentView!.superview!
            capture.layoutSubtreeIfNeeded()
            let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds)!
            capture.cacheDisplay(in: capture.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("claude-saved-resets-\(appearance == .aqua ? "light" : "dark").png"))
            window.orderOut(nil)
        }
        print("Native saved-reset row renders saved")
    }
}

import SwiftUI

/// Sets the hosting NSWindow to floating while `floating` is true.
/// ponytail: NSViewRepresentable to grab the window — no WindowGroup window-level API on macOS 14.
struct WindowFloatAccessor: NSViewRepresentable {
    @Binding var floating: Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { apply(nsView) }
    private func apply(_ v: NSView) {
        guard let w = v.window else { return }
        if floating {
            w.level = .floating
            w.collectionBehavior = []
            w.isMovableByWindowBackground = true
        } else {
            w.level = .normal
            w.collectionBehavior = []
            w.isMovableByWindowBackground = false
        }
    }
}


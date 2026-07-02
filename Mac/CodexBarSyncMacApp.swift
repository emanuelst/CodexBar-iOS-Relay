import SwiftUI
import Network

@main
struct CodexBarSyncMacApp: App {
    @StateObject private var sync = SyncController()

    var body: some Scene {
        WindowGroup {
            MacRootView().environmentObject(sync)
        }
        .defaultSize(width: 380, height: 560)

        MenuBarExtra {
            MenuBarContent().environmentObject(sync)
        } label: {
            Image(systemName: sync.lastError == nil ? "gauge.with.dots.needle.bottom.50percent" : "exclamationmark.triangle")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Sets the hosting NSWindow to floating + all-spaces while `floating` is true.
/// ponytail: NSViewRepresentable to grab the window — no WindowGroup window-level API on macOS 14.
private struct WindowFloatAccessor: NSViewRepresentable {
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
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isMovableByWindowBackground = true
        } else {
            w.level = .normal
            w.collectionBehavior = []
            w.isMovableByWindowBackground = false
        }
    }
}

private struct MacRootView: View {
    @EnvironmentObject var sync: SyncController
    @AppStorage("floatingMode") private var floatingMode = false

    var body: some View {
        VStack(spacing: 0) {
            if floatingMode { floatBanner }
            if let p = sync.payload {
                UsageListView(payload: p, statusText: nil, sourceBadge: sync.iCloudWriter.isConfigured ? "☁️ iCloud Drive" : nil)
            } else {
                UsageListView(payload: nil, searching: false, statusText: sync.lastError ?? "Starting…")
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 360, minHeight: 480)
        .background(WindowFloatAccessor(floating: $floatingMode))
    }

    private var floatBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin.fill").font(.caption2)
            Text("Always on top").font(.caption.bold())
            Spacer()
            Button { floatingMode = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.tint.opacity(0.12))
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(sync.lastError == nil ? Color.green : Color.orange).frame(width: 8, height: 8)
                if let d = sync.syncedAt {
                    Text("synced \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(sync.lastError ?? "running…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    floatingMode.toggle()
                } label: {
                    Image(systemName: floatingMode ? "pin.fill" : "pin")
                        .foregroundStyle(floatingMode ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(floatingMode ? "Turn off always-on-top" : "Keep window on top (super monitoring)")
                Menu {
                    Button("Choose iCloud Drive file…") { sync.iCloudWriter.pickFile() }
                    if sync.iCloudWriter.isConfigured {
                        Button("Stop writing to iCloud Drive") { sync.iCloudWriter.clear() }
                    }
                } label: {
                    Image(systemName: sync.iCloudWriter.isConfigured ? "icloud.fill" : "icloud")
                        .foregroundStyle(sync.iCloudWriter.isConfigured ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .help("iCloud Drive sync file")
                Button("Refresh") { Task { await sync.refreshNow() } }
                    .buttonStyle(.borderless)
            }
            .padding(8)
            if let s = sync.iCloudWriter.statusText, sync.iCloudWriter.isConfigured {
                HStack(spacing: 4) {
                    Image(systemName: "icloud").font(.caption2).foregroundStyle(.secondary)
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
            }
            if let e = sync.iCloudWriter.lastError {
                Text(e).font(.caption2).foregroundStyle(.orange).padding(.horizontal, 8).padding(.bottom, 6)
            }
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var sync: SyncController
    @AppStorage("floatingMode") private var floatingMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let d = sync.syncedAt {
                Text("Last sync: \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))")
            } else {
                Text("No sync yet")
            }
            if sync.serverOK {
                Text("Serving on :\(sync.serverPort)").font(.caption).foregroundStyle(.secondary)
            }
            if let e = sync.lastError {
                Text(e).foregroundStyle(.red).lineLimit(2)
            }
            Text("Auto-refresh every 60s").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        Divider()
        Button("Refresh now") { Task { await sync.refreshNow() } }
        Button("Open window") { NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Choose iCloud Drive file…") { sync.iCloudWriter.pickFile() }
        if sync.iCloudWriter.isConfigured {
            Button("Stop writing to iCloud Drive") { sync.iCloudWriter.clear() }
        }
        Divider()
        Button(floatingMode ? "Disable always-on-top" : "Enable always-on-top") { floatingMode.toggle() }
        Divider()
        Button("Quit CodexBar iOS Relay") { NSApp.terminate(nil) }
    }
}

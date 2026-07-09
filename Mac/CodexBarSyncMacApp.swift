import SwiftUI
import Network

enum ProviderVisibilityStore {
    static let key = "hiddenProvidersCSV"

    static var hiddenProviders: Set<String> {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        let ids = raw.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        return Set(ids)
    }

    static func toggle(_ provider: String) {
        var hidden = hiddenProviders
        if hidden.contains(provider) {
            hidden.remove(provider)
        } else {
            hidden.insert(provider)
        }
        let raw = hidden.sorted().joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: key)
    }

    static func isVisible(_ provider: String) -> Bool {
        !hiddenProviders.contains(provider)
    }
}

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

/// Sets the hosting NSWindow to floating while `floating` is true.
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
            w.collectionBehavior = []
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
    @AppStorage("hidePersonalInfo") private var hidePersonalInfo = false
    @AppStorage(ProviderVisibilityStore.key) private var hiddenProvidersCSV = ""

    var body: some View {
        VStack(spacing: 0) {
            if floatingMode { floatBanner }
            if let p = sync.payload {
                UsageListView(payload: p, statusText: nil, sourceBadge: sync.iCloudWriter.isConfigured ? "☁️ iCloud Drive" : nil, hidePersonalInfo: hidePersonalInfo)
            } else {
                UsageListView(payload: nil, searching: false, statusText: sync.lastError ?? "Starting…", hidePersonalInfo: hidePersonalInfo)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 360, minHeight: 480)
        .background(WindowFloatAccessor(floating: $floatingMode))
        .onChange(of: hiddenProvidersCSV) { _, _ in sync.refreshVisibility() }
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
                Menu {
                    providerVisibilityControls
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .help("Choose which providers to show")
                Toggle(isOn: $hidePersonalInfo) {
                    Image(systemName: hidePersonalInfo ? "eye.slash" : "eye")
                        .foregroundStyle(hidePersonalInfo ? Color.accentColor : Color.secondary)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(hidePersonalInfo ? "Show personal information" : "Hide personal information for screenshots")
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

    @ViewBuilder
    private var providerVisibilityControls: some View {
        if sync.availableProviders.isEmpty {
            Text("No providers yet").foregroundStyle(.secondary)
        } else {
            ForEach(sync.availableProviders, id: \.self) { provider in
                Button {
                    ProviderVisibilityStore.toggle(provider)
                    sync.refreshVisibility()
                } label: {
                    HStack {
                        Text(ProviderDisplayName.name(for: provider))
                        Spacer()
                        if ProviderVisibilityStore.isVisible(provider) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var sync: SyncController
    @AppStorage("floatingMode") private var floatingMode = false
    @AppStorage("hidePersonalInfo") private var hidePersonalInfo = false
    @AppStorage(ProviderVisibilityStore.key) private var hiddenProvidersCSV = ""

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
        .onChange(of: hiddenProvidersCSV) { _, _ in sync.refreshVisibility() }
        Divider()
        Button("Refresh now") { Task { await sync.refreshNow() } }
        Button("Open window") { NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Choose iCloud Drive file…") { sync.iCloudWriter.pickFile() }
        if sync.iCloudWriter.isConfigured {
            Button("Stop writing to iCloud Drive") { sync.iCloudWriter.clear() }
        }
        Divider()
        Menu("Providers") {
            if sync.availableProviders.isEmpty {
                Text("No providers yet")
            } else {
                ForEach(sync.availableProviders, id: \.self) { provider in
                    Button {
                        ProviderVisibilityStore.toggle(provider)
                        sync.refreshVisibility()
                    } label: {
                        HStack {
                            Text(ProviderDisplayName.name(for: provider))
                            Spacer()
                            if ProviderVisibilityStore.isVisible(provider) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
        Divider()
        Toggle(hidePersonalInfo ? "Show personal information" : "Hide personal information", isOn: $hidePersonalInfo)
        Divider()
        Button(floatingMode ? "Disable always-on-top" : "Enable always-on-top") { floatingMode.toggle() }
        Divider()
        Button("Quit CodexBar iOS Relay") { NSApp.terminate(nil) }
    }
}

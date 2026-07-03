import SwiftUI

@main
struct CodexBarSynciOSApp: App {
    @StateObject private var discovery = Discovery()
    @StateObject private var iCloud = ICloudDocumentStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(iCloud)
                .task { discovery.start() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var iCloud: ICloudDocumentStore
    @AppStorage("syncSource") private var syncSource: SyncSource = .auto
    @AppStorage("hidePersonalInfo") private var hidePersonalInfo = false
    @State private var showSettings = false

    private var display: Payload? {
        SyncPick.choose(syncSource, lan: discovery.payload, iCloudDrive: iCloud.payload)
    }

    /// Which source actually provided the current display data (for the badge).
    private var activeSourceLabel: String? {
        guard let display else { return nil }
        let f = ISO8601DateFormatter()
        let lanTime = discovery.payload.flatMap { f.date(from: $0.syncedAt) }
        let cloudTime = iCloud.payload.flatMap { f.date(from: $0.syncedAt) }
        switch syncSource {
        case .lan: return "Local"
        case .icloudDrive: return "iCloud Drive"
        case .auto:
            if let l = lanTime, let c = cloudTime {
                return l >= c ? "Auto · Local" : "Auto · iCloud Drive"
            }
            return lanTime != nil ? "Auto · Local" : (cloudTime != nil ? "Auto · iCloud Drive" : nil)
        case .icloudCloudKit: return nil
        }
    }

    private var searching: Bool {
        switch syncSource {
        case .lan: return discovery.payload == nil && discovery.lastError == nil
        case .icloudDrive:
            return iCloud.payload == nil && iCloud.lastError == nil && !iCloud.isDownloading
        case .auto:
            return discovery.payload == nil && iCloud.payload == nil
                && discovery.lastError == nil && iCloud.lastError == nil && !iCloud.isDownloading
        case .icloudCloudKit: return false
        }
    }

    private var statusText: String? {
        switch syncSource {
        case .lan: return discovery.lastError ?? "Searching for your Mac on the local network…"
        case .icloudDrive:
            if !iCloud.isConfigured { return "Pick an iCloud Drive file in Settings to start syncing." }
            if iCloud.isDownloading { return iCloud.lastError }
            if iCloud.payload == nil { return iCloud.lastError ?? "Waiting for the Mac to write the snapshot…" }
            return nil
        case .auto:
            if !iCloud.isConfigured && discovery.payload == nil {
                return discovery.lastError ?? "Searching local network. Add an iCloud Drive file in Settings to sync anywhere."
            }
            if iCloud.isDownloading { return iCloud.lastError }
            if discovery.payload == nil && iCloud.payload == nil { return "Searching local network and iCloud Drive…" }
            return nil
        case .icloudCloudKit: return nil
        }
    }

    var body: some View {
        NavigationStack {
            UsageListView(payload: display, searching: searching, statusText: statusText, sourceBadge: activeSourceLabel, hidePersonalInfo: hidePersonalInfo)
                .navigationTitle("CodexBar")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                .refreshable { await refreshCurrent() }
                .overlay(alignment: .bottom) {
                    if let e = bottomError {
                        Text(e)
                            .font(.caption2)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsSheet(syncSource: $syncSource, iCloud: iCloud)
                        .presentationDetents([.medium, .large])
                }
        }
    }

    private var bottomError: String? {
        switch syncSource {
        case .lan: return discovery.lastError
        case .icloudDrive: return iCloud.lastError
        case .auto: return (discovery.payload == nil && iCloud.payload == nil) ? (iCloud.lastError ?? discovery.lastError) : nil
        case .icloudCloudKit: return nil
        }
    }

    private func refreshCurrent() async {
        switch syncSource {
        case .lan: await discovery.refresh()
        case .icloudDrive: iCloud.refresh()
        case .auto:
            await discovery.refresh()
            iCloud.refresh()
        case .icloudCloudKit: break
        }
    }
}

private struct SettingsSheet: View {
    @Binding var syncSource: SyncSource
    @ObservedObject var iCloud: ICloudDocumentStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hidePersonalInfo") private var hidePersonalInfo = false
    @State private var showPicker = false

    private var showsFileSection: Bool {
        syncSource == .icloudDrive || syncSource == .auto
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(SyncSource.allCases) { src in
                        sourceRow(src)
                    }
                } footer: {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Toggle("Hide personal information", isOn: $hidePersonalInfo)
                    Text("Masks account emails and host name so screenshots are easier to share safely.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if showsFileSection {
                    Section("iCloud Drive file") {
                        if iCloud.isConfigured {
                            if let age = iCloud.snapshotAge {
                                LabeledContent("Snapshot") {
                                    Text(snapshotAgeText(age))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(staleColor(age))
                                }
                            }
                            if let e = iCloud.lastError {
                                Text(e).font(.caption).foregroundStyle(.orange)
                            }
                            Button("Pick a different file") { showPicker = true }
                            Button("Remove file", role: .destructive) { iCloud.clear() }
                        } else {
                            Button {
                                showPicker = true
                            } label: {
                                Label("Pick iCloud Drive file…", systemImage: "icloud")
                            }
                            if syncSource == .auto {
                                Text("Optional in Automatic mode — without it, only local network is used.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { url in iCloud.setPickedURL(url) }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ src: SyncSource) -> some View {
        Button {
            if src.isAvailable { syncSource = src }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(src.label)
                        .foregroundStyle(src.isAvailable ? .primary : .secondary)
                    if let note = src.availabilityNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if syncSource == src {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!src.isAvailable)
    }

    private var footer: String {
        switch syncSource {
        case .auto: "Uses whichever source has the freshest data — local network at home, iCloud Drive anywhere. Never silently falls back: it compares timestamps only."
        case .lan: "Finds your Mac via Bonjour on the same Wi-Fi/LAN. Fastest, but only when both devices are on the same network."
        case .icloudDrive: "Reads a snapshot file your Mac writes to iCloud Drive. Works anywhere, no shared network needed. Pick the same file on both devices. Read-only on iPhone."
        case .icloudCloudKit: "Proper iCloud sync via CloudKit — works anywhere with no file picking. Requires a paid Apple Developer account. Coming soon."
        }
    }

    private func snapshotAgeText(_ age: TimeInterval) -> String {
        if age < 60 { return "synced \(Int(age))s ago" }
        if age < 3600 { return "synced \(Int(age/60))m ago" }
        if age < 86400 { return "synced \(Int(age/3600))h ago" }
        return "synced \(Int(age/86400))d ago"
    }

    private func staleColor(_ age: TimeInterval) -> Color {
        switch age {
        case 600...: return .red      // ponytail: >10min stale = the Mac is likely asleep
        case 180...: return .orange
        default: return .secondary
        }
    }
}

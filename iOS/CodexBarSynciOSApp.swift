import SwiftUI

@main
struct CodexBarSynciOSApp: App {
    @StateObject private var discovery = Discovery()
    @StateObject private var iCloud = ICloudDocumentStore()
    @AppStorage("syncSource") private var syncSource: SyncSource = .auto
    @AppStorage("tailscaleHost") private var tailscaleHost = ""
    @AppStorage("tailscalePort") private var tailscalePort = Int(RelayNetwork.defaultPort)

    init() {
        // iCloud Drive is the reliable default. Preserve the user's later choice
        // after this one-time migration from the old automatic default.
        let defaults = UserDefaults.standard
        let migrationKey = "syncSourceDefaultVersion"
        if defaults.string(forKey: migrationKey) != "network-icloud-v2" {
            // Preserve an explicit iCloud Drive choice; old LAN, Tailscale,
            // Automatic, and disabled CloudKit choices become Network mode.
            if defaults.string(forKey: "syncSource") != SyncSource.icloudDrive.rawValue {
                defaults.set(SyncSource.auto.rawValue, forKey: "syncSource")
            }
            defaults.set("network-icloud-v2", forKey: migrationKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(iCloud)
                .task(id: syncConfigurationID) {
                    configureDiscovery()
                    while !Task.isCancelled {
                        if syncSource == .icloudDrive || syncSource == .auto {
                            iCloud.refresh()
                        }
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                    }
                }
        }
    }

    private var syncConfigurationID: String {
        "\(syncSource.rawValue)|\(tailscaleHost)|\(tailscalePort)"
    }

    private func configureDiscovery() {
        switch syncSource {
        case .auto:
            discovery.startAutomatic(
                tailscaleHost: tailscaleHost,
                port: UInt16(clamping: tailscalePort))
        case .icloudDrive:
            discovery.stop()
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
        SyncPick.choose(
            syncSource,
            lan: discovery.payload,
            tailscale: discovery.payload,
            iCloudDrive: iCloud.payload)
    }

    /// Which source actually provided the current display data (for the badge).
    private var activeSourceLabel: String? {
        guard let display else { return nil }
        switch syncSource {
        case .icloudDrive: return "iCloud Drive"
        case .auto:
            return discovery.payload != nil ? "Network" : (iCloud.payload != nil ? "iCloud Drive" : nil)
        }
    }

    private var searching: Bool {
        switch syncSource {
        case .auto:
            return discovery.payload == nil && iCloud.payload == nil
                && discovery.lastError == nil && iCloud.lastError == nil && !iCloud.isDownloading
        case .icloudDrive:
            return iCloud.payload == nil && iCloud.lastError == nil && !iCloud.isDownloading
        }
    }

    private var statusText: String? {
        switch syncSource {
        case .auto:
            if !iCloud.isConfigured && discovery.payload == nil {
                return discovery.lastError ?? "Trying the network. Add an iCloud Drive file for fallback sync."
            }
            if iCloud.isDownloading { return iCloud.lastError }
            if discovery.payload == nil && iCloud.payload == nil {
                return iCloud.lastError ?? discovery.lastError ?? "Trying the network and iCloud Drive…"
            }
            return nil
        case .icloudDrive:
            if !iCloud.isConfigured { return "Pick an iCloud Drive file in Settings to start syncing." }
            if iCloud.isDownloading { return iCloud.lastError }
            if iCloud.payload == nil { return iCloud.lastError ?? "Waiting for the Mac to write the snapshot…" }
            return nil
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
        case .auto: return (discovery.payload == nil && iCloud.payload == nil) ? (iCloud.lastError ?? discovery.lastError) : nil
        case .icloudDrive: return iCloud.lastError
        }
    }

    private func refreshCurrent() async {
        switch syncSource {
        case .auto:
            await discovery.refresh()
            iCloud.refresh()
        case .icloudDrive: iCloud.refresh()
        }
    }
}

private struct SettingsSheet: View {
    @Binding var syncSource: SyncSource
    @ObservedObject var iCloud: ICloudDocumentStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hidePersonalInfo") private var hidePersonalInfo = false
    @AppStorage("tailscaleHost") private var tailscaleHost = ""
    @AppStorage("tailscalePort") private var tailscalePort = Int(RelayNetwork.defaultPort)
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

                if syncSource == .auto {
                    Section("Optional Tailscale fallback") {
                        TextField("Mac Tailscale name or IP", text: $tailscaleHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", value: $tailscalePort, format: .number)
                            .keyboardType(.numberPad)
                        Text("Network mode tries Bonjour first, then this Tailscale name or IP if Bonjour is unavailable. The Mac Relay listens on port \(RelayNetwork.defaultPort).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                                Text("Optional in Network mode — without it, the app uses Bonjour and iCloud Drive fallback.")
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
        case .auto: "Tries the Mac Relay over the network (Bonjour, then optional Tailscale) and falls back to iCloud Drive."
        case .icloudDrive: "Reads a snapshot file your Mac writes to iCloud Drive. Works anywhere, no shared network needed. Read-only on iPhone."
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

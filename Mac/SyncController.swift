import Foundation
import Network
import SwiftUI

/// Owns the poller + LAN server + iCloud Drive writer and starts them on init so
/// they run regardless of whether a window is open. One ObservableObject the views
/// subscribe to.
@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var payload: Payload?
    @Published private(set) var syncedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var serverPort: UInt16 = 0
    @Published private(set) var serverOK = false

    private let poller = UsagePoller(interval: 60)
    private let server = LanServer()
    let iCloudWriter = ICloudDocumentWriter()
    private var rawPayload: Payload?

    init() {
        server.payloadProvider = { [weak self] in self?.servedData ?? Data("{}".utf8) }
        do {
            try server.start()
            serverOK = true
            serverPort = server.port
        } catch {
            lastError = "server: \(error)"
        }
        poller.onUpdate = { [weak self] in
            guard let self else { return }
            self.rawPayload = self.poller.payload
            self.payload = self.filteredPayload(self.poller.payload)
            self.syncedAt = self.poller.syncedAt
            self.lastError = self.poller.lastError
            if let p = self.payload {
                self.iCloudWriter.write(p)  // no-op until the user picks an iCloud Drive file
            }
        }
        poller.start()
    }

    var servedData: Data {
        guard let filtered = filteredPayload(rawPayload) else { return poller.servedData }
        return UsageJson.encode(filtered) ?? poller.servedData
    }

    var availableProviders: [String] {
        let ids = rawPayload?.usage.map(\.provider) ?? []
        return Array(Set(ids)).sorted { ProviderDisplayName.name(for: $0) < ProviderDisplayName.name(for: $1) }
    }

    func refreshVisibility() {
        payload = filteredPayload(rawPayload)
        if let p = payload {
            iCloudWriter.write(p)
        }
    }

    func refreshNow() async { await poller.poll() }

    private func filteredPayload(_ payload: Payload?) -> Payload? {
        guard let payload else { return nil }
        let hidden = ProviderVisibilityStore.hiddenProviders
        if hidden.isEmpty { return payload }
        return Payload(
            syncedAt: payload.syncedAt,
            hostname: payload.hostname,
            showUsed: payload.showUsed,
            resetTimesShowAbsolute: payload.resetTimesShowAbsolute,
            usage: payload.usage.filter { !hidden.contains($0.provider) }
        )
    }
}

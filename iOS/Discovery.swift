import Foundation
import Network
import SwiftUI

/// Browses Bonjour for `_codexbarrelay._tcp`, connects to the first Mac it finds,
/// and pulls `/usage` on a timer and on demand. Read-only viewer.
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var payload: Payload?
    @Published private(set) var hostname: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isSearching = true

    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var pollTask: Task<Void, Never>?

    func start() {
        guard browser == nil else { return }
        let desc = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_codexbarrelay._tcp", domain: nil)
        let b = NWBrowser(for: desc, using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            // ponytail: grab the first available Mac; ignore the changes set.
            if let r = results.first {
                Task { @MainActor [weak self] in
                    self?.adopt(r.endpoint, name: Self.browseName(r.endpoint))
                }
            }
        }
        b.stateUpdateHandler = { [weak self] st in
            Task { @MainActor [weak self] in
                if case .failed = st { self?.isSearching = true }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func refresh() async {
        guard let endpoint else { return }
        do {
            let data = try await LanHttpClient.get(endpoint: endpoint,
                                                    hostHeader: hostname ?? "codexbarsync",
                                                    path: "/usage")
            if let p = UsageJson.decodePayload(data) {
                self.payload = p
                self.hostname = p.hostname
                self.lastError = nil
                self.isSearching = false
            } else {
                self.lastError = "couldn't read stats"
            }
        } catch {
            self.lastError = "\(error)"
            self.payload = nil
        }
    }

    private func adopt(_ ep: NWEndpoint, name: String?) {
        if endpoint == nil || endpoint != ep {
            endpoint = ep
            if let name { hostname = name }
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
                }
            }
        }
    }

    private static func browseName(_ ep: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = ep { return name }
        return nil
    }
}

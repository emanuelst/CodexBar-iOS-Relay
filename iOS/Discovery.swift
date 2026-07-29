import Foundation
import Network
import SwiftUI

/// Connects either through Bonjour on the local LAN or directly to a stable host
/// and port (for example a Tailscale MagicDNS name). Pulls `/usage` every 15s.
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var payload: Payload?
    @Published private(set) var hostname: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isSearching = true

    private enum Mode: Equatable {
        case idle
        case bonjour
        case direct(host: String, port: UInt16)
    }

    private var mode: Mode = .idle
    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var pollTask: Task<Void, Never>?

    func startBonjour() {
        if mode == .bonjour, browser != nil { return }
        stop()
        mode = .bonjour
        beginBonjourBrowse()
    }

    func startDirect(host: String, port: UInt16) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            stop()
            lastError = "Add this Mac's Tailscale name or IP in Settings."
            isSearching = false
            return
        }
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            stop()
            lastError = "The direct connection port is invalid."
            isSearching = false
            return
        }

        let newMode = Mode.direct(host: host, port: port)
        if mode == newMode, endpoint != nil { return }
        stop()
        mode = newMode
        lastError = nil
        isSearching = true
        adopt(.hostPort(host: NWEndpoint.Host(host), port: networkPort), name: host)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        pollTask?.cancel()
        pollTask = nil
        endpoint = nil
        payload = nil
        hostname = nil
        mode = .idle
        isSearching = false
    }

    func refresh() async {
        guard let endpoint else {
            if mode == .bonjour { beginBonjourBrowse() }
            return
        }
        do {
            let data = try await LanHttpClient.get(
                endpoint: endpoint,
                hostHeader: hostname ?? "codexbarsync",
                path: "/usage")
            if let payload = UsageJson.decodePayload(data) {
                self.payload = payload
                self.hostname = payload.hostname
                self.lastError = nil
                self.isSearching = false
            } else {
                self.lastError = "Couldn't read stats from the Mac."
            }
        } catch {
            let prefix = if case .direct = mode { "Direct connection failed" } else { "Mac connection failed" }
            self.lastError = "\(prefix): \(error.localizedDescription)"
            self.isSearching = false
        }
    }

    private func beginBonjourBrowse() {
        guard mode == .bonjour, browser == nil else { return }
        lastError = nil
        isSearching = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_codexbarrelay._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            if let result = results.first {
                Task { @MainActor [weak self] in
                    self?.adopt(result.endpoint, name: Self.browseName(result.endpoint))
                }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready, .setup:
                    self.lastError = nil
                    self.isSearching = true
                case .waiting(let error):
                    self.lastError = "Local network access is unavailable: \(error.localizedDescription)"
                    self.isSearching = false
                case .failed(let error):
                    self.lastError = "Mac discovery failed: \(error.localizedDescription)"
                    self.isSearching = false
                    self.browser = nil
                    browser.cancel()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled, self?.mode == .bonjour else { return }
                        self?.beginBonjourBrowse()
                    }
                case .cancelled:
                    self.isSearching = false
                @unknown default:
                    self.isSearching = true
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func adopt(_ endpoint: NWEndpoint, name: String?) {
        if self.endpoint == nil || self.endpoint != endpoint {
            self.endpoint = endpoint
            if let name { hostname = name }
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
        }
    }

    private static func browseName(_ endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint { return name }
        return nil
    }
}

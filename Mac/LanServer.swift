import Foundation
import Network

/// Minimal dependency-free HTTP server on a stable port, Bonjour-advertised as
/// `_codexbarrelay._tcp`. The stable port also allows direct connections over
/// Tailscale, where Bonjour service discovery is not available.
final class LanServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "codexbarsync.lan", qos: .utility)
    var payloadProvider: () -> Data = { Data("{}".utf8) }
    private(set) var port: UInt16 = 0

    func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let relayPort = NWEndpoint.Port(rawValue: RelayNetwork.defaultPort) else {
            throw NSError(
                domain: "CodexBarRelay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid relay port"])
        }
        let listener = try NWListener(using: params, on: relayPort)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "CodexBarRelay",
            type: "_codexbarrelay._tcp"
        )
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = RelayNetwork.defaultPort
            case .failed:
                self?.port = 0
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, err in
            guard err == nil else { conn.cancel(); return }
            let req = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body: Data
            switch path {
            case "/health":
                body = Data("{\"ok\":true}".utf8)
            default:
                body = self?.payloadProvider() ?? Data("{}".utf8)
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }
}

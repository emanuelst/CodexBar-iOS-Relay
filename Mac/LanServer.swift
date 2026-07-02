import Foundation
import Network

/// Minimal dependency-free HTTP server on 0.0.0.0 (auto port), Bonjour-advertised
/// as `_codexbarrelay._tcp`. Serves `/usage` and `/health`. One client at a time
/// is plenty (the phone). ponytail: no streaming, no keep-alive, closes after each reply.
final class LanServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "codexbarsync.lan", qos: .utility)
    var payloadProvider: () -> Data = { Data("{}".utf8) }
    private(set) var port: UInt16 = 0

    func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "CodexBarRelay",
            type: "_codexbarrelay._tcp"
        )
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st, let p = listener.port {
                self?.port = UInt16(p.rawValue)
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

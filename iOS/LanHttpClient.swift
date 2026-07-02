import Foundation
import Network

/// Minimal HTTP-over-TCP GET using Network.framework. The macOS server speaks
/// plain HTTP/1.1 with Connection: close, so we read until the socket closes and
/// split off the body. ponytail: no Content-Length parsing, no chunked, no TLS.
enum LanHttpClient {
    static func get(endpoint: NWEndpoint, hostHeader: String, path: String) async throws -> Data {
        let conn = NWConnection(to: endpoint, using: .tcp)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let req = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                    readUntilClose(conn, into: Data(), cont: cont)
                case .failed(let err):
                    cont.resume(throwing: err)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func readUntilClose(_ conn: NWConnection, into acc: Data,
                                       cont: CheckedContinuation<Data, Error>) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
            if let err {
                cont.resume(throwing: err); return
            }
            var buf = acc
            if let data { buf.append(data) }
            if isComplete {
                if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                    cont.resume(returning: buf[sep.upperBound...])
                } else {
                    cont.resume(returning: buf)
                }
            } else {
                readUntilClose(conn, into: buf, cont: cont)
            }
        }
    }
}

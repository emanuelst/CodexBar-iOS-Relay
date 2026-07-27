import Foundation
import Network

/// Minimal HTTP-over-TCP GET using Network.framework. The macOS server speaks
/// plain HTTP/1.1 with Connection: close, so we read until the socket closes and
/// split off the body.
enum LanHttpClient {
    static func get(endpoint: NWEndpoint, hostHeader: String, path: String) async throws -> Data {
        let conn = NWConnection(to: endpoint, using: .tcp)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let lock = NSLock()
            var completed = false

            func finish(_ result: Result<Data, Error>) {
                lock.lock()
                guard !completed else {
                    lock.unlock()
                    return
                }
                completed = true
                lock.unlock()
                conn.cancel()
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure(let error): cont.resume(throwing: error)
                }
            }

            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let req = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
                    conn.send(content: Data(req.utf8), completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) }
                    })
                    readUntilClose(conn, into: Data(), finish: finish)
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func readUntilClose(_ conn: NWConnection, into acc: Data,
                                       finish: @escaping (Result<Data, Error>) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
            if let err {
                finish(.failure(err))
                return
            }
            var buf = acc
            if let data { buf.append(data) }
            if isComplete {
                if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                    finish(.success(Data(buf[sep.upperBound...])))
                } else {
                    finish(.success(buf))
                }
            } else {
                readUntilClose(conn, into: buf, finish: finish)
            }
        }
    }
}

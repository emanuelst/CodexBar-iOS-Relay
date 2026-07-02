import Foundation
import SwiftUI

@inline(__always)
private func logErr(_ s: String) {
    FileHandle.standardError.write(Data(("[codexbarsync] " + s + "\n").utf8))
}

/// Shells out to `codexbar usage --format json --provider all` every `interval`
/// and publishes a `Payload` ready to serve to iOS.
@MainActor
final class UsagePoller: ObservableObject {
    @Published private(set) var payload: Payload?
    @Published private(set) var lastError: String?
    @Published private(set) var syncedAt: Date?
    /// Called on the main actor after each poll (so a parent controller can mirror state).
    var onUpdate: (() -> Void)?

    let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    func start() {
        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func poll() async {
        do {
            let raw = try await runCodexbar()
            guard let entries = UsageJson.decode(raw) else {
                self.lastError = "decode failed (\(raw.count) bytes)"
                logErr("decode failed; first 200B: \(String(data: raw.prefix(200), encoding: .utf8) ?? "")")
                self.onUpdate?()
                return
            }
            let now = ISO8601DateFormatter().string(from: Date())
            let p = Payload(
                syncedAt: now,
                hostname: Host.current().localizedName ?? "Mac",
                showUsed: Self.codexbarShowUsed,
                resetTimesShowAbsolute: Self.codexbarResetAbsolute,
                usage: entries
            )
            self.payload = p
            self.syncedAt = Date()
            self.lastError = nil
            logErr("poll ok: \(entries.count) entries, \(raw.count) bytes")
        } catch {
            self.lastError = "\(error)"
            logErr("poll error: \(error)")
        }
        self.onUpdate?()
    }

    /// Pre-encoded JSON the server hands out per request (avoids re-encoding on every hit).
    var servedData: Data {
        UsageJson.encode(payload ?? Payload(syncedAt: ISO8601DateFormatter().string(from: Date()),
                                            hostname: Host.current().localizedName ?? "Mac",
                                            showUsed: Self.codexbarShowUsed,
                                            resetTimesShowAbsolute: Self.codexbarResetAbsolute,
                                            usage: []))
        ?? Data("{}".utf8)
    }

    /// Reads CodexBar's display preferences from its prefs plist.
    /// ponytail: reads the file directly instead of UserDefaults inter-process dance;
    /// staleness is irrelevant at a 60s poll. Defaults match CodexBar's defaults.
    static var codexbarShowUsed: Bool { pref("usageBarsShowUsed", default: false) }
    static var codexbarResetAbsolute: Bool { pref("resetTimesShowAbsolute", default: false) }

    private static func pref(_ key: String, default def: Bool) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.steipete.codexbar.plist")
        guard let d = NSDictionary(contentsOfFile: url.path) as? [String: Any] else { return def }
        return (d[key] as? Bool) ?? def
    }

    private func runCodexbar() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codexbar")
                p.arguments = ["usage", "--format", "json"]  // no --provider all: default honors CodexBar's in-app provider toggles
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    p.waitUntilExit()
                    // codexbar exits non-zero when some providers fail but still
                    // emits valid JSON for the rest — trust stdout, not the exit code.
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    if !data.isEmpty {
                        cont.resume(returning: data)
                    } else {
                        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        cont.resume(throwing: NSError(domain: "codexbar", code: Int(p.terminationStatus),
                                                      userInfo: [NSLocalizedDescriptionKey: "codexbar exited \(p.terminationStatus): \(e.prefix(200))"]))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

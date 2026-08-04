import Foundation
import SwiftUI

@inline(__always)
private func logErr(_ s: String) {
    FileHandle.standardError.write(Data(("[codexbarsync] " + s + "\n").utf8))
}

/// Reads CodexBar's 0.47.0 iCloud snapshot cache first, with the CLI path as a
/// compatibility fallback for older/unsigned CodexBar installations.
@MainActor
final class UsagePoller: ObservableObject {
    @Published private(set) var payload: Payload?
    @Published private(set) var lastError: String?
    @Published private(set) var syncedAt: Date?
    /// Called on the main actor after each poll (so a parent controller can mirror state).
    var onUpdate: (() -> Void)?

    let interval: TimeInterval
    private var timer: Timer?
    private var isPolling = false
    private struct CodexSubscriptionMetadata {
        let renewsAt: String?
        let expiresAt: String?
    }

    private var cachedCodexSubscriptionMetadata: CodexSubscriptionMetadata?
    private var nextCodexWebMetadataRefreshAt = Date.distantPast
    private static let webMetadataRefreshInterval: TimeInterval = 6 * 60 * 60
    private static let webMetadataRetryInterval: TimeInterval = 15 * 60
    private let cloudSyncReader = CodexBarCloudSyncReader()

    init(interval: TimeInterval = 60) {
        self.interval = interval
        self.cachedCodexSubscriptionMetadata = UsagePoller.loadCachedCodexSubscriptionMetadata()
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
        guard !isPolling else {
            logErr("poll skipped: previous poll still running")
            return
        }
        isPolling = true
        defer { isPolling = false }

        do {
            if let cloudPayload = cloudSyncReader.readPayload() {
                let payload = self.payloadWithCachedCodexMetadata(cloudPayload)
                self.payload = payload
                self.syncedAt = ResetCountdown.date(from: payload.syncedAt)
                self.lastError = nil
                logErr("CodexBar iCloud snapshot ok: \(payload.usage.count) entries")
                self.onUpdate?()
                return
            }

            let raw: Data
            do {
                raw = try await runCodexbar(
                    arguments: ["usage", "--format", "json", "--web-timeout", "15"],
                    timeout: 25)
            } catch {
                // One slow enabled provider must not prevent Codex/iCloud updates.
                // Codex auto is fast and retains OAuth reset-credit metadata.
                logErr("all-provider poll failed; falling back to codex auto: \(error)")
                raw = try await runCodexbar(
                    arguments: [
                        "usage", "--provider", "codex", "--source", "auto",
                        "--format", "json", "--web-timeout", "12",
                    ],
                    timeout: 18)
            }
            guard var entries = UsageJson.decode(raw) else {
                self.lastError = "decode failed (\(raw.count) bytes)"
                logErr("decode failed; first 200B: \(String(data: raw.prefix(200), encoding: .utf8) ?? "")")
                self.onUpdate?()
                return
            }
            entries = await replacingCodexWithCLIUsage(in: entries)
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
        Task { [weak self] in
            guard let self, let metadata = await self.codexWebSubscriptionMetadata() else { return }
            self.applyCodexWebSubscriptionMetadata(metadata)
        }
    }

    private func payloadWithCachedCodexMetadata(_ payload: Payload) -> Payload {
        guard cachedCodexSubscriptionMetadata != nil else { return payload }
        let usage = payload.usage.map { entry in
            guard entry.provider == "codex" else { return entry }
            return codexEntryWithMetadata(
                from: entry,
                fallback: nil,
                webMetadata: cachedCodexSubscriptionMetadata)
        }
        return Payload(
            syncedAt: payload.syncedAt,
            hostname: payload.hostname,
            showUsed: payload.showUsed,
            resetTimesShowAbsolute: payload.resetTimesShowAbsolute,
            usage: usage)
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

    private func replacingCodexWithCLIUsage(in entries: [UsageEntry]) async -> [UsageEntry] {
        do {
            let raw = try await runCodexbar(
                arguments: ["usage", "--provider", "codex", "--source", "cli", "--format", "json"],
                timeout: 15)
            guard let cliEntries = UsageJson.decode(raw),
                  let cliCodex = cliEntries.first(where: { $0.provider == "codex" && $0.usage != nil })
            else {
                logErr("codex cli replacement skipped: decode failed")
                return entries
            }

            let defaultCodex = entries.first { $0.provider == "codex" && $0.usage != nil }
            let mergedCodex = codexEntryWithMetadata(
                from: cliCodex,
                fallback: defaultCodex,
                webMetadata: cachedCodexSubscriptionMetadata)
            var result = entries.filter { $0.provider != "codex" }
            result.insert(mergedCodex, at: 0)
            logErr("codex cli replacement ok")
            return result
        } catch {
            logErr("codex cli replacement skipped: \(error)")
            return entries
        }
    }

    private func codexEntryWithMetadata(
        from cliCodex: UsageEntry,
        fallback defaultCodex: UsageEntry?,
        webMetadata: CodexSubscriptionMetadata?) -> UsageEntry
    {
        guard let cliUsage = cliCodex.usage else { return cliCodex }
        let fallbackUsage = defaultCodex?.usage
        let credits = cliUsage.codexResetCredits ?? fallbackUsage?.codexResetCredits
        let renewsAt = cliUsage.subscriptionRenewsAt ?? fallbackUsage?.subscriptionRenewsAt ?? webMetadata?.renewsAt
        let expiresAt = cliUsage.subscriptionExpiresAt ?? fallbackUsage?.subscriptionExpiresAt ?? webMetadata?.expiresAt
        guard credits != cliUsage.codexResetCredits
            || renewsAt != cliUsage.subscriptionRenewsAt
            || expiresAt != cliUsage.subscriptionExpiresAt
        else { return cliCodex }

        let mergedUsage = Usage(
            accountEmail: cliUsage.accountEmail,
            updatedAt: cliUsage.updatedAt,
            loginMethod: cliUsage.loginMethod,
            primary: cliUsage.primary,
            secondary: cliUsage.secondary,
            tertiary: cliUsage.tertiary,
            codexResetCredits: credits,
            subscriptionRenewsAt: renewsAt,
            subscriptionExpiresAt: expiresAt
        )
        return UsageEntry(
            provider: cliCodex.provider,
            source: cliCodex.source,
            account: cliCodex.account,
            usage: mergedUsage,
            error: cliCodex.error
        )
    }

    private static func loadCachedCodexSubscriptionMetadata() -> CodexSubscriptionMetadata? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.steipete.codexbar/openai-dashboard.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = root["snapshot"] as? [String: Any]
        else { return nil }
        let metadata = CodexSubscriptionMetadata(
            renewsAt: snapshot["subscriptionRenewsAt"] as? String,
            expiresAt: snapshot["subscriptionExpiresAt"] as? String)
        guard metadata.renewsAt != nil || metadata.expiresAt != nil else { return nil }
        return metadata
    }

    private func applyCodexWebSubscriptionMetadata(_ metadata: CodexSubscriptionMetadata) {
        guard let payload else { return }
        let usage = payload.usage.map { entry in
            guard entry.provider == "codex" else { return entry }
            return codexEntryWithMetadata(from: entry, fallback: nil, webMetadata: metadata)
        }
        guard usage != payload.usage else { return }
        self.payload = Payload(
            syncedAt: payload.syncedAt,
            hostname: payload.hostname,
            showUsed: payload.showUsed,
            resetTimesShowAbsolute: payload.resetTimesShowAbsolute,
            usage: usage)
        self.onUpdate?()
    }

    private func codexWebSubscriptionMetadata(now: Date = .now) async -> CodexSubscriptionMetadata? {
        if now < nextCodexWebMetadataRefreshAt {
            return cachedCodexSubscriptionMetadata
        }

        nextCodexWebMetadataRefreshAt = now.addingTimeInterval(Self.webMetadataRetryInterval)
        do {
            let raw = try await runCodexbar(
                arguments: [
                    "usage",
                    "--provider", "codex",
                    "--source", "web",
                    "--format", "json",
                    "--web-timeout", "60",
                ],
                timeout: 70)
            guard let entries = UsageJson.decode(raw),
                  let usage = entries.first(where: { $0.provider == "codex" })?.usage
            else {
                logErr("codex web metadata skipped: decode failed")
                return cachedCodexSubscriptionMetadata
            }

            let metadata = CodexSubscriptionMetadata(
                renewsAt: usage.subscriptionRenewsAt,
                expiresAt: usage.subscriptionExpiresAt
            )
            guard metadata.renewsAt != nil || metadata.expiresAt != nil else {
                logErr("codex web metadata skipped: subscription date missing")
                return cachedCodexSubscriptionMetadata
            }

            cachedCodexSubscriptionMetadata = metadata
            nextCodexWebMetadataRefreshAt = now.addingTimeInterval(Self.webMetadataRefreshInterval)
            logErr("codex web metadata ok")
            return metadata
        } catch {
            logErr("codex web metadata skipped: \(error)")
            return cachedCodexSubscriptionMetadata
        }
    }

    private func runCodexbar(arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
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
                continuation.resume(with: result)
            }

            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codexbar")
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty {
                    finish(.success(data))
                } else {
                    let stderr = String(
                        data: errors.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
                    finish(.failure(NSError(
                        domain: "codexbar",
                        code: Int(process.terminationStatus),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "codexbar exited \(process.terminationStatus): \(stderr.prefix(200))",
                        ])))
                }
            }

            do {
                try process.run()
            } catch {
                finish(.failure(error))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                finish(.failure(NSError(
                    domain: "codexbar",
                    code: 124,
                    userInfo: [NSLocalizedDescriptionKey: "codexbar timed out after \(Int(timeout))s"])))
            }
        }
    }
}

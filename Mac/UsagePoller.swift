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
    private struct CodexSubscriptionMetadata {
        let renewsAt: String?
        let expiresAt: String?
    }

    private var cachedCodexSubscriptionMetadata: CodexSubscriptionMetadata?
    private var nextCodexWebMetadataRefreshAt = Date.distantPast
    private static let webMetadataRefreshInterval: TimeInterval = 6 * 60 * 60
    private static let webMetadataRetryInterval: TimeInterval = 15 * 60

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
            let raw = try await runCodexbar(arguments: ["usage", "--format", "json"])
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
            let raw = try await runCodexbar(arguments: ["usage", "--provider", "codex", "--source", "cli", "--format", "json"])
            guard let cliEntries = UsageJson.decode(raw),
                  let cliCodex = cliEntries.first(where: { $0.provider == "codex" && $0.usage != nil })
            else {
                logErr("codex cli replacement skipped: decode failed")
                return entries
            }

            let defaultCodex = entries.first { $0.provider == "codex" && $0.usage != nil }
            let webMetadata = await codexWebSubscriptionMetadata()
            let mergedCodex = codexEntryWithMetadata(from: cliCodex, fallback: defaultCodex, webMetadata: webMetadata)
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

    private func codexWebSubscriptionMetadata(now: Date = .now) async -> CodexSubscriptionMetadata? {
        if now < nextCodexWebMetadataRefreshAt {
            return cachedCodexSubscriptionMetadata
        }

        nextCodexWebMetadataRefreshAt = now.addingTimeInterval(Self.webMetadataRetryInterval)
        do {
            let raw = try await runCodexbar(arguments: [
                "usage",
                "--provider", "codex",
                "--source", "web",
                "--format", "json",
                "--web-timeout", "60",
            ])
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

    private func runCodexbar(arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codexbar")
                p.arguments = arguments
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

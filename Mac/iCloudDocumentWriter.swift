import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Writes the usage payload as atomic JSON to a user-selected file in iCloud Drive.
/// ponytail: no CloudKit / app container — the user's own iCloud Drive syncs the file
/// to all their devices. Works on a free team: the access grant comes from the user
/// picking the file (NSSavePanel), persisted as a security-scoped bookmark so it
/// survives relaunch and works under App Sandbox once files.user-selected.read-write
/// is added for an App Store build.
@MainActor
final class ICloudDocumentWriter: ObservableObject {
    @Published private(set) var fileURL: URL?
    @Published private(set) var lastWrite: Date?
    @Published private(set) var lastError: String?

    private let bookmarkKey = "mac.iCloudDoc.bookmark"
    private var lastWrittenPayload: Payload?
    private var lastWrittenURL: URL?

    init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL } else { loadBookmark() }
    }

    var isConfigured: Bool { fileURL != nil }

    func statusText(now: Date) -> String? {
        if let url = fileURL {
            if let payload = lastWrittenPayload, lastWrittenURL == url {
                // Show the oldest known displayed provider capture, not the time we copied it.
                let capture = payload.usage.compactMap { $0.usage?.updatedAt }
                    .compactMap(ResetCountdown.date(from:)).min()
                let timestamp = capture.map { ISO8601DateFormatter().string(from: $0) } ?? payload.syncedAt
                return "\(url.lastPathComponent) · usage updated \(SyncFreshness.relativeAgeLabel(from: timestamp, now: now))"
            }
            return url.lastPathComponent
        }
        return nil
    }

    /// Presents a save panel seeded in the user's iCloud Drive so they can pick/create
    /// the snapshot file. The Mac writes changed snapshots; iOS reads the same file.
    func pickFile() {
        let panel = NSSavePanel()
        panel.title = "Choose CodexBar iOS Relay snapshot in iCloud Drive"
        panel.nameFieldStringValue = "codexbarsync.json"
        panel.allowedContentTypes = [.json]
        // ponytail: no entitlement needed to reach the user's general iCloud Drive —
        // it's just a filesystem path. forUbiquityContainerIdentifier would need the entitlement.
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        panel.directoryURL = FileManager.default.fileExists(atPath: cloud.path) ? cloud : nil
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url)
        fileURL = url
        lastError = nil
    }

    func clear() {
        fileURL = nil
        lastWrittenPayload = nil
        lastWrittenURL = nil
        lastWrite = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Atomic write so iOS never reads a half-written file. Called by SyncController
    /// after each successful poll.
    func write(_ payload: Payload) {
        guard let url = fileURL else { return }
        guard let data = UsageJson.encode(payload) else { lastError = "encode failed"; return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if lastWrittenURL == url, lastWrittenPayload == payload,
           FileManager.default.fileExists(atPath: url.path) {
            lastError = nil
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            lastWrite = Date()
            lastWrittenPayload = payload
            lastWrittenURL = url
            lastError = nil
        } catch {
            lastError = "write: \(error)"
        }
    }

    private func saveBookmark(for url: URL) {
        do {
            // ponytail: plain bookmark (options: []) — our app is unsandboxed on a free team,
            // and .withSecurityScope bookmarks only resolve under App Sandbox. Switch to
            // .withSecurityScope when we add the app-sandbox + files.user-selected.read-write
            // entitlements for an App Store build.
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            lastError = "bookmark: \(error)"
        }
    }

    private func loadBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            fileURL = url
            if stale { saveBookmark(for: url) }
        } catch {
            lastError = "bookmark: \(error)"
        }
    }
}

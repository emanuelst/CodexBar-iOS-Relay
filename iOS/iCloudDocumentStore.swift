import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Reads the usage payload from a user-picked iCloud Drive file (security-scoped
/// bookmark). Read-only. ponytail: no CloudKit/container — the user's own iCloud
/// Drive syncs the file the Mac writes; we read it with NSFileCoordinator, which
/// also handles waiting for the file to download from iCloud on first access.
@MainActor
final class ICloudDocumentStore: ObservableObject {
    @Published private(set) var payload: Payload?
    @Published private(set) var snapshotDate: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isDownloading = false

    private let bookmarkKey = "ios.iCloudDoc.bookmark"
    private var fileURL: URL?

    init() {
        loadBookmark()
        if fileURL != nil { refresh() }
    }

    var isConfigured: Bool { fileURL != nil }

    /// Seconds since the snapshot's syncedAt — used for stale/error display.
    var snapshotAge: TimeInterval? {
        snapshotDate.map { Date().timeIntervalSince($0) }
    }

    func refresh() {
        guard let url = fileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Trigger iCloud download if the file isn't local yet (tiny JSON → near-instant
        // once iCloud has it, but the first read after a change can race the download).
        let fm = FileManager.default
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
            isDownloading = true
            lastError = "Waiting for iCloud to download the file…"
            return
        }
        isDownloading = false

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var readData: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { newURL in
            readData = try? Data(contentsOf: newURL)
        }
        if let coordError {
            lastError = "read: \(coordError.localizedDescription)"
            return
        }
        guard let data = readData, !data.isEmpty, let p = UsageJson.decodePayload(data) else {
            lastError = "couldn't read snapshot"
            return
        }
        payload = p
        snapshotDate = ISO8601DateFormatter().date(from: p.syncedAt)
        lastError = nil
    }

    /// Persist a freshly-picked URL (called while the picker's security scope is still live).
    func setPickedURL(_ url: URL) {
        saveBookmark(for: url)
        fileURL = url
        refresh()
    }

    func clear() {
        fileURL = nil
        payload = nil
        snapshotDate = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private func saveBookmark(for url: URL) {
        do {
            // .minimalBookmark is the documented option for UIDocumentPicker URLs.
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
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

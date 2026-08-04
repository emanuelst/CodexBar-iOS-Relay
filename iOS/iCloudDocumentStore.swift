import Foundation
import Security
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
    private let keychainService = "com.changeme.codexbarrelay.ios"
    private let keychainAccount = "iCloudDocumentBookmark"
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
        guard scoped else {
            lastError = "iCloud file access expired or is unavailable. Pick the file again in Settings."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "The selected iCloud file is missing or was moved. Pick it again in Settings."
            return
        }

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
        snapshotDate = ResetCountdown.date(from: p.syncedAt)
        lastError = nil
    }

    /// Persist a freshly-picked URL (called while the picker's security scope is still live).
    func setPickedURL(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        saveBookmark(for: url)
        fileURL = url
        refresh()
    }

    func clear() {
        fileURL = nil
        payload = nil
        snapshotDate = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        deleteKeychainBookmark()
    }

    private func saveBookmark(for url: URL) {
        do {
            #if os(macOS)
            let bookmarkOptions: URL.BookmarkCreationOptions = [.minimalBookmark, .withSecurityScope]
            #else
            // iOS does not expose .withSecurityScope; the document picker grants
            // access to the picked URL and the bookmark preserves that selection.
            let bookmarkOptions: URL.BookmarkCreationOptions = [.minimalBookmark]
            #endif
            let data = try url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
            ]
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            item[kSecValueData as String] = data
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else {
                lastError = "bookmark: keychain error \(status)"
                return
            }
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        } catch {
            lastError = "bookmark: \(error)"
        }
    }

    private func loadBookmark() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var keychainResult: CFTypeRef?
        let keychainStatus = SecItemCopyMatching(query as CFDictionary, &keychainResult)
        let hasKeychainBookmark = keychainStatus == errSecSuccess
        let data = (hasKeychainBookmark ? keychainResult as? Data : nil)
            ?? UserDefaults.standard.data(forKey: bookmarkKey)
        guard let data else { return }
        var stale = false
        do {
            let url: URL
            #if os(macOS)
            do {
                url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                // Accept the pre-fix minimal bookmark once.
                url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            #else
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            fileURL = url
            if stale || !hasKeychainBookmark {
                let scoped = url.startAccessingSecurityScopedResource()
                saveBookmark(for: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        } catch {
            lastError = "bookmark: \(error)"
        }
    }
    private func deleteKeychainBookmark() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

}

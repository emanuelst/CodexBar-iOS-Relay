import Foundation

/// Observes both ordinary writes and atomic replacements without polling the provider.
/// If the cache does not exist yet, watches its nearest existing parent until it appears.
final class SnapshotFileWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.codexbarrelay.snapshot-watcher", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var observedData: Data?
    private var source: DispatchSourceFileSystemObject?

    init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
        self.observedData = try? Data(contentsOf: fileURL)
    }

    deinit { source?.cancel() }

    func start() {
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        lock.withLock { stopped = true }
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func watchURL() -> URL {
        var url = fileURL
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func arm() {
        guard !lock.withLock({ stopped }) else { return }
        source?.cancel()
        source = nil
        let url = watchURL()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        let next = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue)
        next.setEventHandler { [weak self, weak next] in
            guard let self, let next, self.source === next else { return }
            self.processChange()
            if next.data.contains(.rename) || next.data.contains(.delete)
                || self.needsRearm(descriptor: descriptor, url: url) {
                self.arm()
            }
        }
        // Reconcile after registration so a replacement made while arming is not lost.
        next.setRegistrationHandler { [weak self, weak next] in
            guard let self, let next, self.source === next else { return }
            self.processChange()
            if self.needsRearm(descriptor: descriptor, url: url) { self.arm() }
        }
        next.setCancelHandler { close(descriptor) }
        source = next
        next.resume()
    }

    private func needsRearm(descriptor: Int32, url: URL) -> Bool {
        guard watchURL() == url else { return true }
        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0, stat(url.path, &current) == 0 else { return true }
        return opened.st_dev != current.st_dev || opened.st_ino != current.st_ino
    }

    private func processChange() {
        let changed = lock.withLock {
            guard !stopped else { return false }
            let data = try? Data(contentsOf: fileURL)
            defer { observedData = data }
            return observedData != data
        }
        if changed { onChange() }
    }
}

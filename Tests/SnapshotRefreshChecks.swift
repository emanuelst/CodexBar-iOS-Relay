import Foundation

private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ data: Data) { lock.withLock { values.append(data) } }
    func contains(_ data: Data) -> Bool { lock.withLock { values.contains(data) } }
    var count: Int { lock.withLock { values.count } }
}

/// Uses synthetic files only: no provider calls, real preferences, LAN or iCloud access.
@main
enum SnapshotRefreshChecks {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-refresh-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("missing/sync/engine-state.json")
        let observations = Observations()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)
        let watcher = SnapshotFileWatcher(fileURL: file) {
            guard let data = try? Data(contentsOf: file) else { return }
            observations.append(data)
            // Replace inside the callback, before the watcher has rearmed its old inode.
            if data == second { try! third.write(to: file, options: .atomic) }
        }
        watcher.start()
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try first.write(to: file, options: .atomic)
        await waitUntil { observations.contains(first) }
        try second.write(to: file, options: .atomic)
        await waitUntil { observations.contains(third) }
        precondition(observations.contains(second))

        let inPlace = Data("in-place".utf8)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: inPlace)
        try handle.close()
        await waitUntil { observations.contains(inPlace) }

        // Missing/recreated sources are observed without a live CLI fallback.
        try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("old-cache"))
        try await Task.sleep(for: .milliseconds(100))
        let recreated = Data("recreated".utf8)
        try recreated.write(to: file, options: .atomic)
        await waitUntil { observations.contains(recreated) }
        watcher.stop()
        let stoppedCount = observations.count
        try Data("after-stop".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        precondition(observations.count == stoppedCount)

        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let old = now.addingTimeInterval(-180)
        func payload(captured: Date, used: Double = 98) -> Payload {
            let usage = Usage(accountEmail: nil, updatedAt: ISO8601DateFormatter().string(from: captured),
                              loginMethod: nil, primary: Limit(windowMinutes: 300, resetsAt: nil,
                                                              resetDescription: nil, usedPercent: used),
                              secondary: nil, tertiary: nil, codexResetCredits: nil)
            return Payload(syncedAt: ISO8601DateFormatter().string(from: now), hostname: "Fixture",
                           showUsed: false, resetTimesShowAbsolute: false,
                           usage: [UsageEntry(provider: "claude", source: "fixture", account: nil, usage: usage, error: nil)])
        }
        let destination = directory.appendingPathComponent("output.json")
        let writer = ICloudDocumentWriter(fileURL: destination)
        let original = payload(captured: old)
        writer.write(original)
        let firstWrite = writer.lastWrite
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        precondition(writer.statusText(now: now)?.contains("usage updated 3m ago") == true)
        writer.write(original)
        let unchangedAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        precondition(firstWrite == writer.lastWrite)
        precondition(originalAttributes[.systemFileNumber] as? UInt64 == unchangedAttributes[.systemFileNumber] as? UInt64)
        precondition(originalAttributes[.modificationDate] as? Date == unchangedAttributes[.modificationDate] as? Date)

        // A newer measurement with identical percentages still propagates its timestamp.
        let newer = payload(captured: now)
        writer.write(newer)
        let newerOutput = try Data(contentsOf: destination)
        precondition(UsageJson.decodePayload(newerOutput) == newer)
        precondition(writer.statusText(now: now)?.contains("usage updated just now") == true)
        let reset = payload(captured: now, used: 0)
        writer.write(reset)
        let resetOutput = try Data(contentsOf: destination)
        precondition(UsageJson.decodePayload(resetOutput) == reset)
        try FileManager.default.moveItem(at: destination, to: directory.appendingPathComponent("old-output.json"))
        writer.write(reset)
        let recreatedOutput = try Data(contentsOf: destination)
        precondition(UsageJson.decodePayload(recreatedOutput) == reset)

        let missingDestination = directory.appendingPathComponent("not-yet-created/output.json")
        let retryWriter = ICloudDocumentWriter(fileURL: missingDestination)
        retryWriter.write(original)
        precondition(retryWriter.lastWrite == nil && retryWriter.lastError != nil)
        try FileManager.default.createDirectory(at: missingDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        retryWriter.write(original)
        precondition(retryWriter.lastWrite != nil && retryWriter.lastError == nil)
        print("PASS: atomic replacements, callback races, in-place writes, missing/recreated cache, stop, output deduplication, freshness and failed-write retry")
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(condition(), "File change was not observed within three seconds")
    }
}

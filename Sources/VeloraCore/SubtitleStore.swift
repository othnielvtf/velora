import Foundation
import CryptoKit
import Darwin

/// Retains converted text tracks independently of a playback session's segment cache.
public struct SubtitleStore: Sendable {
    private static let version = "velora-webvtt-1"
    private static let documentLimit = 16 * 1024 * 1024
    private static let cacheLimit = 256 * 1024 * 1024
    private static let keyLocks = SubtitleKeyLocks()
    private let directory: URL

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public func load(source: SubtitleSource, tools: MediaTools, runner: MediaProcessRunner) throws -> SubtitleDocument {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fingerprint = try fingerprint(source)
        let cached = directory.appendingPathComponent("\(fingerprint.key).vtt")
        return try Self.keyLocks.withLock(for: cached.path) {
            if let document = try withCacheLock({ try readCached(cached) }) { return document }

            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            _ = try runner.run(tools.executable("ffmpeg"), arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts", "-start_at_zero",
                "-i", source.url.path, "-map", "0:\(source.streamIndex)", "-vn", "-an", "-dn",
                "-c:s", "webvtt", "-fs", "\(Self.documentLimit)", "-f", "webvtt", temporary.path
            ], timeout: Self.extractionTimeout(fileSize: fingerprint.size))
            try Task.checkCancellation()
            let document = try readDocument(temporary)
            guard try self.fingerprint(source).key == fingerprint.key else {
                throw VeloraError("The source file changed while preparing subtitles. Reopen it and try again.")
            }
            try withCacheLock {
                try Task.checkCancellation()
                // rename publishes a complete validated document, including when
                // another app process prepared the same track concurrently.
                guard Darwin.rename(temporary.path, cached.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                trimCache(protecting: cached)
            }
            return document
        }
    }

    static func extractionTimeout(fileSize: Int64) -> TimeInterval {
        min(12 * 3600, max(120, Double(max(0, fileSize)) / 5_000_000 + 60))
    }

    private func fingerprint(_ source: SubtitleSource) throws -> (key: String, size: Int64) {
        let url = source.url.resolvingSymlinksInPath().standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard url.isFileURL, values.isRegularFile == true, let size = values.fileSize,
              let modified = values.contentModificationDate else {
            throw VeloraError("The subtitle source must be an available local file.")
        }
        let fields = [Self.version, url.path, String(size), String(modified.timeIntervalSince1970.bitPattern),
                      source.id, String(source.streamIndex)]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\0").utf8))
        return (digest.map { String(format: "%02x", $0) }.joined(), Int64(size))
    }

    private func readCached(_ url: URL) throws -> SubtitleDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let document = try readDocument(url)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            trimCache(protecting: url)
            return document
        } catch is CancellationError { throw CancellationError() }
        catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func readDocument(_ url: URL) throws -> SubtitleDocument {
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < Self.documentLimit else {
            throw VeloraError("This subtitle track is empty or exceeds 16 MB.")
        }
        return try SubtitleDocument(webVTT: String(contentsOf: url, encoding: .utf8))
    }

    private func withCacheLock<T>(_ operation: () throws -> T) throws -> T {
        let lockURL = directory.appendingPathComponent(".index.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try operation()
    }

    private func trimCache(protecting protected: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        let cached = entries.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "vtt", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = cached.reduce(Int64(0)) { $0 + Int64($1.1) }
        for (url, size, _) in cached.sorted(by: { $0.2 < $1.2 }) where total > Int64(Self.cacheLimit) && url != protected {
            do {
                try FileManager.default.removeItem(at: url)
                total -= Int64(size)
            } catch { continue }
        }
    }
}

/// Reference counts keep the lock table bounded by current callers. Waiting
/// callers remain cancellable without blocking an unrelated source's extraction.
private final class SubtitleKeyLocks: @unchecked Sendable {
    private final class Entry {
        let lock = NSLock()
        var users = 0
    }
    private let registryLock = NSLock()
    private var entries: [String: Entry] = [:]

    func withLock<T>(for key: String, _ operation: () throws -> T) throws -> T {
        registryLock.lock()
        let entry = entries[key] ?? Entry()
        entry.users += 1; entries[key] = entry
        registryLock.unlock()
        defer {
            registryLock.lock()
            entry.users -= 1
            if entry.users == 0 { entries[key] = nil }
            registryLock.unlock()
        }
        while !entry.lock.try() {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { entry.lock.unlock() }
        try Task.checkCancellation()
        return try operation()
    }
}

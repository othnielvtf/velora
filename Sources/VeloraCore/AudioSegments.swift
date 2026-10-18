import Foundation

/// Encode AAC continuously across video chunks. A distant seek starts at that scene,
/// while each caller retains its run so concurrent requests cannot restart each other.
struct PreparedAudio: Sendable {
    let data: Data
    let runID: UUID
}

actor AudioSegments {
    private struct Key: Hashable { let runID: UUID; let index: Int }
    private struct Run {
        let id: UUID
        let directory: URL
        let start: Int
        var next: Int
        var requested: Int
        var consumers: Set<UUID>
        var lastRequested: Date
        let runner: MediaProcessRunner
        let task: Task<Void, Never>
        var finished = false
        var error: Error?
    }
    private let media: MediaInfo
    private let track: MediaTrack
    private let tools: MediaTools
    private let timeline: StreamTimeline
    private let directory: URL
    private var runs: [UUID: Run] = [:]
    private var monitors: [UUID: Task<Void, Never>] = [:]
    private var retired: [Task<Void, Never>] = []
    private var cache: [Key: (url: URL, bytes: Int64, touched: Date)] = [:]
    private var stopped = false
    private let cacheLimit: Int64 = 256 * 1024 * 1024

    init(media: MediaInfo, track: MediaTrack, tools: MediaTools, timeline: StreamTimeline, directory: URL) {
        self.media = media; self.track = track; self.tools = tools
        self.timeline = timeline; self.directory = directory
    }

    func segment(_ index: Int) async throws -> PreparedAudio {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let consumer = UUID()
        let runID: UUID
        if let current = runs.values.filter({ current in
            let cached = cache[Key(runID: current.id, index: index)]
            let available = cached.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
            return index >= current.start && (available || (!current.finished && index >= current.next && index <= current.next + 4))
        }).max(by: { $0.lastRequested < $1.lastRequested }) {
            runID = current.id
            runs[runID]?.requested = max(current.requested, index)
            runs[runID]?.consumers.insert(consumer)
            runs[runID]?.lastRequested = Date()
            updatePacing(runID)
        } else { runID = try start(at: index, consumer: consumer) }
        defer { runs[runID]?.consumers.remove(consumer) }
        while true {
            try Task.checkCancellation()
            guard !stopped, let current = runs[runID] else { throw CancellationError() }
            refresh(runID)
            if let data = try cached(index, runID: runID) { return data }
            if current.finished { throw current.error ?? VeloraError("The audio segment could not be prepared.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func cached(_ index: Int, runID: UUID) throws -> PreparedAudio? {
        let key = Key(runID: runID, index: index)
        guard let hit = cache[key], FileManager.default.fileExists(atPath: hit.url.path) else { return nil }
        cache[key]?.touched = Date()
        var data = try Data(contentsOf: hit.url)
        if index == timeline.count - 1, let run = runs[runID] {
            // A sub-frame video tail belongs to the preceding HLS chunk. AAC
            // still uses the fixed four-second grid, so include its closed tail.
            var tail = index + 1
            while FileManager.default.fileExists(atPath: run.directory.appendingPathComponent("audio-\(tail).ts").path) {
                data.append(try Data(contentsOf: run.directory.appendingPathComponent("audio-\(tail).ts")))
                tail += 1
            }
        }
        return PreparedAudio(data: data, runID: runID)
    }

    private func start(at index: Int, consumer: UUID) throws -> UUID {
        // Video has two encoder slots. Keep at most two audio runs, preserving any
        // run still awaited by the other slot during an overlapping seek request.
        if runs.count >= 2 {
            let idle = runs.values.filter { $0.consumers.isEmpty }
            guard let old = idle.min(by: { $0.requested < $1.requested }) else { throw CancellationError() }
            retire(old.id)
        }
        let id = UUID(), runner = MediaProcessRunner()
        let folder = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Eight seconds is both two video segments and exactly 375 AAC frames at
        // 48 kHz. Starting every run on this shared grid keeps odd/even segment
        // boundaries identical even when a receiver mixes previously cached runs.
        // Encode one extra grid block before the requested scene so encoder priming
        // and overlap state never enter a served chunk (except the movie's start).
        let encoderStart = max(0, (index / 2) * 2 - 2)
        let firstPlayable = encoderStart == 0 ? 0 : encoderStart + 2
        let start = timeline.start(encoderStart), remaining = media.duration - start
        let arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                         "-readrate", "8", "-ss", Self.number(media.videoStartOffset + start), "-i", media.source.path,
                         "-t", Self.number(remaining), "-map", "0:\(track.index)", "-vn", "-sn", "-dn",
                         "-af", "aresample=async=1:first_pts=0,apad", "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000",
                         "-output_ts_offset", Self.number(start + 1024.0 / 48000),
                         "-f", "segment", "-segment_time", Self.number(timeline.segmentDuration),
                         "-segment_format", "mpegts", "-segment_format_options", "mpegts_copyts=1:mpegts_flags=+resend_headers+initial_discontinuity",
                         "-segment_start_number", "\(encoderStart)", folder.appendingPathComponent("audio-%d.ts").path]
        let executable = try tools.executable("ffmpeg")
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try runner.run(executable, arguments: arguments, timeout: max(120, remaining + 120))
                await self?.complete(id, error: nil)
            } catch { await self?.complete(id, error: error) }
        }
        runs[id] = Run(id: id, directory: folder, start: firstPlayable, next: encoderStart, requested: index,
                       consumers: [consumer], lastRequested: Date(), runner: runner, task: task)
        monitors[id] = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, await self.poll(id) else { return }
            }
        }
        return id
    }

    private func complete(_ id: UUID, error: Error?) {
        guard runs[id] != nil else { return }
        runs[id]?.finished = true; runs[id]?.error = error
        refresh(id)
    }

    private func poll(_ id: UUID) -> Bool {
        guard runs[id] != nil, !stopped else { return false }
        refresh(id)
        return runs[id]?.finished == false
    }

    private func refresh(_ id: UUID) {
        guard var current = runs[id] else { return }
        while current.next < timeline.count {
            let index = current.next
            let file = current.directory.appendingPathComponent("audio-\(index).ts")
            let successor = current.directory.appendingPathComponent("audio-\(index + 1).ts")
            // The muxer closes a file before opening its successor. Never serve an open file.
            guard FileManager.default.fileExists(atPath: file.path),
                  index != timeline.count - 1 || (current.finished && current.error == nil),
                  FileManager.default.fileExists(atPath: successor.path) || (current.finished && current.error == nil) else { break }
            let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            cache[Key(runID: id, index: index)] = (file, bytes, Date())
            current.next += 1
        }
        runs[id] = current
        updatePacing(id)
        var total = cache.values.reduce(Int64(0)) { $0 + $1.bytes }
        for (index, entry) in cache.sorted(by: { $0.value.touched < $1.value.touched }) where total > cacheLimit {
            try? FileManager.default.removeItem(at: entry.url); total -= entry.bytes; cache[index] = nil
        }
    }

    private func updatePacing(_ id: UUID) {
        guard let current = runs[id], !current.finished else { return }
        // Bound speculative work even for day-long sources or a paused player.
        current.runner.setSuspended(current.next > current.requested + 8)
    }

    private func retire(_ id: UUID) {
        guard let current = runs.removeValue(forKey: id) else { return }
        current.runner.stop(); current.task.cancel()
        cache = cache.filter { $0.key.runID != id }
        let cleanup = Task.detached {
            await current.task.value
            try? FileManager.default.removeItem(at: current.directory)
        }
        retired.append(cleanup)
        monitors.removeValue(forKey: id)?.cancel()
    }

    func stop() async {
        stopped = true
        for id in Array(runs.keys) { retire(id) }
        for task in retired { await task.value }
        retired.removeAll(); cache.removeAll()
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

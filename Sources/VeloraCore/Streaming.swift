import Foundation

public struct StreamTimeline: Sendable {
    public let duration: Double
    public let segmentDuration: Double
    public let minimumFinalSegmentDuration: Double
    public init(duration: Double, segmentDuration: Double = 4, minimumFinalSegmentDuration: Double = 0) {
        precondition(duration.isFinite && duration > 0 && segmentDuration > 0)
        self.duration = duration; self.segmentDuration = segmentDuration
        self.minimumFinalSegmentDuration = min(segmentDuration, max(0, minimumFinalSegmentDuration))
    }
    public var count: Int {
        let proposed = Int(ceil(duration / segmentDuration))
        // A final interval shorter than one source frame may contain only the
        // previous frame's display duration. Keep it with that frame's chunk.
        let tail = duration - Double(proposed - 1) * segmentDuration
        return proposed > 1 && tail + 0.000000001 < minimumFinalSegmentDuration ? proposed - 1 : proposed
    }
    public func start(_ index: Int) -> Double { Double(index) * segmentDuration }
    public func length(_ index: Int) -> Double {
        index == count - 1 ? duration - start(index) : min(segmentDuration, duration - start(index))
    }
    public func playlist(segmentExtension: String = "ts") -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(Int(ceil(max(segmentDuration, length(count - 1)))))",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        // Encoding starts on an IDR, but the movie clock is continuous. TS
        // packet-counter resets are signaled inside the transport stream;
        // resetting the HLS timeline here also resets the subtitle clock.
        for index in 0..<count {
            lines.append(String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), length(index)))
            lines.append("segment-\(index).\(segmentExtension)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct SegmentEvent: Sendable {
    public let index: Int
    public let count: Int
    public let speed: Double
    public let cachedBytes: Int64
    public let cachedIndices: [Int]
}

actor EncoderGate {
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []
    private var stopped = false
    func acquire() async -> Bool {
        if stopped || Task.isCancelled { return false }
        if active < 2 { active += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(returning: false)
    }
    func release() {
        // A newly requested scene takes priority over older speculative reads.
        if !waiting.isEmpty { waiting.removeLast().1.resume(returning: !stopped) }
        else { active = max(0, active - 1) }
    }
    func stop() { stopped = true; waiting.forEach { $0.1.resume(returning: false) }; waiting.removeAll() }
}

public actor TranscodeSession {
    public nonisolated let token = UUID().uuidString.lowercased()
    public nonisolated let media: MediaInfo
    public nonisolated let quality: StreamQuality
    public nonisolated let timeline: StreamTimeline
    public nonisolated let directory: URL
    public nonisolated let audioTrack: MediaTrack?
    public nonisolated let subtitles: [SubtitleSource]
    private let tools: MediaTools
    private let gate = EncoderGate()
    private let subtitleGate = EncoderGate()
    private struct SegmentJob {
        let id: UUID
        let task: Task<(URL, Double, UUID?), Error>
        let runner: MediaProcessRunner
        var consumers: Set<UUID>
    }
    private var jobs: [Int: SegmentJob] = [:]
    private var retiredJobs: [Task<Void, Never>] = []
    private let audioSegments: AudioSegments?
    private var cache: [Int: (url: URL, bytes: Int64, touched: Date, audioID: UUID?)] = [:]
    private struct SubtitleJob {
        let id: UUID
        let task: Task<Void, Never>
        let runner: MediaProcessRunner
        var consumers: [UUID: CheckedContinuation<SubtitleDocument, Error>]
    }
    private var subtitleJobs: [String: SubtitleJob] = [:]
    private var retiredSubtitleJobs: [UUID: Task<Void, Never>] = [:]
    private var subtitleCache: [String: SubtitleDocument] = [:]
    private let subtitleStore: SubtitleStore
    private let onSubtitlePreparation: @Sendable (Bool) -> Void
    private var stopped = false
    private let onEvent: @Sendable (SegmentEvent) -> Void
    private let cacheLimit: Int64 = 1792 * 1024 * 1024

    public init(media: MediaInfo, quality: StreamQuality, tools: MediaTools,
                audioTrackIndex: Int? = nil, externalSubtitle: URL? = nil,
                cacheRoot: URL, onSubtitlePreparation: @escaping @Sendable (Bool) -> Void = { _ in },
                onEvent: @escaping @Sendable (SegmentEvent) -> Void = { _ in }) throws {
        self.media = media; self.quality = quality; self.tools = tools
        if let audioTrackIndex {
            guard let track = media.audioTracks.first(where: { $0.index == audioTrackIndex }) else {
                throw VeloraError("The selected audio track is unavailable.")
            }
            audioTrack = track
        } else { audioTrack = media.defaultAudioTrack }
        subtitles = media.subtitleTracks.filter(\.supportsTextSubtitles).map { SubtitleSource(media: media, track: $0) }
            + (externalSubtitle.map { [SubtitleSource(externalURL: $0)] } ?? [])
        self.timeline = StreamTimeline(duration: media.duration, minimumFinalSegmentDuration: 1 / media.frameRate)
        self.onEvent = onEvent
        self.onSubtitlePreparation = onSubtitlePreparation
        subtitleStore = SubtitleStore(directory: cacheRoot.appendingPathComponent("Subtitles"))
        directory = cacheRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let track = audioTrack {
            audioSegments = AudioSegments(media: media, track: track, tools: tools, timeline: timeline,
                                          directory: directory.appendingPathComponent("audio"))
        } else { audioSegments = nil }
    }

    public nonisolated func masterPlaylist() -> String {
        // Resolution is omitted because portrait/rotated sources may have different output geometry.
        var lines = ["#EXTM3U", "#EXT-X-VERSION:6"]
        lines += subtitles.map(\.mediaTag)
        lines += ["#EXT-X-STREAM-INF:BANDWIDTH=\(quality.bitRate + 800_000),CODECS=\"avc1.640029\(audioTrack == nil ? "" : ",mp4a.40.2")\"\(subtitles.isEmpty ? "" : ",SUBTITLES=\"subs\"")", "video.m3u8"]
        return lines.joined(separator: "\n") + "\n"
    }

    public func segment(_ index: Int) async throws -> URL {
        try Task.checkCancellation()
        guard !stopped, (0..<timeline.count).contains(index) else { throw VeloraError("Unknown video segment.") }
        if audioSegments == nil, let hit = cache[index], FileManager.default.fileExists(atPath: hit.url.path) {
            cache[index]?.touched = Date(); return hit.url
        }
        let consumer = UUID()
        let job: SegmentJob
        if var shared = jobs[index] {
            shared.consumers.insert(consumer); jobs[index] = shared; job = shared
        } else {
            let id = UUID(), processRunner = MediaProcessRunner()
            let media = media, quality = quality, tools = tools, directory = directory, timeline = timeline
            let gate = gate, audioSegments = audioSegments
            let hit = cache[index].flatMap { FileManager.default.fileExists(atPath: $0.url.path) ? $0 : nil }
            let task = Task.detached(priority: .userInitiated) { () throws -> (URL, Double, UUID?) in
                guard await gate.acquire() else { throw CancellationError() }
                do {
                    try Task.checkCancellation()
                    let scratch = directory.appendingPathComponent("work-\(id)")
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    let destination = directory.appendingPathComponent("segment-\(index)-\(id).ts")
                    let staged = scratch.appendingPathComponent("segment.ts")
                    let video = hit?.url ?? scratch.appendingPathComponent("video.ts")
                    let start = timeline.start(index), length = timeline.length(index)
                    let begin = Date()
                    // Retain the decoded frame preceding a seek. Expanding it
                    // to the 30 fps output clock before trimming also preserves
                    // long held frames in variable-frame-rate sources.
                    let filter = "setpts=PTS-\(Self.number(media.videoStartOffset))/TB,fps=30,trim=start=\(Self.number(start)):duration=\(Self.number(length)),setpts=PTS-STARTPTS,\(VideoFilter.make(media: media, quality: quality))"
                    var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                                "-copyts", "-start_at_zero", "-noaccurate_seek",
                                "-ss", Self.number(media.videoStartOffset + start), "-i", media.source.path, "-t", Self.number(length),
                                "-map", "0:V:0", "-an", "-sn", "-dn",
                                "-vf", filter,
                                "-r", "30", "-fps_mode", "cfr", "-c:v", "h264_videotoolbox", "-allow_sw", "0",
                                "-profile:v", "high", "-level:v", "4.1", "-pix_fmt", "yuv420p",
                                "-b:v", "\(quality.bitRate)", "-maxrate", "\(quality.bitRate + 500_000)",
                                "-bufsize", "\(quality.bitRate * 2)", "-g", "120", "-bf", "0",
                                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                                "-output_ts_offset", Self.number(start)]
                    let transport = ["-mpegts_copyts", "1", "-mpegts_flags", "+resend_headers+initial_discontinuity",
                                     "-muxdelay", "0", "-muxpreload", "0", "-f", "mpegts"]
                    args += transport + [video.path]
                    let executable = try tools.executable("ffmpeg")
                    if hit == nil { _ = try processRunner.run(executable, arguments: args) }
                    try Task.checkCancellation()
                    try Self.requireNonemptyOutput(video)
                    var audioID: UUID?
                    if let audioSegments {
                        let prepared = try await audioSegments.segment(index)
                        try Task.checkCancellation()
                        audioID = prepared.runID
                        if let hit, hit.audioID == audioID {
                            await gate.release()
                            return (hit.url, 0, audioID)
                        }
                        let audio = scratch.appendingPathComponent("audio.ts")
                        try prepared.data.write(to: audio)
                        try Task.checkCancellation()
                        _ = try processRunner.run(executable, arguments: [
                            "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts",
                            "-i", video.path, "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-c", "copy"
                        ] + transport + [staged.path])
                    } else { try FileManager.default.moveItem(at: video, to: staged) }
                    // Incomplete remux output belongs to scratch storage. Publish
                    // only a finished file so failed jobs cannot evade cache accounting.
                    try Task.checkCancellation()
                    try Self.requireNonemptyOutput(staged)
                    try FileManager.default.moveItem(at: staged, to: destination)
                    do { try Task.checkCancellation() }
                    catch { try? FileManager.default.removeItem(at: destination); throw error }
                    await gate.release()
                    return (destination, length / max(0.001, Date().timeIntervalSince(begin)), audioID)
                } catch { await gate.release(); throw error }
            }
            job = SegmentJob(id: id, task: task, runner: processRunner, consumers: [consumer])
            jobs[index] = job
        }
        return try await withTaskCancellationHandler {
            do {
                let (url, speed, audioID) = try await job.task.value
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                if jobs[index]?.id == job.id {
                    jobs[index] = nil
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    if let old = cache[index], old.url != url { try? FileManager.default.removeItem(at: old.url) }
                    cache[index] = (url, bytes, Date(), audioID)
                    trimCache(protecting: index)
                    onEvent(SegmentEvent(index: index, count: timeline.count, speed: speed,
                                         cachedBytes: cache.values.reduce(0) { $0 + $1.bytes }, cachedIndices: cache.keys.sorted()))
                }
                return url
            } catch {
                releaseConsumer(consumer, index: index, jobID: job.id)
                throw error
            }
        } onCancel: {
            Task { await self.releaseConsumer(consumer, index: index, jobID: job.id) }
        }
    }

    private func releaseConsumer(_ consumer: UUID, index: Int, jobID: UUID) {
        guard var job = jobs[index], job.id == jobID else { return }
        job.consumers.remove(consumer)
        if job.consumers.isEmpty {
            jobs[index] = nil; job.task.cancel(); job.runner.stop()
            let task = job.task
            let outputName = "segment-\(index)-\(jobID).ts"
            retiredJobs.append(Task.detached {
                if let (url, _, _) = try? await task.value, url.lastPathComponent == outputName {
                    try? FileManager.default.removeItem(at: url)
                }
            })
        } else { jobs[index] = job }
    }

    private nonisolated static func number(_ value: Double) -> String {
        String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private nonisolated static func requireNonemptyOutput(_ url: URL) throws {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw VeloraError("The video conversion produced no playable data for this segment.")
        }
    }

    private func trimCache(protecting index: Int) {
        var total = cache.values.reduce(Int64(0)) { $0 + $1.bytes }
        for (key, entry) in cache.sorted(by: { $0.value.touched < $1.value.touched }) where key != index && jobs[key] == nil && total > cacheLimit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes; cache[key] = nil
        }
    }

    public func subtitleSegment(trackID: String, index: Int) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, (0..<timeline.count).contains(index),
              let source = subtitles.first(where: { $0.id == trackID }) else {
            throw VeloraError("Unknown subtitle segment.")
        }
        let document: SubtitleDocument
        if let cached = subtitleCache[trackID] { document = cached }
        else {
            let consumer = UUID()
            document = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    enqueueSubtitle(source, consumer: consumer, continuation: continuation)
                }
            } onCancel: {
                Task { await self.releaseSubtitleConsumer(consumer, trackID: trackID) }
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        return Data(document.segment(start: timeline.start(index), duration: timeline.length(index),
                                     timestampOffset: source.id.hasPrefix("embedded-") ? -media.videoStartOffset : 0).utf8)
    }

    private func enqueueSubtitle(_ source: SubtitleSource, consumer: UUID,
                                 continuation: CheckedContinuation<SubtitleDocument, Error>) {
        guard !stopped, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        if var existing = subtitleJobs[source.id] {
            existing.consumers[consumer] = continuation
            subtitleJobs[source.id] = existing
            return
        }
        let id = UUID(), processRunner = MediaProcessRunner()
        let tools = tools, store = subtitleStore, gate = subtitleGate
        let task = Task.detached(priority: .utility) {
            guard await gate.acquire() else {
                await self.completeSubtitleJob(source.id, jobID: id, result: .failure(CancellationError()))
                return
            }
            let result: Result<SubtitleDocument, Error>
            do {
                try Task.checkCancellation()
                result = .success(try store.load(source: source, tools: tools, runner: processRunner))
            } catch { result = .failure(error) }
            await gate.release()
            await self.completeSubtitleJob(source.id, jobID: id, result: result)
        }
        if subtitleJobs.isEmpty { onSubtitlePreparation(true) }
        subtitleJobs[source.id] = SubtitleJob(id: id, task: task, runner: processRunner,
                                              consumers: [consumer: continuation])
    }

    private func completeSubtitleJob(_ trackID: String, jobID: UUID, result: Result<SubtitleDocument, Error>) {
        guard let job = subtitleJobs[trackID], job.id == jobID else { return }
        subtitleJobs[trackID] = nil
        if subtitleJobs.isEmpty { onSubtitlePreparation(false) }
        if !stopped, case .success(let document) = result {
            // Bound memory even for files with many large language tracks.
            if subtitleCache.count >= 4, let old = subtitleCache.keys.first { subtitleCache[old] = nil }
            subtitleCache[trackID] = document
        }
        for continuation in job.consumers.values {
            if stopped { continuation.resume(throwing: CancellationError()) }
            else { continuation.resume(with: result) }
        }
    }

    private func releaseSubtitleConsumer(_ consumer: UUID, trackID: String) {
        guard var job = subtitleJobs[trackID], let continuation = job.consumers.removeValue(forKey: consumer) else { return }
        guard job.consumers.isEmpty else {
            subtitleJobs[trackID] = job
            continuation.resume(throwing: CancellationError())
            return
        }
        subtitleJobs[trackID] = nil
        if subtitleJobs.isEmpty { onSubtitlePreparation(false) }
        job.task.cancel(); job.runner.stop()
        let task = job.task, id = job.id
        // The final consumer waits for process reaping; a duplicate consumer can
        // cancel promptly while another request continues to use the extraction.
        retiredSubtitleJobs[id] = Task.detached {
            await task.value
            continuation.resume(throwing: CancellationError())
            await self.finishRetiredSubtitleJob(id)
        }
    }

    private func finishRetiredSubtitleJob(_ id: UUID) { retiredSubtitleJobs[id] = nil }

    public nonisolated func cancelProcesses() { Task { await self.stop() } }

    public func stop() async {
        stopped = true
        for job in jobs.values { job.task.cancel(); job.runner.stop() }
        let subtitleJobs = Array(subtitleJobs.values)
        for job in subtitleJobs { job.task.cancel(); job.runner.stop() }
        await gate.stop()
        await subtitleGate.stop()
        // Wait until workers exit before removing the directory they may still be writing to.
        for job in jobs.values { _ = try? await job.task.value }
        for job in retiredJobs { await job.value }
        retiredJobs.removeAll()
        await audioSegments?.stop()
        for job in subtitleJobs { await job.task.value }
        for job in retiredSubtitleJobs.values { await job.value }
        retiredSubtitleJobs.removeAll()
        jobs.removeAll(); cache.removeAll()
        subtitleCache.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}

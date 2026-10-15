import Foundation

public struct StreamTimeline: Sendable {
    public let duration: Double
    public let segmentDuration: Double
    public init(duration: Double, segmentDuration: Double = 4) {
        precondition(duration.isFinite && duration > 0 && segmentDuration > 0)
        self.duration = duration; self.segmentDuration = segmentDuration
    }
    public var count: Int { Int(ceil(duration / segmentDuration)) }
    public func start(_ index: Int) -> Double { Double(index) * segmentDuration }
    public func length(_ index: Int) -> Double { min(segmentDuration, duration - start(index)) }
    public func playlist(segmentExtension: String = "ts") -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(Int(ceil(segmentDuration)))",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for index in 0..<count {
            // Each chunk has a separate encoder, PAT/PMT and AAC priming. Signal the reset explicitly.
            if index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
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

private actor EncoderGate {
    private var active = 0
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var stopped = false
    func acquire() async -> Bool {
        if stopped { return false }
        if active < 2 { active += 1; return true }
        return await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if !waiting.isEmpty { waiting.removeFirst().resume(returning: !stopped) }
        else { active = max(0, active - 1) }
    }
    func stop() { stopped = true; waiting.forEach { $0.resume(returning: false) }; waiting.removeAll() }
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
    private let runner = MediaProcessRunner()
    private let gate = EncoderGate()
    private var jobs: [Int: Task<(URL, Double), Error>] = [:]
    private var cache: [Int: (url: URL, bytes: Int64, touched: Date)] = [:]
    private var subtitleJobs: [String: Task<SubtitleDocument, Error>] = [:]
    private var subtitleCache: [String: SubtitleDocument] = [:]
    private var stopped = false
    private let onEvent: @Sendable (SegmentEvent) -> Void
    private let cacheLimit: Int64 = 2 * 1024 * 1024 * 1024

    public init(media: MediaInfo, quality: StreamQuality, tools: MediaTools,
                audioTrackIndex: Int? = nil, externalSubtitle: URL? = nil,
                cacheRoot: URL, onEvent: @escaping @Sendable (SegmentEvent) -> Void = { _ in }) throws {
        self.media = media; self.quality = quality; self.tools = tools
        if let audioTrackIndex {
            guard let track = media.audioTracks.first(where: { $0.index == audioTrackIndex }) else {
                throw VeloraError("The selected audio track is unavailable.")
            }
            audioTrack = track
        } else { audioTrack = media.defaultAudioTrack }
        subtitles = media.subtitleTracks.filter(\.supportsTextSubtitles).map { SubtitleSource(media: media, track: $0) }
            + (externalSubtitle.map { [SubtitleSource(externalURL: $0)] } ?? [])
        self.timeline = StreamTimeline(duration: media.duration)
        self.onEvent = onEvent
        directory = cacheRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public nonisolated func masterPlaylist() -> String {
        // Resolution is omitted because portrait/rotated sources may have different output geometry.
        var lines = ["#EXTM3U", "#EXT-X-VERSION:6"]
        lines += subtitles.map(\.mediaTag)
        lines += ["#EXT-X-STREAM-INF:BANDWIDTH=\(quality.bitRate + 800_000),CODECS=\"avc1.640029\(audioTrack == nil ? "" : ",mp4a.40.2")\"\(subtitles.isEmpty ? "" : ",SUBTITLES=\"subs\"")", "video.m3u8"]
        return lines.joined(separator: "\n") + "\n"
    }

    public func segment(_ index: Int) async throws -> URL {
        guard !stopped, (0..<timeline.count).contains(index) else { throw VeloraError("Unknown video segment.") }
        if let hit = cache[index], FileManager.default.fileExists(atPath: hit.url.path) {
            cache[index]?.touched = Date(); return hit.url
        }
        if let job = jobs[index] { return try await job.value.0 }
        let media = media, quality = quality, tools = tools, directory = directory, timeline = timeline
        let runner = runner, gate = gate
        let audioTrack = audioTrack
        let job = Task.detached(priority: .userInitiated) { () throws -> (URL, Double) in
            guard await gate.acquire() else { throw CancellationError() }
            do {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent("segment-\(index).ts")
                let partial = directory.appendingPathComponent("segment-\(index).partial")
                defer { try? FileManager.default.removeItem(at: partial) }
                let start = timeline.start(index), length = timeline.length(index)
                let begin = Date()
                var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                            "-ss", String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), start),
                            "-i", media.source.path, "-t", String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), length),
                            "-map", "0:V:0"]
                if let audioTrack { args += ["-map", "0:\(audioTrack.index)"] }
                args += ["-sn", "-dn",
                            "-vf", VideoFilter.make(media: media, quality: quality),
                            "-r", "30", "-fps_mode", "cfr", "-c:v", "h264_videotoolbox", "-allow_sw", "0",
                            "-profile:v", "high", "-level:v", "4.1", "-pix_fmt", "yuv420p",
                            "-b:v", "\(quality.bitRate)", "-maxrate", "\(quality.bitRate + 500_000)",
                            "-bufsize", "\(quality.bitRate * 2)", "-g", "120", "-bf", "0",
                            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
                if audioTrack != nil {
                    args += ["-af", "aresample=async=1:first_pts=0,apad", "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000"]
                }
                args += ["-output_ts_offset", String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), start),
                         "-mpegts_copyts", "1", "-mpegts_flags", "+resend_headers+initial_discontinuity",
                         "-muxdelay", "0", "-muxpreload", "0", "-f", "mpegts", partial.path]
                _ = try runner.run(tools.executable("ffmpeg"), arguments: args)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: partial, to: destination)
                await gate.release()
                return (destination, length / max(0.001, Date().timeIntervalSince(begin)))
            } catch { await gate.release(); throw error }
        }
        jobs[index] = job
        do {
            let (url, speed) = try await job.value
            jobs[index] = nil
            guard !stopped else { try? FileManager.default.removeItem(at: url); throw CancellationError() }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            cache[index] = (url, bytes, Date())
            trimCache(protecting: index)
            onEvent(SegmentEvent(index: index, count: timeline.count, speed: speed,
                                 cachedBytes: cache.values.reduce(0) { $0 + $1.bytes }, cachedIndices: cache.keys.sorted()))
            return url
        } catch { jobs[index] = nil; throw error }
    }

    private func trimCache(protecting index: Int) {
        var total = cache.values.reduce(Int64(0)) { $0 + $1.bytes }
        for (key, entry) in cache.sorted(by: { $0.value.touched < $1.value.touched }) where key != index && total > cacheLimit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes; cache[key] = nil
        }
    }

    public func subtitleSegment(trackID: String, index: Int) async throws -> Data {
        guard !stopped, (0..<timeline.count).contains(index),
              let source = subtitles.first(where: { $0.id == trackID }) else {
            throw VeloraError("Unknown subtitle segment.")
        }
        let document: SubtitleDocument
        if let cached = subtitleCache[trackID] { document = cached }
        else {
            let job: Task<SubtitleDocument, Error>
            if let existing = subtitleJobs[trackID] { job = existing }
            else {
                let tools = tools, runner = runner
                let output = directory.appendingPathComponent("\(trackID).vtt")
                job = Task.detached(priority: .utility) {
                    defer { try? FileManager.default.removeItem(at: output) }
                    _ = try runner.run(tools.executable("ffmpeg"), arguments: [
                        "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-copyts", "-start_at_zero",
                        "-i", source.url.path, "-map", "0:\(source.streamIndex)", "-vn", "-an", "-dn",
                        "-c:s", "webvtt", "-fs", "16777216", "-f", "webvtt", output.path
                    ])
                    let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size < 16 * 1024 * 1024 else { throw VeloraError("This subtitle track exceeds 16 MB.") }
                    return try SubtitleDocument(webVTT: String(contentsOf: output, encoding: .utf8))
                }
                subtitleJobs[trackID] = job
            }
            do { document = try await job.value }
            catch { subtitleJobs[trackID] = nil; throw error }
            subtitleJobs[trackID] = nil
            guard !stopped else { throw CancellationError() }
            // Bound memory even for files with many large language tracks.
            if subtitleCache.count >= 4, let old = subtitleCache.keys.first { subtitleCache[old] = nil }
            subtitleCache[trackID] = document
        }
        return Data(document.segment(start: timeline.start(index), duration: timeline.length(index)).utf8)
    }

    public nonisolated func cancelProcesses() { runner.stop() }

    public func stop() async {
        stopped = true
        for job in jobs.values { job.cancel() }
        for job in subtitleJobs.values { job.cancel() }
        runner.stop()
        await gate.stop()
        // Wait until workers exit before removing the directory they may still be writing to.
        for job in jobs.values { _ = try? await job.value }
        for job in subtitleJobs.values { _ = try? await job.value }
        jobs.removeAll(); cache.removeAll()
        subtitleJobs.removeAll(); subtitleCache.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}

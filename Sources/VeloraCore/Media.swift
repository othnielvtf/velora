import Foundation
import Darwin

public struct VeloraError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MediaTools: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func executable(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VeloraError("The bundled \(name) tool is missing. Rebuild Velora with scripts/build.sh.")
        }
        return url
    }
}

/// Processes write to files instead of pipes, avoiding deadlock on verbose or malformed inputs.
public final class MediaProcessRunner: @unchecked Sendable {
    private enum Interruption { case timeout, cancellation }
    private struct Child {
        let pid: pid_t
        var deadline: DispatchTime
        var interruption: Interruption?
        var killDeadline: DispatchTime?
        var killed = false
        var suspended = false
        var suspendedAt: DispatchTime?
    }

    private let lock = NSLock()
    private var processes: [UUID: Child] = [:]
    private var stopped = false
    private var suspended = false
    private let terminationGrace: TimeInterval = 0.5
    public init() {}

    public func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 90) throws -> Data {
        guard timeout.isFinite, timeout >= 0 else { throw VeloraError("Invalid media conversion timeout.") }
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-process-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("stdout")
        let err = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out)
        let error = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? error.close() }
        lock.lock()
        guard !stopped else { lock.unlock(); throw CancellationError() }
        do {
            let pid = try Self.spawn(executable, arguments: arguments, output: output, error: error)
            var child = Child(pid: pid, deadline: .now() + timeout)
            if suspended {
                kill(pid, SIGSTOP); child.suspended = true; child.suspendedAt = .now()
            }
            processes[id] = child
            lock.unlock()
        }
        catch { lock.unlock(); throw error }

        let (status, interruption) = try wait(for: id)
        if interruption == .cancellation { throw CancellationError() }
        if interruption == .timeout { throw VeloraError("Media conversion timed out after \(timeout) seconds.") }
        // waitpid's status contains either the exit code or the terminating signal.
        guard (status & 0x7f) == 0, ((status >> 8) & 0xff) == 0 else {
            let log = (try? String(contentsOf: err, encoding: .utf8)) ?? "No diagnostic output."
            throw VeloraError("Media conversion failed. \(String(log.suffix(2200)))")
        }
        return (try? Data(contentsOf: out)) ?? Data()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        for id in Array(processes.keys) {
            guard var child = processes[id] else { continue }
            interrupt(&child, reason: .cancellation, now: .now())
            processes[id] = child
        }
    }

    /// Application termination must wait for escalation and waitpid, including
    /// children paused by the audio lookahead limiter.
    public func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                while true {
                    lock.lock()
                    let finished = processes.isEmpty
                    lock.unlock()
                    if finished { continuation.resume(); return }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
    }

    public func setSuspended(_ suspended: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.suspended = suspended
        for id in Array(processes.keys) {
            guard var child = processes[id], child.interruption == nil, child.suspended != suspended else { continue }
            let now = DispatchTime.now()
            if suspended { child.suspendedAt = now }
            else if let since = child.suspendedAt {
                child.deadline = child.deadline + Double(now.uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000_000
                child.suspendedAt = nil
            }
            kill(child.pid, suspended ? SIGSTOP : SIGCONT)
            child.suspended = suspended
            processes[id] = child
        }
    }

    private func interrupt(_ child: inout Child, reason: Interruption, now: DispatchTime) {
        child.interruption = reason
        if child.killDeadline == nil {
            // A suspended child must be running to handle TERM during its grace period.
            kill(child.pid, SIGCONT)
            child.suspended = false
            child.suspendedAt = nil
            kill(child.pid, SIGTERM)
            child.killDeadline = now + terminationGrace
        }
    }

    private func wait(for id: UUID) throws -> (Int32, Interruption?) {
        while true {
            // Signals and reaping share this lock. Until waitpid reaps the child, its PID
            // cannot be reused; no deferred callback can signal an already-reaped PID.
            lock.lock()
            var child = processes[id]!
            let now = DispatchTime.now()
            if child.interruption == nil, !child.suspended, now >= child.deadline {
                interrupt(&child, reason: .timeout, now: now)
            }
            if let deadline = child.killDeadline, now >= deadline, !child.killed {
                kill(child.pid, SIGKILL)
                child.killed = true
            }
            var status: Int32 = 0
            let result = waitpid(child.pid, &status, WNOHANG)
            let waitError = errno
            if result == child.pid {
                processes[id] = nil
                lock.unlock()
                return (status, child.interruption)
            }
            if result == -1, waitError != EINTR {
                processes[id] = nil
                lock.unlock()
                throw POSIXError(POSIXErrorCode(rawValue: waitError) ?? .EIO)
            }
            processes[id] = child
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func spawn(_ executable: URL, arguments: [String], output: FileHandle, error: FileHandle) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ result: Int32) throws {
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, error.fileDescriptor, STDERR_FILENO))
        // Close unrelated descriptors and let TERM/KILL work even if the caller's thread masks signals.
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try check(posix_spawnattr_setsigmask(&attributes, &signalMask))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw POSIXError(.ENOMEM)
        }
        var pid: pid_t = 0
        try argv.withUnsafeBufferPointer { args in
            try environment.withUnsafeBufferPointer { env in
                try check(posix_spawn(&pid, executable.path, &actions, &attributes,
                                      UnsafeMutablePointer(mutating: args.baseAddress!),
                                      UnsafeMutablePointer(mutating: env.baseAddress!)))
            }
        }
        return pid
    }
}

public struct MediaInfo: Sendable {
    public let source: URL
    /// The duration and playback clock describe video frames, excluding audio padding.
    public let duration: Double
    /// FFmpeg input seeks are relative to the container's start, which can precede video.
    public let videoStartOffset: Double
    public let width: Int
    public let height: Int
    public let videoCodec: String
    public let audioTracks: [MediaTrack]
    public let subtitleTracks: [MediaTrack]
    public var defaultAudioTrack: MediaTrack? { audioTracks.first(where: \.isDefault) ?? audioTracks.first }
    public var audioCodec: String? { defaultAudioTrack?.codec }
    public let frameRate: Double
    public let colorTransfer: String?
    public var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" }
    public var codecLabel: String {
        ["hevc": "HEVC", "h264": "H.264", "av1": "AV1"][videoCodec] ?? videoCodec.uppercased()
    }

    public static func inspect(_ source: URL, tools: MediaTools, runner: MediaProcessRunner) throws -> MediaInfo {
        let data = try runner.run(tools.executable("ffprobe"), arguments: [
            "-v", "error", "-show_format", "-show_streams", "-of", "json", source.path
        ], timeout: 30)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var streams = json["streams"] as? [[String: Any]],
              let index = videoIndex(streams) else {
            throw VeloraError("This file does not contain a playable video track.")
        }
        // Some containers expose only their longest track's duration. In that
        // case inspect video packets near EOF rather than advertising an audio-only tail.
        if videoDuration(streams[index]) == nil {
            streams[index]["duration"] = String(try probeVideoDuration(source, video: streams[index],
                format: json["format"] as? [String: Any] ?? [:], tools: tools, runner: runner))
            json["streams"] = streams
        }
        return try decodeProbe(JSONSerialization.data(withJSONObject: json), source: source)
    }

    public static func decodeProbe(_ data: Data, source: URL) throws -> MediaInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let index = videoIndex(streams) else { throw VeloraError("This file does not contain a playable video track.") }
        let video = streams[index]
        let format = json["format"] as? [String: Any] ?? [:]
        let duration = videoDuration(video) ?? containerDuration(format) ?? 0
        guard duration.isFinite, duration > 0, duration < 7 * 24 * 3600 else {
            throw VeloraError("Velora needs a local video with a known duration of less than seven days.")
        }
        let videoStart = finiteNumber(video["start_time"]) ?? 0
        let containerStart = finiteNumber(format["start_time"]) ?? streams.compactMap { finiteNumber($0["start_time"]) }.min() ?? videoStart
        let videoStartOffset = max(0, videoStart - containerStart)
        let rate = (video["avg_frame_rate"] as? String ?? "30/1").split(separator: "/").compactMap { Double($0) }
        let fps = rate.count == 2 && rate[1] > 0 ? rate[0] / rate[1] : 30
        return MediaInfo(source: source, duration: duration, videoStartOffset: videoStartOffset,
                         width: video["width"] as? Int ?? 1920, height: video["height"] as? Int ?? 1080,
                         videoCodec: video["codec_name"] as? String ?? "unknown",
                         audioTracks: MediaTrack.parse(streams, kind: "audio"),
                         subtitleTracks: MediaTrack.parse(streams, kind: "subtitle"),
                         frameRate: fps.isFinite && fps > 0 ? fps : 30,
                         colorTransfer: video["color_transfer"] as? String)
    }

    private static func videoIndex(_ streams: [[String: Any]]) -> Int? {
        streams.firstIndex {
            $0["codec_type"] as? String == "video" &&
            (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        let number = (value as? String).flatMap(Double.init) ?? (value as? NSNumber)?.doubleValue
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func videoDuration(_ video: [String: Any]) -> Double? {
        if let duration = finiteNumber(video["duration"]), duration > 0 { return duration }
        // Matroska DURATION tags contain the ending timestamp, including any
        // nonzero start. They are not the stream's elapsed playback duration.
        let tags = video["tags"] as? [String: Any] ?? [:]
        if let text = tags.first(where: { $0.key.caseInsensitiveCompare("DURATION") == .orderedSame })?.value as? String,
           let end = SubtitleDocument.seconds(text), end > (finiteNumber(video["start_time"]) ?? 0) {
            return end - (finiteNumber(video["start_time"]) ?? 0)
        }
        return nil
    }

    private static func containerDuration(_ format: [String: Any]) -> Double? {
        guard let duration = finiteNumber(format["duration"]) else { return nil }
        if (format["format_name"] as? String ?? "").split(separator: ",").contains("matroska") {
            return duration - (finiteNumber(format["start_time"]) ?? 0)
        }
        return duration
    }

    private static func probeVideoDuration(_ source: URL, video: [String: Any], format: [String: Any],
                                           tools: MediaTools, runner: MediaProcessRunner) throws -> Double {
        let start = finiteNumber(video["start_time"]) ?? finiteNumber(format["start_time"]) ?? 0
        guard let estimate = containerDuration(format), estimate > 0, estimate < 7 * 24 * 3600 else {
            throw VeloraError("Velora needs a local video with a known duration of less than seven days.")
        }
        let rate = (video["avg_frame_rate"] as? String ?? "30/1").split(separator: "/").compactMap { Double($0) }
        let frameDuration = rate.count == 2 && rate[0] > 0 && rate[1] > 0 ? rate[1] / rate[0] : 1 / 30.0
        var lookback = 30.0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let seek = start + max(0, estimate - lookback)
            let data = try runner.run(tools.executable("ffprobe"), arguments: [
                "-v", "error", "-select_streams", "V:0", "-read_intervals", String(format: "%.9f%%", locale: Locale(identifier: "en_US_POSIX"), seek),
                "-show_entries", "packet=pts_time,duration_time", "-of", "json", source.path
            ], timeout: max(0.1, deadline.timeIntervalSinceNow))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let packets = json?["packets"] as? [[String: Any]] ?? []
            if let end = packets.compactMap({ packet -> Double? in
                guard let pts = finiteNumber(packet["pts_time"]) else { return nil }
                let duration = finiteNumber(packet["duration_time"]).flatMap { $0 > 0 ? $0 : nil } ?? frameDuration
                return pts + duration
            }).max(), end > start { return end - start }
            if lookback >= estimate { break }
            lookback = min(estimate, lookback * 4)
        }
        throw VeloraError("The video track's playable duration could not be determined.")
    }
}

public enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case fullHD = "1080p", hd = "720p"
    public var id: String { rawValue }
    public var maxWidth: Int { self == .fullHD ? 1920 : 1280 }
    public var maxHeight: Int { self == .fullHD ? 1080 : 720 }
    public var bitRate: Int { self == .fullHD ? 6_000_000 : 3_000_000 }
    public var description: String { self == .fullHD ? "1080p · 6 Mbps" : "720p · 3 Mbps" }
}

public enum VideoFilter {
    public static func make(media: MediaInfo, quality: StreamQuality) -> String {
        let scale = "scale=w='min(\(quality.maxWidth),iw)':h='min(\(quality.maxHeight),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1"
        if media.isHDR {
            return "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,\(scale),format=yuv420p"
        }
        return "\(scale),format=yuv420p"
    }
}

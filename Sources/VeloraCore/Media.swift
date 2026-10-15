import Foundation

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
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var stopped = false
    public init() {}

    public func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 90) throws -> Data {
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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        lock.lock()
        guard !stopped else { lock.unlock(); throw CancellationError() }
        do { try process.run(); processes[id] = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        let watchdog = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        lock.lock(); processes[id] = nil; let cancelled = stopped; lock.unlock()
        if cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let log = (try? String(contentsOf: err, encoding: .utf8)) ?? "No diagnostic output."
            throw VeloraError("Media conversion failed. \(String(log.suffix(2200)))")
        }
        return (try? Data(contentsOf: out)) ?? Data()
    }

    public func stop() {
        lock.lock(); stopped = true; let running = Array(processes.values); lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }
}

public struct MediaInfo: Sendable {
    public let source: URL
    public let duration: Double
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
        return try decodeProbe(data, source: source)
    }

    public static func decodeProbe(_ data: Data, source: URL) throws -> MediaInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let video = streams.first(where: {
                  $0["codec_type"] as? String == "video" &&
                  (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
              }) else { throw VeloraError("This file does not contain a playable video track.") }
        let format = json["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? video["duration"] as? String ?? "0") ?? 0
        guard duration.isFinite, duration > 0, duration < 7 * 24 * 3600 else {
            throw VeloraError("Velora needs a local video with a known duration of less than seven days.")
        }
        let rate = (video["avg_frame_rate"] as? String ?? "30/1").split(separator: "/").compactMap { Double($0) }
        let fps = rate.count == 2 && rate[1] > 0 ? rate[0] / rate[1] : 30
        return MediaInfo(source: source, duration: duration,
                         width: video["width"] as? Int ?? 1920, height: video["height"] as? Int ?? 1080,
                         videoCodec: video["codec_name"] as? String ?? "unknown",
                         audioTracks: MediaTrack.parse(streams, kind: "audio"),
                         subtitleTracks: MediaTrack.parse(streams, kind: "subtitle"),
                         frameRate: fps.isFinite && fps > 0 ? fps : 30,
                         colorTransfer: video["color_transfer"] as? String)
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
        let scale = "scale=w='min(\(quality.maxWidth),iw)':h='min(\(quality.maxHeight),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1"
        if media.isHDR {
            return "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,\(scale),format=yuv420p"
        }
        return "\(scale),format=yuv420p"
    }
}

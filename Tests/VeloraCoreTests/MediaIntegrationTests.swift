import XCTest
@testable import VeloraCore

final class MediaIntegrationTests: XCTestCase {
    func testAnamorphicVideoKeepsItsDisplayAspect() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = MediaTools(directory: repo.appendingPathComponent("Resources/Tools"))
        guard let ffmpeg = try? tools.executable("ffmpeg") else { throw XCTSkip("Build bundled media tools to run codec regression checks") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-aspect-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = MediaProcessRunner(), input = root.appendingPathComponent("anamorphic.mkv")
        _ = try runner.run(ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=30",
                                               "-t", "1", "-vf", "setsar=16/15", "-c:v", "h264_videotoolbox", input.path])
        let info = try MediaInfo.inspect(input, tools: tools, runner: runner)
        let session = try TranscodeSession(media: info, quality: .hd, tools: tools, cacheRoot: root)
        do {
            let segment = try await session.segment(0)
            let probe = try runner.run(tools.executable("ffprobe"), arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                                              "stream=width,height,sample_aspect_ratio,display_aspect_ratio", "-of", "json", segment.path])
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: probe) as? [String: Any])
            let stream = try XCTUnwrap((json["streams"] as? [[String: Any]])?.first)
            XCTAssertEqual(stream["width"] as? Int, 720)
            XCTAssertEqual(stream["height"] as? Int, 540)
            // H.264 may omit the VUI aspect field for square pixels.
            let sar = (stream["sample_aspect_ratio"] as? String ?? "1:1").split(separator: ":").compactMap { Double($0) }
            XCTAssertEqual(sar, [1, 1])
            let width = try XCTUnwrap(stream["width"] as? Int)
            let height = try XCTUnwrap(stream["height"] as? Int)
            XCTAssertEqual(Double(width) / Double(height), 4.0 / 3.0, accuracy: 0.001)
            await session.stop()
        } catch { await session.stop(); throw error }
    }

    func testAACRemainsContinuousAcrossVideoChunks() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = MediaTools(directory: repo.appendingPathComponent("Resources/Tools"))
        guard let ffmpeg = try? tools.executable("ffmpeg") else { throw XCTSkip("Build bundled media tools to run codec regression checks") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-audio-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = MediaProcessRunner(), input = root.appendingPathComponent("source.mkv")
        _ = try runner.run(ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30",
                                               "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "12",
                                               "-c:v", "h264_videotoolbox", "-b:v", "500k", "-c:a", "pcm_s16le", input.path])
        let info = try MediaInfo.inspect(input, tools: tools, runner: runner)
        let session = try TranscodeSession(media: info, quality: .hd, tools: tools, cacheRoot: root)
        do {
            var previousEnd: Double?
            for index in 0..<3 {
                let segment = try await session.segment(index)
                try FileManager.default.copyItem(at: segment, to: root.appendingPathComponent("segment-\(index).ts"))
                let probe = try runner.run(tools.executable("ffprobe"), arguments: ["-v", "error", "-select_streams", "a:0", "-show_packets",
                                                                                  "-show_entries", "packet=pts_time,duration_time", "-of", "json", segment.path])
                let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: probe) as? [String: Any])
                let packets = try XCTUnwrap(json["packets"] as? [[String: Any]])
                let first = try XCTUnwrap(packets.first?["pts_time"] as? String).doubleValue
                let last = try XCTUnwrap(packets.last?["pts_time"] as? String).doubleValue
                let packetDuration = try XCTUnwrap(packets.last?["duration_time"] as? String).doubleValue
                if let previousEnd { XCTAssertEqual(first, previousEnd, accuracy: 0.00003, "AAC packets must neither overlap nor leave a gap") }
                previousEnd = last + packetDuration
            }
            let playlist = root.appendingPathComponent("video.m3u8")
            try session.timeline.playlist().write(to: playlist, atomically: true, encoding: .utf8)
            let pcm = try runner.run(ffmpeg, arguments: ["-v", "error", "-i", playlist.path, "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"])
            let samples = stride(from: 0, to: pcm.count - 1, by: 2).map { Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8) }
            XCTAssertEqual(Double(samples.count) / 48_000, 12, accuracy: 0.04)
            // A steady tone must stay audible through both joins, including AAC encoder priming.
            // The original frequency-only check skipped the first/last 100 ms and missed 35 ms silence.
            let reference = samples[48_000..<52_800]
            let referenceRMS = sqrt(reference.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(reference.count))
            for boundary in [4.0, 8.0] {
                for step in -15...15 {
                    let start = Int((boundary + Double(step) * 0.005) * 48_000)
                    let window = samples[start..<(start + 240)]
                    let rms = sqrt(window.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.count))
                    XCTAssertGreaterThan(rms, referenceRMS * 0.75, "Unexpected audio dip near \(boundary)s at step \(step)")
                }
            }
            await session.stop()
        } catch { await session.stop(); throw error }
    }
}

private extension String {
    var doubleValue: Double { Double(self) ?? .nan }
}

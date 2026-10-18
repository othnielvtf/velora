import XCTest
@testable import VeloraCore

final class VideoTimelineTests: XCTestCase {
    func testStreamDurationWinsOverLongerAudioAndKeepsVideoSeekOffset() throws {
        let media = try decode(video: ["start_time": "5.023", "duration": "20.0"],
                               format: ["start_time": "5.0", "duration": "25.1"])
        XCTAssertEqual(media.duration, 20)
        XCTAssertEqual(media.videoStartOffset, 0.023, accuracy: 0.000001)
        XCTAssertEqual(StreamTimeline(duration: media.duration).count, 5)
    }

    func testMatroskaEndingTagIsNormalizedByVideoStart() throws {
        let media = try decode(video: ["start_time": "5.023", "tags": ["DURATION": "00:00:25.023000000"]],
                               format: ["format_name": "matroska,webm", "start_time": "5.0", "duration": "25.1"])
        XCTAssertEqual(media.duration, 20, accuracy: 0.000001)
        XCTAssertEqual(media.videoStartOffset, 0.023, accuracy: 0.000001)
    }

    func testAACPaddingDoesNotAdvertiseAnEmptyFinalVideoSegment() async throws {
        let fixture = try makeFixture(duration: 20, audioCodec: "aac", sampleRate: 44100)
        let media = try MediaInfo.inspect(fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(media.duration, 20, accuracy: 0.001)
        XCTAssertEqual(StreamTimeline(duration: media.duration).count, 5)
        try await assertEverySegmentHasVideo(media, fixture: fixture)
    }

    func testNonzeroContainerStartDoesNotAddAnUnavailableTail() async throws {
        let fixture = try makeFixture(duration: 12, audioCodec: "pcm_s16le", sampleRate: 48000, timestampOffset: 5)
        let media = try MediaInfo.inspect(fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(media.duration, 12, accuracy: 0.001)
        XCTAssertEqual(media.videoStartOffset, 0, accuracy: 0.001)
        XCTAssertEqual(StreamTimeline(duration: media.duration).count, 3)
        try await assertEverySegmentHasVideo(media, fixture: fixture)
    }

    func testFractionalRateFinalFrameDoesNotCreateAnEmptySliverSegment() async throws {
        // Six hundred NTSC frames end at 20.020s, but the last frame starts at
        // 19.987s. A new seek to 20s therefore has no frame to encode.
        let fixture = try makeFixture(duration: 20, audioCodec: "pcm_s16le", sampleRate: 48000,
                                      frameRate: "30000/1001", frameCount: 600, audioDuration: 20.02)
        let media = try MediaInfo.inspect(fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(media.duration, 20.02, accuracy: 0.001)
        let session = try TranscodeSession(media: media, quality: .hd, tools: fixture.tools,
                                          cacheRoot: fixture.root.appendingPathComponent("timeline-check"))
        XCTAssertEqual(session.timeline.count, 5)
        XCTAssertEqual(session.timeline.length(4), 4.02, accuracy: 0.001)
        XCTAssertTrue(session.timeline.playlist().contains("#EXT-X-TARGETDURATION:5"))
        await session.stop()
        try await assertEverySegmentHasVideo(media, fixture: fixture, finalAudioEnd: 20.02)
    }

    func testVariableRateHeldFinalFrameFillsEveryAdvertisedSegment() async throws {
        let fixture = try makeFixture(duration: 12, audioCodec: nil, sampleRate: 48000)
        let hold = fixture.root.appendingPathComponent("hold.mkv")
        let source = fixture.root.appendingPathComponent("variable.mp4")
        let concat = fixture.root.appendingPathComponent("concat.txt")
        let runner = MediaProcessRunner(), ffmpeg = try fixture.tools.executable("ffmpeg")
        _ = try runner.run(ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=1/8",
            "-frames:v", "1", "-c:v", "h264_videotoolbox", "-b:v", "100k", hold.path
        ])
        try "file '\(fixture.source.path)'\nfile '\(hold.path)'\n".write(to: concat, atomically: true, encoding: .utf8)
        _ = try runner.run(ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", concat.path,
            "-c", "copy", source.path
        ])
        let media = try MediaInfo.inspect(source, tools: fixture.tools, runner: runner)
        XCTAssertEqual(media.duration, 20, accuracy: 0.001)
        try await assertEverySegmentHasVideo(media, fixture: Fixture(source: source, root: fixture.root, tools: fixture.tools))
    }

    func testEightSecondSourceFramesFillChunksBetweenFrameTimestamps() async throws {
        let fixture = try makeFixture(duration: 24, audioCodec: nil, sampleRate: 48000,
                                      frameRate: "1/8", frameCount: 3)
        let media = try MediaInfo.inspect(fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(media.duration, 24, accuracy: 0.001)
        try await assertEverySegmentHasVideo(media, fixture: fixture)
    }

    func testMissingVideoDurationUsesActualPacketsInsteadOfLongerAudio() throws {
        let fixture = try makeFixture(duration: 12, audioCodec: "aac", sampleRate: 44100)
        let runner = MediaProcessRunner()
        let data = try runner.run(fixture.tools.executable("ffprobe"), arguments: [
            "-v", "error", "-show_format", "-show_streams", "-of", "json", fixture.source.path
        ])
        var probe = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var streams = try XCTUnwrap(probe["streams"] as? [[String: Any]])
        let index = try XCTUnwrap(streams.firstIndex { $0["codec_type"] as? String == "video" })
        streams[index].removeValue(forKey: "duration")
        streams[index].removeValue(forKey: "tags")
        probe["streams"] = streams
        var format = try XCTUnwrap(probe["format"] as? [String: Any])
        format["duration"] = "40.0" // Simulate an audio track that outlasts video.
        probe["format"] = format
        let initialProbe = fixture.root.appendingPathComponent("initial-probe.json")
        try JSONSerialization.data(withJSONObject: probe).write(to: initialProbe)
        let wrappedTools = fixture.root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: wrappedTools, withIntermediateDirectories: true)
        let wrapper = wrappedTools.appendingPathComponent("ffprobe")
        let original = try fixture.tools.executable("ffprobe")
        // Only metadata is masked. Packet timestamps come from the real bundled probe.
        try """
        #!/bin/sh
        case " $* " in
          *" -show_streams "*) exec /bin/cat \(shellQuote(initialProbe.path)) ;;
          *) exec \(shellQuote(original.path)) "$@" ;;
        esac
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let media = try MediaInfo.inspect(fixture.source, tools: MediaTools(directory: wrappedTools), runner: runner)
        XCTAssertEqual(media.duration, 12, accuracy: 0.002)
        XCTAssertEqual(StreamTimeline(duration: media.duration).count, 3)
    }

    private func assertEverySegmentHasVideo(_ media: MediaInfo, fixture: Fixture, finalAudioEnd: Double? = nil) async throws {
        let session = try TranscodeSession(media: media, quality: .hd, tools: fixture.tools,
                                          cacheRoot: fixture.root.appendingPathComponent("cache"))
        do {
            for index in 0..<session.timeline.count {
                let segment = try await session.segment(index)
                let data = try MediaProcessRunner().run(fixture.tools.executable("ffprobe"), arguments: [
                    "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                    "stream=nb_read_packets:packet=pts_time,duration_time", "-of", "json", segment.path
                ])
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
                let count = streams.first?["nb_read_packets"] as? String ?? "0"
                XCTAssertGreaterThan(Int(count) ?? 0, 0, "Advertised segment \(index) must contain video")
                let videoPackets = try XCTUnwrap(json["packets"] as? [[String: Any]])
                let starts = videoPackets.compactMap { Double($0["pts_time"] as? String ?? "") }
                let ends = videoPackets.compactMap { packet -> Double? in
                    guard let pts = Double(packet["pts_time"] as? String ?? ""),
                          let duration = Double(packet["duration_time"] as? String ?? "") else { return nil }
                    return pts + duration
                }
                XCTAssertEqual(try XCTUnwrap(starts.min()), session.timeline.start(index), accuracy: 1 / 30.0,
                               "Video PTS must stay on the movie clock")
                XCTAssertEqual(try XCTUnwrap(ends.max()), session.timeline.start(index) + session.timeline.length(index),
                               accuracy: 2 / 30.0, "A held source frame must fill its advertised display interval")
                if index == session.timeline.count - 1, let finalAudioEnd {
                    let audioData = try MediaProcessRunner().run(fixture.tools.executable("ffprobe"), arguments: [
                        "-v", "error", "-select_streams", "a:0", "-show_entries", "packet=pts_time,duration_time",
                        "-of", "json", segment.path
                    ])
                    let audio = try XCTUnwrap(JSONSerialization.jsonObject(with: audioData) as? [String: Any])
                    let packets = try XCTUnwrap(audio["packets"] as? [[String: Any]])
                    let ending = try XCTUnwrap(packets.compactMap { packet -> Double? in
                        guard let pts = Double(packet["pts_time"] as? String ?? ""),
                              let duration = Double(packet["duration_time"] as? String ?? "") else { return nil }
                        return pts + duration
                    }.max())
                    XCTAssertGreaterThanOrEqual(ending, finalAudioEnd,
                                                "Merged final video must retain audio after the four-second AAC boundary")
                    // AAC's flush packet plus sample-grid rounding can add up
                    // to two padded frames; the requested source tail must survive.
                    XCTAssertLessThanOrEqual(ending, finalAudioEnd + 2 * 1024 / 48000.0 + 0.002)
                }
            }
            await session.stop()
        } catch { await session.stop(); throw error }
    }

    private struct Fixture { let source: URL; let root: URL; let tools: MediaTools }

    private func makeFixture(duration: Int, audioCodec: String?, sampleRate: Int,
                             timestampOffset: Int = 0, frameRate: String = "30", frameCount: Int? = nil,
                             audioDuration: Double? = nil) throws -> Fixture {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = MediaTools(directory: repo.appendingPathComponent("Resources/Tools"))
        guard let ffmpeg = try? tools.executable("ffmpeg"), (try? tools.executable("ffprobe")) != nil else {
            throw XCTSkip("Build bundled media tools to run video timeline regression checks")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-video-timeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mkv")
        var arguments = ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=\(frameRate)"]
        if audioCodec != nil {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=\(sampleRate)" +
                          (audioDuration.map { ":duration=\($0)" } ?? "")]
        }
        arguments += frameCount.map { ["-frames:v", "\($0)"] } ?? ["-t", "\(duration)"]
        arguments += ["-c:v", "h264_videotoolbox", "-b:v", "100k"]
        if let audioCodec { arguments += ["-c:a", audioCodec] }
        arguments += ["-output_ts_offset", "\(timestampOffset)", source.path]
        _ = try MediaProcessRunner().run(ffmpeg, arguments: arguments)
        return Fixture(source: source, root: root, tools: tools)
    }

    private func decode(video fields: [String: Any], format: [String: Any]) throws -> MediaInfo {
        var video = fields
        video["codec_type"] = "video"; video["codec_name"] = "h264"
        return try MediaInfo.decodeProbe(JSONSerialization.data(withJSONObject: ["streams": [video], "format": format]),
                                         source: URL(fileURLWithPath: "/tmp/movie.mkv"))
    }

    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

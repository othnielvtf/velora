import XCTest
@testable import VeloraCore

final class AudioSeekContinuityTests: XCTestCase {
    func testBufferedChunksFromDifferentSeekRunsSharePacketGridAndWaveform() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = MediaTools(directory: repo.appendingPathComponent("Resources/Tools"))
        guard let ffmpeg = try? tools.executable("ffmpeg") else { throw XCTSkip("Build bundled media tools for AAC seek regression checks") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-seek-audio-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = MediaProcessRunner(), input = root.appendingPathComponent("source.mkv")
        _ = try runner.run(ffmpeg, arguments: ["-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=1",
                                               "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "40",
                                               "-c:v", "h264_videotoolbox", "-b:v", "100k", "-c:a", "pcm_s16le", input.path])
        let media = try MediaInfo.inspect(input, tools: tools, runner: runner)
        let track = try XCTUnwrap(media.defaultAudioTrack)
        let timeline = StreamTimeline(duration: media.duration)
        func store(_ name: String) -> AudioSegments {
            AudioSegments(media: media, track: track, tools: tools, timeline: timeline, directory: root.appendingPathComponent(name))
        }
        let original = store("original"), oddSeek = store("odd-seek"), evenSeek = store("even-seek")
        do {
            var old: [Int: PreparedAudio] = [:]
            // Populate a continuous original run before simulating a receiver
            // keeping these bytes through forward and backward seeks.
            for index in 0...7 { old[index] = try await original.segment(index) }
            let odd5 = try await oddSeek.segment(5)
            let odd6 = try await oddSeek.segment(6)
            let even6 = try await evenSeek.segment(6)
            let even7 = try await evenSeek.segment(7)
            XCTAssertNotEqual(odd5.runID, old[5]?.runID)
            XCTAssertNotEqual(even6.runID, old[6]?.runID)
            XCTAssertEqual(odd5.runID, odd6.runID)
            XCTAssertEqual(even6.runID, even7.runID)
            let combinations = [
                [try XCTUnwrap(old[4]), odd5, try XCTUnwrap(old[6])],
                [odd5, try XCTUnwrap(old[6]), even7],
                [try XCTUnwrap(old[5]), even6, try XCTUnwrap(old[7])],
                [even6, try XCTUnwrap(old[7])]
            ]
            for (number, chunks) in combinations.enumerated() {
                let folder = root.appendingPathComponent("mixed-\(number)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var previousEnd: Double?, frameCounts: [Int] = []
                for (index, chunk) in chunks.enumerated() {
                    let file = folder.appendingPathComponent("segment-\(index).ts")
                    try chunk.data.write(to: file)
                    let probe = try runner.run(tools.executable("ffprobe"), arguments: ["-v", "error", "-select_streams", "a:0", "-show_packets",
                                                                                      "-show_entries", "packet=pts_time,duration_time", "-of", "json", file.path])
                    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: probe) as? [String: Any])
                    let packets = try XCTUnwrap(json["packets"] as? [[String: Any]])
                    let first = try XCTUnwrap(Double(try XCTUnwrap(packets.first?["pts_time"] as? String)))
                    let last = try XCTUnwrap(Double(try XCTUnwrap(packets.last?["pts_time"] as? String)))
                    let duration = try XCTUnwrap(Double(try XCTUnwrap(packets.last?["duration_time"] as? String)))
                    if let previousEnd { XCTAssertEqual(first, previousEnd, accuracy: 0.00003, "Mixed seek runs must have no overlap or gap") }
                    previousEnd = last + duration
                    frameCounts.append(packets.count * 1024)
                }
                var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
                for index in chunks.indices { playlist += "#EXTINF:4.000000,\nsegment-\(index).ts\n" }
                playlist += "#EXT-X-ENDLIST\n"
                let url = folder.appendingPathComponent("mixed.m3u8")
                try playlist.write(to: url, atomically: true, encoding: .utf8)
                let pcm = try runner.run(ffmpeg, arguments: ["-v", "error", "-i", url.path, "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"])
                let samples = stride(from: 0, to: pcm.count - 1, by: 2).map { Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8) }
                XCTAssertEqual(samples.count, frameCounts.reduce(0, +), "No packets may be duplicated or discarded at mixed joins")
                let reference = samples[48_000..<52_800]
                let referenceRMS = rms(reference)
                var boundary = 0
                for frames in frameCounts.dropLast() {
                    boundary += frames
                    for offset in stride(from: -3600, through: 3600, by: 240) {
                        XCTAssertGreaterThan(rms(samples[(boundary + offset)..<(boundary + offset + 240)]), referenceRMS * 0.75,
                                             "Encoder priming must not create a silent dip at a mixed cached/seek join")
                    }
                }
            }
            await original.stop(); await oddSeek.stop(); await evenSeek.stop()
        } catch {
            await original.stop(); await oddSeek.stop(); await evenSeek.stop()
            throw error
        }
    }

    private func rms(_ samples: ArraySlice<Int16>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
}

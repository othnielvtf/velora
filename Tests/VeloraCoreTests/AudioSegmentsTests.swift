import XCTest
@testable import VeloraCore

final class AudioSegmentsTests: XCTestCase {
    func testCompletedRunKeepsItsEpochForEarlierAndFinalChunks() async throws {
        let fixture = try makeFixture(duration: 6)
        let audio = fixture.audio
        do {
            let first = try await audio.segment(0)
            // The final two-second file has no successor. It becomes available
            // only after FFmpeg exits, so this also exercises completed runs.
            let final = try await audio.segment(1)
            XCTAssertEqual(first.runID, final.runID)
            let earlierAgain = try await audio.segment(0)
            let finalAgain = try await audio.segment(1)
            XCTAssertEqual(earlierAgain.runID, first.runID, "Cached audio must not restart its AAC encoder after EOF")
            XCTAssertEqual(finalAgain.runID, first.runID)
            XCTAssertEqual(earlierAgain.data, first.data)
            XCTAssertEqual(finalAgain.data, final.data)
            await audio.stop()
        } catch { await audio.stop(); throw error }
    }

    func testConcurrentDistantRequestsRetainIndependentRuns() async throws {
        let fixture = try makeFixture(duration: 96)
        let audio = fixture.audio
        do {
            async let beginning = audio.segment(0)
            async let distant = audio.segment(18)
            let (first, later) = try await (beginning, distant)
            XCTAssertFalse(first.data.isEmpty)
            XCTAssertFalse(later.data.isEmpty)
            XCTAssertNotEqual(first.runID, later.runID)
            async let followingBeginning = audio.segment(1)
            async let followingDistant = audio.segment(19)
            let (nextFirst, nextLater) = try await (followingBeginning, followingDistant)
            XCTAssertEqual(nextFirst.runID, first.runID, "A distant seek must not replace the run used by the other request")
            XCTAssertEqual(nextLater.runID, later.runID)
            await audio.stop()
        } catch { await audio.stop(); throw error }
    }

    func testMissingEarlierChunkStartsNewRunInsteadOfWaitingForPastOutput() async throws {
        let fixture = try makeFixture(duration: 96)
        let audio = fixture.audio
        do {
            let first = try await audio.segment(0)
            let chunk = fixture.root.appendingPathComponent("audio").appendingPathComponent(first.runID.uuidString)
                .appendingPathComponent("audio-0.ts")
            // Model cache eviction after the encoder has advanced beyond this
            // file. That encoder cannot produce index zero for a second time.
            try FileManager.default.removeItem(at: chunk)
            let replacement = try await withThrowingTaskGroup(of: PreparedAudio.self) { group in
                group.addTask { try await audio.segment(0) }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw VeloraError("The missing audio chunk waited for output the existing run had already passed.")
                }
                defer { group.cancelAll() }
                let firstResult = try await group.next()
                return try XCTUnwrap(firstResult)
            }
            XCTAssertNotEqual(replacement.runID, first.runID)
            XCTAssertFalse(replacement.data.isEmpty)
            await audio.stop()
        } catch { await audio.stop(); throw error }
    }

    func testStopEndsPacedRunAndRejectsFurtherRequests() async throws {
        let fixture = try makeFixture(duration: 96)
        let audio = fixture.audio
        do {
            _ = try await audio.segment(0)
            // At eight times real time, nine prepared chunks reach the pacing
            // limit within five seconds. A stopped child must resume for TERM.
            try await Task.sleep(for: .seconds(5))
            let started = Date()
            await audio.stop()
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            do {
                _ = try await audio.segment(1)
                XCTFail("A stopped audio session must reject new requests")
            } catch { XCTAssertTrue(error is CancellationError, error.localizedDescription) }
        } catch { await audio.stop(); throw error }
    }

    private func makeFixture(duration: Int) throws -> (audio: AudioSegments, root: URL) {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = MediaTools(directory: repo.appendingPathComponent("Resources/Tools"))
        guard let ffmpeg = try? tools.executable("ffmpeg"), (try? tools.executable("ffprobe")) != nil else {
            throw XCTSkip("Build bundled media tools to run audio lifecycle regression checks")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-audio-runs-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runner = MediaProcessRunner(), input = root.appendingPathComponent("source.mkv")
        _ = try runner.run(ffmpeg, arguments: [
            "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=1",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "\(duration)",
            "-c:v", "h264_videotoolbox", "-b:v", "100k", "-c:a", "pcm_s16le", input.path
        ])
        let media = try MediaInfo.inspect(input, tools: tools, runner: runner)
        let track = try XCTUnwrap(media.defaultAudioTrack)
        return (AudioSegments(media: media, track: track, tools: tools, timeline: StreamTimeline(duration: media.duration),
                              directory: root.appendingPathComponent("audio")), root)
    }
}

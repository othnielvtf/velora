import AVFoundation
import XCTest
import VeloraCore
@testable import Velora

final class NativePlaybackEventTests: XCTestCase {
    @MainActor func testNativePlayAndRateCommandsCannotBypassAnUnavailableAudioRequest() async throws {
        let fixture = try await makeFixture()
        let model = makeModel(root: fixture.root)
        model.setMode(.original)
        model.open(fixture.movie, autoplay: false)
        try await waitUntilReady(model)
        model.selectAudio("audio-3")
        XCTAssertFalse(try XCTUnwrap(model.audioOptions.first { $0.id == "audio-3" }).isPlayable)
        XCTAssertTrue(model.errorMessage?.hasPrefix("Tracks:") == true)

        for command in [{ model.player.play() }, { model.player.rate = 1 }, { model.player.playImmediately(atRate: 1.5) }] {
            command()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(model.player.rate, 0, "Native playback must not resume the retained English option")
            XCTAssertEqual(model.player.timeControlStatus, .paused)
            XCTAssertFalse(model.isPlaying)
            XCTAssertFalse(model.isBuffering)
            XCTAssertEqual(model.selectedAudioTrackID, "audio-3")
            XCTAssertTrue(model.errorMessage?.hasPrefix("Tracks:") == true)
        }
        await model.shutdown()
    }

    @MainActor func testAnActualNativePlayableSelectionClearsTheUnavailableAudioRequest() async throws {
        let fixture = try await makeFixture()
        let model = makeModel(root: fixture.root)
        model.setMode(.original)
        model.open(fixture.movie, autoplay: false)
        try await waitUntilReady(model)
        model.selectAudio("audio-3")

        let item = try XCTUnwrap(model.player.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedGroup)
        let french = try XCTUnwrap(group.options.first { $0.extendedLanguageTag?.hasPrefix("fr") == true })
        XCTAssertTrue(french.isPlayable)
        item.select(french, in: group)
        try await waitUntil("native French selection to update the model") { model.selectedAudioTrackID == "audio-2" }
        XCTAssertNil(model.errorMessage)
        model.player.play()
        try await waitUntil("native playback to resume after recovery") { model.player.rate > 0 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(model.player.rate, 0)
        XCTAssertEqual(model.selectedAudioTrackID, "audio-2")
        await model.shutdown()
    }

    @MainActor func testOlderAppSelectionAcknowledgementsAndUnchangedNotificationsPreserveNewerUnavailableIntent() async throws {
        let fixture = try await makeFixture()
        let model = makeModel(root: fixture.root)
        model.setMode(.original)
        model.open(fixture.movie, autoplay: false)
        try await waitUntilReady(model)
        let item = try XCTUnwrap(model.player.currentItem)

        // AVPlayer applies selections asynchronously. French's acknowledgement
        // belongs to this older app request, even if Japanese is now requested.
        model.selectAudio("audio-2")
        model.selectAudio("audio-3")
        try await Task.sleep(for: .milliseconds(250))
        NotificationCenter.default.post(name: AVPlayerItem.mediaSelectionDidChangeNotification, object: item)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedAudioTrackID, "audio-3")
        XCTAssertTrue(model.errorMessage?.hasPrefix("Tracks:") == true)

        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertTrue(item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag?.hasPrefix("fr") == true)
        let english = try XCTUnwrap(group.options.first { $0.extendedLanguageTag?.hasPrefix("en") == true })
        item.select(english, in: group)
        try await waitUntil("a subsequent native selection to clear the block") { model.selectedAudioTrackID == "audio-1" }
        XCTAssertNil(model.errorMessage)
        await model.shutdown()
    }

    @MainActor func testOriginalSeeksAndNativeTimeUpdatesUseTheNormalizedVideoClock() async throws {
        let fixture = try await makeTimelineFixture()
        let model = makeModel(root: fixture.root)
        model.setMode(.original)
        model.open(fixture.movie, autoplay: false)
        try await waitUntilReady(model)
        try await waitUntil("the initial seek to the first video frame") { !model.isSeeking }
        let item = try XCTUnwrap(model.player.currentItem)
        XCTAssertEqual(model.duration, 10, accuracy: 0.01)
        XCTAssertEqual(item.duration.seconds, 17, accuracy: 0.05, "The native item includes its leading edit and audio tail")
        XCTAssertEqual(item.forwardPlaybackEndTime.seconds, 15, accuracy: 0.01)
        XCTAssertEqual(model.player.currentTime().seconds, 5, accuracy: 0.12)
        XCTAssertEqual(model.position, 0, accuracy: 0.12)
        XCTAssertEqual(model.player.rate, 0)

        model.seek(8)
        try await waitUntil("normalized8 to seek to native13") { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 13, accuracy: 0.12)
        XCTAssertEqual(model.position, 8, accuracy: 0.12)

        _ = await model.player.seek(to: CMTime(seconds: 9, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await waitUntil("native9 to update the normalized position to4") { abs(model.position - 4) < 0.12 }
        XCTAssertEqual(model.player.rate, 0)
        await model.shutdown()
    }

    @MainActor func testPausedOffsetVideoKeepsItsSceneAcrossPlaybackModeRoundTrip() async throws {
        let fixture = try await makeTimelineFixture()
        let model = makeModel(root: fixture.root)
        model.setMode(.original)
        model.open(fixture.movie, at: 8, autoplay: false)
        try await waitUntilReady(model)
        try await waitUntil("the Original seek to settle") { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 13, accuracy: 0.12)

        model.setMode(.compatibility)
        try await waitUntilReady(model)
        try await waitUntil("the Compatibility seek to settle") { !model.isSeeking }
        XCTAssertEqual(model.position, 8, accuracy: 0.12)
        XCTAssertEqual(model.player.currentTime().seconds, 8, accuracy: 0.12)
        XCTAssertEqual(model.player.rate, 0)
        model.setMode(.original)
        try await waitUntilReady(model)
        try await waitUntil("the restored Original seek to settle") { !model.isSeeking }
        XCTAssertEqual(model.position, 8, accuracy: 0.12)
        XCTAssertEqual(model.player.currentTime().seconds, 13, accuracy: 0.12)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertFalse(model.isPlaying)
        await model.shutdown()
    }

    @MainActor private func makeModel(root: URL) -> PlayerModel {
        let model = PlayerModel(tools: tools, cacheRoot: root.appendingPathComponent("Cache"))
        model.player.isMuted = true
        model.player.allowsExternalPlayback = false
        addTeardownBlock { @MainActor in await model.shutdown() }
        return model
    }

    @MainActor private func waitUntilReady(_ model: PlayerModel) async throws {
        try await waitUntil("the movie to finish preparing") { !model.isPreparing }
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay, model.errorMessage ?? "No AVPlayer item")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }

    private var tools: MediaTools {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MediaTools(directory: repository.appendingPathComponent("Resources/Tools"))
    }

    private func makeTimelineFixture() async throws -> (root: URL, movie: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraNativeTimeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("OffsetWithAudioTail.mp4")
        let executable = try tools.executable("ffmpeg")
        _ = try await Task.detached {
            try MediaProcessRunner().run(executable, arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", "color=size=128x72:rate=24:duration=10",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=12",
                "-map", "0:v", "-map", "1:a", "-c:v", "h264_videotoolbox", "-b:v", "100k", "-c:a", "aac",
                "-metadata:s:a:0", "language=eng", "-output_ts_offset", "5", movie.path
            ])
        }.value
        return (root, movie)
    }

    private func makeFixture() async throws -> (root: URL, movie: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraNativeEvents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("MixedAudio.mp4")
        let executable = try tools.executable("ffmpeg")
        _ = try await Task.detached {
            try MediaProcessRunner().run(executable, arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", "color=size=128x72:rate=24",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000",
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
                "-t", "10", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:a",
                "-c:v", "h264_videotoolbox", "-b:v", "100k", "-c:a", "aac",
                "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=fra", "-metadata:s:a:2", "language=jpn",
                "-disposition:a:0", "default", "-disposition:a:1", "0", "-disposition:a:2", "0", movie.path
            ])
        }.value
        var data = try Data(contentsOf: movie)
        var entries: [Range<Data.Index>] = [], offset = data.startIndex
        while let range = data.range(of: Data("mp4a".utf8), in: offset..<data.endIndex) {
            entries.append(range); offset = range.upperBound
        }
        guard entries.count == 3 else { throw VeloraError("Native event fixture has unexpected MP4 sample entries") }
        data.replaceSubrange(entries[2], with: Data("zzzz".utf8))
        try data.write(to: movie)
        return (root, movie)
    }
}

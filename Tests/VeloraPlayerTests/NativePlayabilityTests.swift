import AVFoundation
import Darwin
import XCTest
import VeloraCore
@testable import Velora

final class NativePlayabilityTests: XCTestCase {
    @MainActor func testUnsupportedNativeDefaultDoesNotAutoplayOrLoseRequestedLanguage() async throws {
        let fixtures = try await makeFixtures()
        let group = try await AVURLAsset(url: fixtures.unsupported).loadMediaSelectionGroup(for: .audible)
        XCTAssertEqual(group?.options.count, 2)
        XCTAssertTrue(group?.options.allSatisfy { !$0.isPlayable } == true,
                      "The patched MP4 must reproduce native options that FFmpeg can decode but macOS cannot play")
        let player = NativeRecordingPlayer(), model = makeModel(player, root: fixtures.root)
        model.setMode(.original)
        model.open(fixtures.unsupported)
        try await waitUntilReady(model)

        XCTAssertEqual(model.selectedAudioTrackID, "audio-1")
        XCTAssertEqual(model.audioOptions.count, 2)
        XCTAssertTrue(model.audioOptions.allSatisfy { !$0.isPlayable })
        XCTAssertTrue(model.errorMessage?.contains("TV Compatibility") == true)
        XCTAssertTrue(player.playedRates.isEmpty)
        model.togglePlayback()
        XCTAssertTrue(player.playedRates.isEmpty)
        model.selectAudio("audio-2")
        XCTAssertEqual(model.selectedAudioTrackID, "audio-2")
        XCTAssertTrue(model.errorMessage?.hasPrefix("Tracks:") == true)

        model.setMode(.compatibility)
        try await waitUntilReady(model)
        XCTAssertEqual(model.selectedAudioTrackID, "audio-2")
        XCTAssertTrue(model.audioOptions.allSatisfy(\.isPlayable))
        XCTAssertNil(model.errorMessage)
        await model.shutdown()
    }

    @MainActor func testPlayableNativeTracksRemainSelectableAndAutoplay() async throws {
        let fixtures = try await makeFixtures()
        let player = NativeRecordingPlayer(), model = makeModel(player, root: fixtures.root)
        model.setMode(.original)
        model.open(fixtures.normal)
        try await waitUntilReady(model)

        XCTAssertEqual(player.playedRates, [1])
        XCTAssertEqual(model.selectedAudioTrackID, "audio-1")
        XCTAssertTrue(model.audioOptions.allSatisfy(\.isPlayable))
        model.selectAudio("audio-2")
        XCTAssertEqual(model.selectedAudioTrackID, "audio-2")
        XCTAssertNil(model.errorMessage)
        let item = try XCTUnwrap(player.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertTrue(item.currentMediaSelection.selectedMediaOption(in: group)?.isPlayable == true)
        await model.shutdown()
    }

    @MainActor func testSelectingUnsupportedNativeTrackPausesUntilAPlayableTrackIsChosen() async throws {
        let fixtures = try await makeFixtures()
        let player = NativeRecordingPlayer(), model = makeModel(player, root: fixtures.root)
        model.setMode(.original)
        model.open(fixtures.mixed)
        try await waitUntilReady(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(player.playedRates, [1])

        model.selectAudio("audio-2")
        XCTAssertEqual(model.selectedAudioTrackID, "audio-2")
        XCTAssertTrue(model.errorMessage?.contains("TV Compatibility") == true)
        model.togglePlayback()
        XCTAssertEqual(player.playedRates, [1])

        model.selectAudio("audio-1")
        XCTAssertNil(model.errorMessage)
        model.togglePlayback()
        XCTAssertEqual(player.playedRates, [1, 1])
        await model.shutdown()
    }

    @MainActor func testShutdownWaitsForAProbeFromAPreviouslyClosedMovieAndRejectsNewLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraShutdownProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("probe.pid"), probe = root.appendingPathComponent("ffprobe")
        try "#!/bin/sh\necho $$ > '\(marker.path)'\ntrap '' TERM\nexec /bin/sleep 30\n".write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        let model = PlayerModel(tools: MediaTools(directory: root), cacheRoot: root.appendingPathComponent("Cache"))
        model.player.allowsExternalPlayback = false
        addTeardownBlock { @MainActor in await model.shutdown() }
        model.open(root.appendingPathComponent("Movie.mp4"))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0)
        model.close()

        await model.shutdown()
        await model.shutdown()

        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH, "shutdown must reap even a TERM-ignoring probe closed before quit")
        model.open(root.appendingPathComponent("Another.mp4"))
        XCTAssertFalse(model.isPreparing)
        XCTAssertNil(model.media)
        XCTAssertNil(model.player.currentItem)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor private func makeModel(_ player: AVPlayer, root: URL) -> PlayerModel {
        player.isMuted = true
        let model = PlayerModel(player: player, tools: tools, cacheRoot: root.appendingPathComponent("Cache"))
        model.player.allowsExternalPlayback = false
        addTeardownBlock { @MainActor in await model.shutdown() }
        return model
    }

    @MainActor private func waitUntilReady(_ model: PlayerModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.isPreparing, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay, model.errorMessage ?? "No AVPlayer item")
    }

    private var tools: MediaTools {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MediaTools(directory: repository.appendingPathComponent("Resources/Tools"))
    }

    private func makeFixtures() async throws -> (root: URL, normal: URL, unsupported: URL, mixed: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraNativePlayability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let normal = root.appendingPathComponent("Normal.mp4"), unsupported = root.appendingPathComponent("Unsupported.mp4"), mixed = root.appendingPathComponent("Mixed.mp4")
        let executable = try tools.executable("ffmpeg")
        _ = try await Task.detached {
            try MediaProcessRunner().run(executable, arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                "-f", "lavfi", "-i", "color=size=128x72:rate=24",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
                "-t", "2", "-map", "0:v", "-map", "1:a", "-map", "2:a",
                "-c:v", "h264_videotoolbox", "-b:v", "100k", "-c:a", "aac",
                "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=jpn",
                "-disposition:a:0", "default", "-disposition:a:1", "0", normal.path
            ])
        }.value
        var data = try Data(contentsOf: normal)
        var entries: [Range<Data.Index>] = [], offset = data.startIndex
        while let range = data.range(of: Data("mp4a".utf8), in: offset..<data.endIndex) {
            entries.append(range); offset = range.upperBound
        }
        XCTAssertEqual(entries.count, 2)
        guard entries.count == 2 else { throw VeloraError("Native playability fixture has unexpected MP4 sample entries") }
        data.replaceSubrange(entries[1], with: Data("zzzz".utf8))
        try data.write(to: mixed)
        data.replaceSubrange(entries[0], with: Data("zzzz".utf8))
        try data.write(to: unsupported)
        return (root, normal, unsupported, mixed)
    }
}

private final class NativeRecordingPlayer: AVPlayer, @unchecked Sendable {
    var playedRates: [Float] = []
    override func playImmediately(atRate rate: Float) { playedRates.append(rate) }
}

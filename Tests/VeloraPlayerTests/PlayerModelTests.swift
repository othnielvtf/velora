import AVFoundation
import XCTest
import VeloraCore
@testable import Velora

final class PlayerModelTests: XCTestCase {
    @MainActor func testPauseWhileSeekingDoesNotRestartPlaybackWhenSeekFinishes() async throws {
        let player = RecordingPlayer(), model = makeModel(player: player)
        model.media = try fixture()
        model.togglePlayback()
        model.seek(20)
        model.togglePlayback()
        XCTAssertEqual(player.playedRates, [1])
        XCTAssertEqual(player.pauseCount, 1)

        player.seekCompletions[0](true)
        await drainMainActor()

        XCTAssertEqual(player.playedRates, [1], "The user paused while the uncached seek was pending")
        XCTAssertFalse(model.isSeeking)
        XCTAssertEqual(model.status, "Paused")
        model.close()
    }

    @MainActor func testPlayWhilePausedSeekIsPendingUsesTheLatestIntent() async throws {
        let player = RecordingPlayer(), model = makeModel(player: player)
        model.media = try fixture()
        model.seek(20)
        model.togglePlayback()
        player.seekCompletions[0](true)
        await drainMainActor()

        XCTAssertEqual(player.playedRates, [1, 1])
        XCTAssertFalse(model.isSeeking)
        model.close()
    }

    @MainActor func testOlderSeekAndClosedMovieCannotResumePlayback() async throws {
        let player = RecordingPlayer(), model = makeModel(player: player)
        model.media = try fixture()
        model.togglePlayback()
        model.seek(10)
        model.seek(20)
        player.seekCompletions[0](true)
        await drainMainActor()
        XCTAssertTrue(model.isSeeking, "An older seek must not finish the latest seek")
        XCTAssertEqual(player.playedRates, [1])

        model.close()
        player.seekCompletions[1](true)
        await drainMainActor()
        XCTAssertEqual(player.playedRates, [1])
        XCTAssertNil(model.media)
        XCTAssertFalse(model.isSeeking)
    }

    @MainActor func testCompatibilityQualityChangeLeavesOriginalMovieInstalled() throws {
        let player = RecordingPlayer(), model = makeModel(player: player)
        model.setMode(.original)
        model.media = try fixture()
        model.position = 12
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/original-movie.mp4"))
        player.replaceCurrentItem(with: item)

        model.quality = .hd

        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(model.position, 12)
        XCTAssertNotNil(model.media)
        XCTAssertFalse(model.isPreparing)
        model.close()
    }

    @MainActor func testNativeAudioSurvivesModeRoundTripAndExternalSubtitleLoad() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELORA_PLAYER_TEST_MOVIE"] else {
            throw XCTSkip("Set VELORA_PLAYER_TEST_MOVIE to a native MP4 with at least two audio languages")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = MediaTools(directory: repository.appendingPathComponent("Resources/Tools"))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraPlayerTest-\(UUID())")
        let model = PlayerModel(tools: tools, cacheRoot: cache)
        addTeardownBlock { @MainActor in
            await model.shutdown()
            try? FileManager.default.removeItem(at: cache)
        }
        model.player.isMuted = true
        model.player.allowsExternalPlayback = false
        model.setMode(.original)
        model.open(URL(fileURLWithPath: path), autoplay: false)
        try await waitUntilReady(model)
        let alternate = try XCTUnwrap(model.media?.audioTracks.dropFirst().first)
        let selected = "audio-\(alternate.index)"
        XCTAssertTrue(model.audioOptions.contains { $0.id == selected })
        model.selectAudio(selected)

        model.setMode(.compatibility)
        try await waitUntilReady(model)
        XCTAssertEqual(model.selectedAudioTrackID, selected)
        model.setMode(.original)
        try await waitUntilReady(model)
        XCTAssertEqual(model.selectedAudioTrackID, selected)

        let subtitle = cache.appendingPathComponent("External.vtt")
        try "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nExternal captions\n".write(to: subtitle, atomically: true, encoding: .utf8)
        model.loadSubtitle(subtitle)
        try await waitUntilReady(model)
        XCTAssertEqual(model.mode, .compatibility)
        XCTAssertEqual(model.selectedAudioTrackID, selected)
        XCTAssertEqual(model.selectedSubtitleID, "external")
        XCTAssertNil(model.errorMessage)
        await model.shutdown()
    }

    @MainActor private func makeModel(player: AVPlayer) -> PlayerModel {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraPlayerTest-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        return PlayerModel(player: player, cacheRoot: cache)
    }

    @MainActor private func waitUntilReady(_ model: PlayerModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.isPreparing, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay, model.errorMessage ?? "No AVPlayer item")
        XCTAssertNil(model.errorMessage)
    }

    private func fixture() throws -> MediaInfo {
        let json = #"{"format":{"duration":"30"},"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":640,"height":360}]}"#
        return try MediaInfo.decodeProbe(Data(json.utf8), source: URL(fileURLWithPath: "/tmp/movie.mp4"))
    }

    @MainActor private func drainMainActor() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

private final class RecordingPlayer: AVPlayer, @unchecked Sendable {
    var playedRates: [Float] = []
    var pauseCount = 0
    var seekCompletions: [(Bool) -> Void] = []

    override func playImmediately(atRate rate: Float) { playedRates.append(rate) }
    override func pause() { pauseCount += 1 }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: @escaping (Bool) -> Void) {
        seekCompletions.append(completionHandler)
    }
}

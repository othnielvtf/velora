import XCTest
import Darwin
@testable import VeloraCore

final class SubtitleJobTests: XCTestCase {
    func testTenTracksUseAtMostTwoProcessesAndCancellationDrainsThem() async throws {
        let fixture = try makeFixture(), results = Results()
        let tasks = (1...10).map { request($0, fixture: fixture, results: results) }
        try await waitUntil { fixture.starts.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.starts.count, 2, "Whole-file subtitle scans must have bounded concurrency")
        XCTAssertEqual(fixture.livePIDs.count, 2)

        let first = try XCTUnwrap(fixture.starts.first)
        try fixture.release(first.track)
        try await waitUntil { fixture.starts.count == 3 }
        XCTAssertLessThanOrEqual(fixture.livePIDs.count, 2, "A gate slot must remain occupied until its process exits")

        // Cancel queued consumers first so no newly released slot can start them.
        let startedTracks = Set(fixture.starts.map(\.track))
        for index in 1...10 where !startedTracks.contains(index) { tasks[index - 1].cancel() }
        try await waitUntil { await results.count >= 8 }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        XCTAssertTrue(fixture.livePIDs.isEmpty, "Last-consumer cancellation must reap every extraction")
        XCTAssertEqual(fixture.starts.count, 3, "Cancelled queued jobs must never launch ffmpeg")
        let successCount = await results.successCount, cancellationCount = await results.cancellationCount
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(cancellationCount, 9)
    }

    func testCancellingDuplicateReturnsPromptlyWhileSurvivorCompletesAndCaches() async throws {
        let fixture = try makeFixture(), results = Results()
        let abandoned = request(1, label: "abandoned", fixture: fixture, results: results)
        try await waitUntil { fixture.starts.count == 1 }
        let survivor = request(1, label: "survivor", fixture: fixture, results: results)
        try await waitUntil { await results.entered == 2 }
        try await Task.sleep(for: .milliseconds(50))
        abandoned.cancel()
        try await waitUntil { await results.result("abandoned") != nil }
        let cancellationCount = await results.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(fixture.livePIDs.count, 1, "A shared consumer must retain its extraction")
        XCTAssertEqual(fixture.starts.count, 1)
        try fixture.release(1)
        await abandoned.value; await survivor.value
        let successCount = await results.successCount
        XCTAssertEqual(successCount, 1)
        let cached = try await fixture.session.subtitleSegment(trackID: "embedded-1", index: 0)
        XCTAssertTrue(String(decoding: cached, as: UTF8.self).contains("Track 1"))
        XCTAssertEqual(fixture.starts.count, 1)

        await fixture.session.stop()
        let reopened = try fixture.makeSession()
        let persistent = try await reopened.subtitleSegment(trackID: "embedded-1", index: 0)
        await reopened.stop()
        XCTAssertEqual(cached, persistent, "Completed persistent subtitles must survive a session close")
        XCTAssertEqual(fixture.starts.count, 1)
    }

    func testStopCancelsActiveAndQueuedConsumersAndRemovesPartialFiles() async throws {
        let fixture = try makeFixture(), results = Results()
        let tasks = (1...10).map { request($0, fixture: fixture, results: results) }
        try await waitUntil { fixture.starts.count == 2 }
        await fixture.session.stop()
        for task in tasks { await task.value }
        let cancellationCount = await results.cancellationCount
        XCTAssertEqual(cancellationCount, 10)
        XCTAssertTrue(fixture.livePIDs.isEmpty)
        XCTAssertEqual(fixture.starts.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.session.directory.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.appendingPathComponent("Subtitles").path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".partial") || $0.hasSuffix(".vtt") })
    }

    func testRequestAfterLastConsumerCancellationSurvivesOldWorkerCompletion() async throws {
        let fixture = try makeFixture(), results = Results()
        let abandoned = request(1, label: "abandoned", fixture: fixture, results: results)
        try await waitUntil { fixture.starts.count == 1 }
        let oldPID = try XCTUnwrap(fixture.starts.first?.pid)
        abandoned.cancel()
        try await waitUntil { fixture.wasTerminated(oldPID) }
        let replacement = request(1, label: "replacement", fixture: fixture, results: results)
        try await waitUntil { fixture.starts.count == 2 }
        try fixture.release(1)
        await abandoned.value; await replacement.value
        let successCount = await results.successCount, cancellationCount = await results.cancellationCount
        XCTAssertEqual(successCount, 1, "An old cancelled worker must not erase its replacement's consumers")
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertTrue(fixture.livePIDs.isEmpty)
    }

    private func request(_ track: Int, label: String? = nil, fixture: Fixture, results: Results) -> Task<Void, Never> {
        Task {
            await results.enter()
            do {
                let data = try await fixture.session.subtitleSegment(trackID: "embedded-\(track)", index: 0)
                await results.finish(label ?? String(track), result: .success(data))
            } catch { await results.finish(label ?? String(track), result: .failure(error)) }
        }
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard await condition() else {
            XCTFail("Timed out waiting for subtitle conversion state", file: file, line: line)
            throw VeloraError("Subtitle cancellation test timed out")
        }
    }

    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        addTeardownBlock {
            await fixture.session.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        return fixture
    }

    private actor Results {
        private(set) var entered = 0
        private var completed: [String: Result<Data, Error>] = [:]
        var count: Int { completed.count }
        var successCount: Int { completed.values.filter { if case .success = $0 { return true }; return false }.count }
        var cancellationCount: Int {
            completed.values.filter { if case .failure(let error) = $0 { return error is CancellationError }; return false }.count
        }
        func enter() { entered += 1 }
        func finish(_ label: String, result: Result<Data, Error>) { completed[label] = result }
        func result(_ label: String) -> Result<Data, Error>? { completed[label] }
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let cache: URL
        let tools: URL
        let media: MediaInfo
        let session: TranscodeSession

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Velora Subtitle Jobs \(UUID())")
            cache = root.appendingPathComponent("Cache")
            tools = root.appendingPathComponent("Tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let executable = tools.appendingPathComponent("ffmpeg")
            try """
            #!/bin/sh
            tools=${0%/*}
            previous=
            track=unknown
            for argument in "$@"; do
                if [ "$previous" = '-map' ]; then track=${argument#0:}; fi
                previous=$argument
                output=$argument
            done
            trap 'printf terminated > "$tools/terminated-$$"; /bin/sleep 0.1; exit 0' TERM
            printf '%s\n' "$$" > "$tools/started-$track-$$"
            printf 'WEBVTT\n\n' > "$output"
            while [ ! -f "$tools/release-$track" ]; do /bin/sleep 0.01; done
            printf '00:00.500 --> 00:03.000\nTrack %s\n' "$track" >> "$output"
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let source = root.appendingPathComponent("Ten tracks.mkv")
            try Data("Subtitle source".utf8).write(to: source)
            let streams: [[String: Any]] = [
                ["index": 0, "codec_type": "video", "codec_name": "h264", "width": 16, "height": 16]
            ] + (1...10).map { ["index": $0, "codec_type": "subtitle", "codec_name": "webvtt"] }
            media = try MediaInfo.decodeProbe(JSONSerialization.data(withJSONObject: [
                "format": ["duration": "20"], "streams": streams
            ]), source: source)
            session = try TranscodeSession(media: media, quality: .hd, tools: MediaTools(directory: tools), cacheRoot: cache)
        }

        func makeSession() throws -> TranscodeSession {
            try TranscodeSession(media: media, quality: .hd, tools: MediaTools(directory: tools), cacheRoot: cache)
        }

        var starts: [(track: Int, pid: pid_t)] {
            ((try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? []).compactMap { name in
                let parts = name.split(separator: "-")
                guard parts.count == 3, parts[0] == "started", let track = Int(parts[1]), let pid = pid_t(parts[2]) else { return nil }
                return (track, pid)
            }
        }
        var livePIDs: [pid_t] { starts.map(\.pid).filter { kill($0, 0) == 0 } }
        func wasTerminated(_ pid: pid_t) -> Bool {
            FileManager.default.fileExists(atPath: tools.appendingPathComponent("terminated-\(pid)").path)
        }
        func release(_ track: Int) throws { try Data().write(to: tools.appendingPathComponent("release-\(track)")) }
    }
}

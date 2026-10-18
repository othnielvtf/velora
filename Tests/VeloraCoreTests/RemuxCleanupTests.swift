import XCTest
@testable import VeloraCore

final class RemuxCleanupTests: XCTestCase {
    func testSuccessfulProcessWithEmptyVideoNeverStartsRemuxOrPublishes() async throws {
        let fixture = try makeFixture(mode: "empty-video")
        do { _ = try await fixture.session.segment(0); XCTFail("Empty video must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no playable data"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        try assertPublishedFiles([], fixture: fixture)
        XCTAssertTrue(fixture.events.values.isEmpty)
    }

    func testSuccessfulProcessWithEmptyRemuxNeverPublishes() async throws {
        let fixture = try makeFixture(mode: "empty-remux")
        do { _ = try await fixture.session.segment(0); XCTFail("Empty remux must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no playable data"), error.localizedDescription) }
        try assertPublishedFiles([], fixture: fixture)
        XCTAssertTrue(fixture.events.values.isEmpty)
    }

    func testCancelledPartialRemuxIsRemovedBeforeRequestFinishes() async throws {
        let fixture = try makeFixture(mode: "cancel")
        let request = Task { try await fixture.session.segment(0) }
        try await waitForPartialRemux(fixture)
        let staged = try fixture.partialOutput()
        XCTAssertTrue(staged.deletingLastPathComponent().lastPathComponent.hasPrefix("work-"),
                      "An encoder must write partial transport output inside its scratch directory")
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled remux must fail") }
        catch { XCTAssertTrue(error is CancellationError, error.localizedDescription) }
        try assertPublishedFiles([], fixture: fixture)
        XCTAssertTrue(fixture.events.values.isEmpty, "Partial files must not enter cache accounting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))

        try fixture.setMode("success")
        let completed = try await fixture.session.segment(0)
        try assertPublishedFiles([completed], fixture: fixture)
        try assertCacheContainsOnly(completed, fixture: fixture)
    }

    func testFailedPartialRemuxIsRemovedAndSuccessfulRetryIsAccounted() async throws {
        let fixture = try makeFixture(mode: "fail")
        do { _ = try await fixture.session.segment(0); XCTFail("Failed remux must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("conversion failed"), error.localizedDescription) }
        let staged = try fixture.partialOutput()
        try assertPublishedFiles([], fixture: fixture)
        XCTAssertTrue(fixture.events.values.isEmpty, "Failed files must not enter cache accounting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))

        try fixture.setMode("success")
        let completed = try await fixture.session.segment(0)
        try assertPublishedFiles([completed], fixture: fixture)
        try assertCacheContainsOnly(completed, fixture: fixture)
        let cached = try await fixture.session.segment(0)
        XCTAssertEqual(cached, completed)
    }

    func testFailedReplacementPreservesPreviouslyPublishedInput() async throws {
        let fixture = try makeFixture(mode: "success")
        let original = try await fixture.session.segment(0)
        let originalData = try Data(contentsOf: original)
        // Model eviction of an audio chunk. The next request prepares a new AAC
        // run and remuxes it using the already-published video as its input.
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: fixture.session.directory,
                                                                      includingPropertiesForKeys: nil))
        let audioChunks = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "audio-0.ts" }
        XCTAssertFalse(audioChunks.isEmpty)
        for chunk in audioChunks { try FileManager.default.removeItem(at: chunk) }
        try fixture.setMode("fail")
        do { _ = try await fixture.session.segment(0); XCTFail("Replacement remux must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("conversion failed"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: original), originalData,
                       "Cleanup may remove a failed replacement, but must preserve its cached input")
        try assertPublishedFiles([original], fixture: fixture)
        try assertCacheContainsOnly(original, fixture: fixture)
    }

    private func assertPublishedFiles(_ expected: [URL], fixture: Fixture,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try FileManager.default.contentsOfDirectory(at: fixture.session.directory,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.filter { $0.pathExtension == "ts" }.map(\.lastPathComponent)),
                       Set(expected.map(\.lastPathComponent)), file: file, line: line)
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("work-") },
                       "A completed request must remove its scratch directory", file: file, line: line)
    }

    private func assertCacheContainsOnly(_ url: URL, fixture: Fixture,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let event = try XCTUnwrap(fixture.events.values.last, file: file, line: line)
        XCTAssertEqual(event.cachedIndices, [0], file: file, line: line)
        XCTAssertEqual(event.cachedBytes, Int64(try Data(contentsOf: url).count), file: file, line: line)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "complete transport", file: file, line: line)
    }

    private func waitForPartialRemux(_ fixture: Fixture) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: fixture.marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path), "Remux must write a partial file before cancellation")
    }

    private func makeFixture(mode: String) throws -> Fixture {
        let fixture = try Fixture(mode: mode)
        addTeardownBlock {
            await fixture.session.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        return fixture
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SegmentEvent] = []
        func append(_ event: SegmentEvent) { lock.lock(); defer { lock.unlock() }; recorded.append(event) }
        var values: [SegmentEvent] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let tools: URL
        let marker: URL
        let session: TranscodeSession
        let events: Events

        init(mode: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Velora Remux Tests \(UUID())")
            tools = root.appendingPathComponent("Tools")
            marker = tools.appendingPathComponent("remux-started")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            try mode.write(to: tools.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let executable = tools.appendingPathComponent("ffmpeg")
            try """
            #!/bin/sh
            tools=${0%/*}
            previous=
            is_audio=0
            inputs=0
            start=0
            for argument in "$@"; do
                if [ "$previous" = '-f' ] && [ "$argument" = 'segment' ]; then is_audio=1; fi
                if [ "$previous" = '-segment_start_number' ]; then start=$argument; fi
                if [ "$argument" = '-i' ]; then inputs=$((inputs + 1)); fi
                previous=$argument
                output=$argument
            done
            if [ "$is_audio" = 1 ]; then
                folder=${output%/*}
                index=$start
                while [ "$index" -lt 8 ]; do
                    printf audio > "$folder/audio-$index.ts"
                    index=$((index + 1))
                done
            elif [ "$inputs" = 2 ]; then
                printf PARTIAL_REMUX > "$output"
                printf '%s' "$output" > "$tools/remux-started"
                mode=$(/bin/cat "$tools/mode")
                if [ "$mode" = 'fail' ]; then exit 23; fi
                if [ "$mode" = 'cancel' ]; then
                    trap 'exit 0' TERM
                    while :; do :; done
                fi
                if [ "$mode" = 'empty-remux' ]; then : > "$output"; exit 0; fi
                printf 'complete transport' > "$output"
            else
                mode=$(/bin/cat "$tools/mode")
                if [ "$mode" = 'empty-video' ]; then : > "$output"; exit 0; fi
                printf video > "$output"
            fi
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let source = root.appendingPathComponent("source.mkv")
            try Data().write(to: source)
            let probe: [String: Any] = ["format": ["duration": "32"], "streams": [
                ["index": 0, "codec_type": "video", "codec_name": "h264", "width": 16, "height": 16],
                ["index": 1, "codec_type": "audio", "codec_name": "aac", "channels": 2]
            ]]
            let media = try MediaInfo.decodeProbe(JSONSerialization.data(withJSONObject: probe), source: source)
            events = Events()
            let events = events
            session = try TranscodeSession(media: media, quality: .hd, tools: MediaTools(directory: tools),
                                           cacheRoot: root.appendingPathComponent("Cache"), onEvent: { events.append($0) })
        }

        func setMode(_ mode: String) throws {
            try mode.write(to: tools.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        }

        func partialOutput() throws -> URL {
            URL(fileURLWithPath: try String(contentsOf: marker, encoding: .utf8))
        }
    }
}

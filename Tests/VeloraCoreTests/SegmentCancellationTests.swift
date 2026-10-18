import XCTest
import Darwin
@testable import VeloraCore

final class SegmentCancellationTests: XCTestCase {
    func testCancellingOneDuplicateKeepsSharedProcessForSurvivor() async throws {
        let fixture = try makeFixture(), results = Results()
        let abandoned = request(0, label: "abandoned", fixture: fixture, results: results)
        try await waitUntil { fixture.starts(for: 0).count == 1 }
        let survivor = request(0, label: "survivor", fixture: fixture, results: results)
        try await waitUntil { await results.entered.count == 2 }
        // Give the second caller time to join the actor's existing job before cancellation.
        try await Task.sleep(for: .milliseconds(50))
        abandoned.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let pid = try XCTUnwrap(fixture.starts(for: 0).first)
        XCTAssertEqual(kill(pid, 0), 0, "One consumer must not terminate the other consumer's encoder")
        XCTAssertEqual(fixture.starts(for: 0).count, 1, "Duplicate requests must share a single conversion")
        XCTAssertFalse(fixture.wasTerminated(pid))
        try fixture.release(0)
        try await waitUntil { await results.completed.count == 2 }
        assertCancelled(await results.result("abandoned"))
        let url = try success(await results.result("survivor"))
        XCTAssertEqual(try Data(contentsOf: url), Data("transport at 0\n".utf8))
        let cached = try await fixture.session.segment(0)
        XCTAssertEqual(cached, url)
        XCTAssertEqual(fixture.starts(for: 0).count, 1, "The surviving request must populate the segment cache")
        _ = await abandoned.value; _ = await survivor.value
    }

    func testCancellingAllConsumersReapsActiveJobsAndRemovesQueuedJobs() async throws {
        let fixture = try makeFixture(), results = Results()
        var tasks = [request(0, label: "zero-a", fixture: fixture, results: results),
                     request(0, label: "zero-b", fixture: fixture, results: results),
                     request(1, label: "one", fixture: fixture, results: results)]
        try await waitUntil { fixture.starts(for: 0).count == 1 && fixture.starts(for: 1).count == 1 }
        tasks += [request(2, label: "queued-a", fixture: fixture, results: results),
                  request(2, label: "queued-b", fixture: fixture, results: results),
                  request(3, label: "queued-c", fixture: fixture, results: results)]
        try await waitUntil { await results.entered.count == 6 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.starts(for: 2).isEmpty)
        XCTAssertTrue(fixture.starts(for: 3).isEmpty)
        let activePIDs = fixture.starts(for: 0) + fixture.starts(for: 1)
        for task in tasks { task.cancel() }
        try await waitUntil { await results.completed.count == 6 }
        for label in ["zero-a", "zero-b", "one", "queued-a", "queued-b", "queued-c"] {
            assertCancelled(await results.result(label))
        }
        for pid in activePIDs {
            let status = kill(pid, 0), signalError = errno
            XCTAssertEqual(status, -1, "Cancelled encoders must be reaped before requests finish")
            XCTAssertEqual(signalError, ESRCH)
        }
        XCTAssertTrue(fixture.starts(for: 2).isEmpty, "Cancelled queued jobs must never launch ffmpeg")
        XCTAssertTrue(fixture.starts(for: 3).isEmpty, "Unused queued jobs must release their gate waiters")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.session.directory.path)
        XCTAssertFalse(leftovers.contains(where: { $0.hasPrefix("work-") }), "Cancelled workers must remove partial output")

        let next = request(4, label: "next", fixture: fixture, results: results)
        try await waitUntil { fixture.starts(for: 4).count == 1 }
        try fixture.release(4)
        try await waitUntil { await results.result("next") != nil }
        let url = try success(await results.result("next"))
        XCTAssertEqual(try Data(contentsOf: url), Data("transport at 16\n".utf8))
        for task in tasks { _ = await task.value }
        _ = await next.value
    }

    private func request(_ index: Int, label: String, fixture: Fixture, results: Results) -> Task<Void, Never> {
        Task {
            await results.enter(label)
            do { await results.finish(label, result: .success(try await fixture.session.segment(index))) }
            catch { await results.finish(label, result: .failure(error)) }
        }
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard await condition() else {
            XCTFail("Timed out waiting for segment conversion state", file: file, line: line)
            throw VeloraError("Segment cancellation test timed out")
        }
    }

    private func assertCancelled(_ result: Result<URL, Error>?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else {
            XCTFail("Expected a cancelled segment request", file: file, line: line); return
        }
        XCTAssertTrue(error is CancellationError, error.localizedDescription, file: file, line: line)
    }

    private func success(_ result: Result<URL, Error>?, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(result, file: file, line: line).get()
    }

    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        addTeardownBlock {
            try? fixture.releaseAll()
            await fixture.session.stop()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        return fixture
    }

    private actor Results {
        private(set) var entered = Set<String>()
        private(set) var completed: [String: Result<URL, Error>] = [:]
        func enter(_ label: String) { entered.insert(label) }
        func finish(_ label: String, result: Result<URL, Error>) { completed[label] = result }
        func result(_ label: String) -> Result<URL, Error>? { completed[label] }
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let tools: URL
        let session: TranscodeSession

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Velora Cancellation Tests \(UUID())")
            tools = root.appendingPathComponent("Tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let executable = tools.appendingPathComponent("ffmpeg")
            try """
            #!/bin/sh
            tools=${0%/*}
            previous=
            seconds=0
            for argument in "$@"; do
                if [ "$previous" = '-ss' ]; then seconds=${argument%%.*}; fi
                previous=$argument
                output=$argument
            done
            trap 'printf terminated > "$tools/terminated-$$"; exit 0' TERM
            printf '%s\n' "$$" > "$tools/started-$seconds-$$"
            while [ ! -f "$tools/release-$seconds" ]; do /bin/sleep 0.01; done
            printf 'transport at %s\n' "$seconds" > "$output"
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let probe: [String: Any] = ["format": ["duration": "80"], "streams": [
                ["index": 0, "codec_type": "video", "codec_name": "h264", "width": 16, "height": 16]
            ]]
            let source = root.appendingPathComponent("Silent fixture.mkv")
            try Data().write(to: source)
            let media = try MediaInfo.decodeProbe(JSONSerialization.data(withJSONObject: probe), source: source)
            session = try TranscodeSession(media: media, quality: .hd, tools: MediaTools(directory: tools),
                                           cacheRoot: root.appendingPathComponent("Cache"))
        }

        func starts(for index: Int) -> [pid_t] {
            let prefix = "started-\(index * 4)-"
            return ((try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? [])
                .filter { $0.hasPrefix(prefix) }.compactMap { pid_t($0.dropFirst(prefix.count)) }
        }

        func wasTerminated(_ pid: pid_t) -> Bool {
            FileManager.default.fileExists(atPath: tools.appendingPathComponent("terminated-\(pid)").path)
        }

        func release(_ index: Int) throws { try Data().write(to: tools.appendingPathComponent("release-\(index * 4)")) }
        func releaseAll() throws { for index in 0..<20 { try release(index) } }
    }
}

import XCTest
@testable import VeloraCore

final class SubtitleStoreTests: XCTestCase {
    func testConvertedTrackSurvivesNewStoreInstance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        let second = try SubtitleStore(directory: fixture.cache).load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(first.cues, second.cues)
        XCTAssertEqual(first.cues.first?.text, "Cached subtitle")
        XCTAssertEqual(try fixture.extractionCount(), 1)
    }

    func testSourceSizeAndModificationTimeInvalidateCachedTracks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        try Data("A longer source file".utf8).write(to: fixture.source.url)
        _ = try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(try fixture.extractionCount(), 2)

        let modified = try fixture.source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(10)], ofItemAtPath: fixture.source.url.path)
        _ = try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(try fixture.extractionCount(), 3)
    }

    func testConcurrentStoreInstancesPublishOneCompleteDocument() async throws {
        let fixture = try Fixture(extractionDelay: 0.15)
        defer { fixture.remove() }
        let secondStore = SubtitleStore(directory: fixture.cache)
        let first = Task.detached {
            try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        }
        let second = Task.detached {
            try secondStore.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        }
        let firstDocument = try await first.value
        let secondDocument = try await second.value
        XCTAssertEqual(firstDocument.cues.count, 1)
        XCTAssertEqual(firstDocument.cues, secondDocument.cues)
        XCTAssertEqual(try fixture.extractionCount(), 1)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "vtt" }.count, 1)
        XCTAssertFalse(files.contains { $0.pathExtension == "partial" })
    }

    func testCorruptCachedDocumentIsExtractedAgain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        let cached = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "vtt" })
        try Data("Incomplete subtitle data".utf8).write(to: cached)
        let repaired = try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        XCTAssertEqual(repaired.cues.first?.text, "Cached subtitle")
        XCTAssertEqual(try fixture.extractionCount(), 2)
    }

    func testPublicationPrunesCompletedCacheTo256MB() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        for index in 0..<17 {
            let old = fixture.cache.appendingPathComponent("old-\(index).vtt")
            FileManager.default.createFile(atPath: old.path, contents: nil)
            let handle = try FileHandle(forWritingTo: old)
            try handle.truncate(atOffset: 16 * 1024 * 1024)
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: old.path)
        }
        _ = try fixture.store.load(source: fixture.source, tools: fixture.tools, runner: MediaProcessRunner())
        let files = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.filter { $0.pathExtension == "vtt" }.reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(bytes, 256 * 1024 * 1024)
        XCTAssertEqual(try fixture.extractionCount(), 1)
    }

    func testFullScanTimeoutScalesWithSourceSizeAndRemainsBounded() {
        XCTAssertEqual(SubtitleStore.extractionTimeout(fileSize: 0), 120)
        XCTAssertEqual(SubtitleStore.extractionTimeout(fileSize: 20_000_000_000), 4_060)
        XCTAssertEqual(SubtitleStore.extractionTimeout(fileSize: Int64.max), 12 * 3600)
    }

    private struct Fixture: Sendable {
        let root: URL
        let cache: URL
        let source: SubtitleSource
        let tools: MediaTools
        let counter: URL
        var store: SubtitleStore { SubtitleStore(directory: cache) }

        init(extractionDelay: Double = 0) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("velora-subtitle-store-tests-\(UUID().uuidString)")
            cache = root.appendingPathComponent("cache")
            counter = root.appendingPathComponent("extractions")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let input = root.appendingPathComponent("External.srt")
            try Data("Subtitle source".utf8).write(to: input)
            source = SubtitleSource(externalURL: input)
            tools = MediaTools(directory: root)
            let script = """
            #!/bin/sh
            set -eu
            printf 'run\\n' >> '\(counter.path)'
            for output in "$@"; do :; done
            printf 'WEBVTT\\n\\n' > "$output"
            /bin/sleep \(extractionDelay)
            printf '00:00.500 --> 00:04.000\\nCached subtitle\\n' >> "$output"
            """
            let executable = root.appendingPathComponent("ffmpeg")
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func extractionCount() throws -> Int {
            try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

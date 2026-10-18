import XCTest
@testable import VeloraCore

final class StreamingTests: XCTestCase {
    func testVODTimelineIncludesWholeMovieAndExactFinalChunk() {
        let timeline = StreamTimeline(duration: 14.25)
        XCTAssertEqual(timeline.count, 4)
        XCTAssertEqual(timeline.start(3), 12)
        XCTAssertEqual(timeline.length(3), 2.25)
        let manifest = timeline.playlist()
        XCTAssertTrue(manifest.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(manifest.contains("#EXTINF:2.250000,\nsegment-3.ts"))
        XCTAssertTrue(manifest.hasSuffix("#EXT-X-ENDLIST\n"))
        XCTAssertFalse(manifest.contains("#EXT-X-DISCONTINUITY"))
    }

    func testExactBoundaryDoesNotCreateEmptyChunk() {
        XCTAssertEqual(StreamTimeline(duration: 12).count, 3)
        XCTAssertEqual(StreamTimeline(duration: 12).length(2), 4)
        XCTAssertEqual(StreamTimeline(duration: 0.1).count, 1)
    }

    func testSubframeTailStaysWithTheFinalVideoChunk() {
        let timeline = StreamTimeline(duration: 20.02, minimumFinalSegmentDuration: 1001.0 / 30_000)
        XCTAssertEqual(timeline.count, 5)
        XCTAssertEqual(timeline.start(4), 16)
        XCTAssertEqual(timeline.length(4), 4.02, accuracy: 0.000001)
        XCTAssertTrue(timeline.playlist().contains("#EXT-X-TARGETDURATION:5"))
        XCTAssertTrue(timeline.playlist().contains("#EXTINF:4.020000,\nsegment-4.ts"))
        XCTAssertEqual(StreamTimeline(duration: 20.1, minimumFinalSegmentDuration: 1001.0 / 30_000).count, 6)
    }

    func testByteRangesCoverTVRequests() throws {
        XCTAssertEqual(try ByteRange.parse("bytes=0-187", size: 1000), ByteRange(lower: 0, upper: 187))
        XCTAssertEqual(try ByteRange.parse("bytes=800-", size: 1000), ByteRange(lower: 800, upper: 999))
        XCTAssertEqual(try ByteRange.parse("bytes=-200", size: 1000), ByteRange(lower: 800, upper: 999))
        XCTAssertEqual(try ByteRange.parse("bytes=0-99999", size: 1000).count, 1000)
        for invalid in ["bytes=1000-", "bytes=10-9", "bytes=-0", "bytes=0-1,5-6", "x=0-1", "bytes=--", "bytes=0-x"] {
            XCTAssertThrowsError(try ByteRange.parse(invalid, size: 1000), invalid)
        }
        XCTAssertThrowsError(try ByteRange.parse("bytes=0-", size: 0))
    }

    func testHTTPParsingAndHEADResponse() throws {
        let request = try HTTPRequest(Data("HEAD /token/segment-2.ts?x=y HTTP/1.1\r\nRange: bytes=0-187\r\nHost: localhost\r\n\r\n".utf8))
        XCTAssertEqual(request.method, "HEAD")
        XCTAssertEqual(request.path, "/token/segment-2.ts")
        XCTAssertEqual(request.headers["range"], "bytes=0-187")
        let response = HTTPResponse(type: "video/mp2t", body: Data("video".utf8))
        let head = String(decoding: response.serialized(head: true), as: UTF8.self)
        XCTAssertTrue(head.contains("Content-Length: 5\r\n"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(head.hasSuffix("video"))
        XCTAssertThrowsError(try HTTPRequest(Data("garbage\r\n\r\n".utf8)))
    }
}

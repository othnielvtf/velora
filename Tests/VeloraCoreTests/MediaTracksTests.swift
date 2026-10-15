import XCTest
@testable import VeloraCore

final class MediaTracksTests: XCTestCase {
    func testProbeKeepsGlobalTrackIndexesLanguagesAndDefaultAudio() throws {
        let info = try fixture()
        XCTAssertEqual(info.audioTracks.map(\.index), [2, 7])
        XCTAssertEqual(info.defaultAudioTrack?.index, 7)
        XCTAssertEqual(info.audioCodec, "ac3")
        XCTAssertEqual(info.audioTracks.map(\.language), ["en", "ja"])
        XCTAssertEqual(info.subtitleTracks.map(\.index), [9, 12])
        XCTAssertTrue(info.subtitleTracks[0].supportsTextSubtitles)
        XCTAssertTrue(info.subtitleTracks[0].isSDH)
        XCTAssertFalse(info.subtitleTracks[1].supportsTextSubtitles)
        XCTAssertEqual(info.videoCodec, "hevc")
        XCTAssertEqual(info.width, 1920)
    }

    func testSubtitleManifestEscapesMetadataAndKeepsSafeResourceIDs() throws {
        let info = try fixture()
        let source = SubtitleSource(media: info, track: info.subtitleTracks[0])
        XCTAssertEqual(source.id, "embedded-9")
        XCTAssertTrue(source.mediaTag.contains("LANGUAGE=\"en\""))
        XCTAssertTrue(source.mediaTag.contains("URI=\"subtitles/embedded-9/index.m3u8\""))
        XCTAssertTrue(source.mediaTag.contains("public.accessibility.transcribes-spoken-dialog"))
        XCTAssertFalse(source.mediaTag.contains("\n"))
        XCTAssertFalse(source.hlsName.contains("\""))
        XCTAssertEqual(MediaTrack.languageTag("JPN"), "ja")
        XCTAssertEqual(MediaTrack.languageTag("en_US"), "en-us")
        XCTAssertEqual(MediaTrack.languageTag("en\n#EXTM3U"), "und")
    }

    func testWebVTTCuesCrossSegmentBoundariesWithoutBeingShifted() throws {
        let document = try SubtitleDocument(webVTT: """
        WEBVTT

        cue-one
        00:00:00.500 --> 00:00:06.000 align:center
        <i>English</i>
        日本語

        00:06.000 --> 00:08.000
        Second cue

        00:12.000 --> 00:13.250
        Ending
        """)
        let first = document.segment(start: 0, duration: 4)
        let second = document.segment(start: 4, duration: 4)
        XCTAssertTrue(first.contains("00:00:00.500 --> 00:00:06.000 align:center"))
        XCTAssertTrue(second.contains("00:00:00.500 --> 00:00:06.000 align:center"))
        XCTAssertTrue(second.contains("Second cue"))
        XCTAssertFalse(first.contains("Second cue"))
        XCTAssertFalse(document.segment(start: 8, duration: 4).contains("Second cue"))
        XCTAssertFalse(document.segment(start: 8, duration: 4).contains("Ending"))
        XCTAssertTrue(document.segment(start: 12, duration: 1.25).contains("Ending"))
        XCTAssertTrue(first.contains("X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0"))
        XCTAssertTrue(first.contains("日本語"))
        let playlist = StreamTimeline(duration: 13.25).playlist(segmentExtension: "vtt")
        XCTAssertTrue(playlist.contains("#EXTINF:1.250000,\nsegment-3.vtt"))
        XCTAssertEqual(playlist.components(separatedBy: "#EXT-X-DISCONTINUITY").count - 1, 3)
    }

    func testEmptySubtitlesAndInvalidTimes() throws {
        XCTAssertEqual(try SubtitleDocument(webVTT: "\u{FEFF}WEBVTT\r\n\r\n").cues.count, 0)
        for text in ["garbage", "WEBVTT\n\n00:00:03.000 --> 00:00:01.000\nBackwards",
                     "WEBVTT\n\n00:99:00.000 --> 01:00:00.000\nBad minutes",
                     "WEBVTT\n\n999999999999999999999:00:00 --> 999999999999999999999:00:01\nOverflow"] {
            XCTAssertThrowsError(try SubtitleDocument(webVTT: text))
        }
    }

    private func fixture() throws -> MediaInfo {
        let json: [String: Any] = ["format": ["duration": "30.0"], "streams": [
            ["index": 0, "codec_type": "video", "codec_name": "png", "width": 600, "height": 600, "disposition": ["attached_pic": 1]],
            ["index": 1, "codec_type": "video", "codec_name": "hevc", "width": 1920, "height": 1080, "avg_frame_rate": "30/1"],
            ["index": 2, "codec_type": "audio", "codec_name": "aac", "channels": 2, "tags": ["language": "eng"]],
            ["index": 7, "codec_type": "audio", "codec_name": "ac3", "channels": 6, "tags": ["language": "jpn"], "disposition": ["default": 1]],
            ["index": 9, "codec_type": "subtitle", "codec_name": "subrip", "tags": ["language": "eng", "title": "English \"SDH\"\n#EXTM3U"], "disposition": ["hearing_impaired": 1]],
            ["index": 12, "codec_type": "subtitle", "codec_name": "hdmv_pgs_subtitle", "tags": ["language": "jpn"]]
        ]]
        return try MediaInfo.decodeProbe(JSONSerialization.data(withJSONObject: json), source: URL(fileURLWithPath: "/tmp/fixture.mkv"))
    }
}

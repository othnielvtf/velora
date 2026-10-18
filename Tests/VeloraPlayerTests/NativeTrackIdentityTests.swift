import XCTest
import VeloraCore
@testable import Velora

final class NativeTrackIdentityTests: XCTestCase {
    func testReorderedSameLanguageAudioVariantsKeepTheirSourceIdentity() throws {
        let media = try fixture()
        let native = [
            NativeTrackDescriptor(language: "jpn", title: "Main", codecs: ["aac"]),
            NativeTrackDescriptor(language: "eng", title: "Director Commentary", codecs: ["aac"]),
            NativeTrackDescriptor(language: "eng", title: "Main", codecs: ["aac"])
        ]
        let mapping = NativeTrackIdentity.match(native, to: media.audioTracks)
        XCTAssertEqual(mapping, [0: 11, 1: 7, 2: 2])
        // The compatibility encoder uses stream 7; its corresponding Original
        // option is at offset 1, not source ordinal 1 in an assumed group order.
        XCTAssertEqual(mapping.first(where: { $0.value == 7 })?.key, 1)
    }

    func testSameLanguageSubtitleAccessibilityAndForcedVariantsStayDistinct() throws {
        let media = try fixture()
        let native = [
            NativeTrackDescriptor(language: "eng", title: "English", codecs: ["mov_text"], isSDH: true),
            NativeTrackDescriptor(language: "eng", title: "English", codecs: ["mov_text"], isForced: true),
            NativeTrackDescriptor(language: "eng", title: "English", codecs: ["mov_text"])
        ]
        XCTAssertEqual(NativeTrackIdentity.match(native, to: media.subtitleTracks), [0: 18, 1: 23, 2: 14])
    }

    func testMissingMetadataDoesNotGuessBetweenSameLanguageVariants() throws {
        let native = [NativeTrackDescriptor(language: "en", title: nil, codecs: ["aac"])]
        XCTAssertTrue(NativeTrackIdentity.match(native, to: try fixture().audioTracks).isEmpty,
                      "A missing or unsupported native variant must not shift source indexes")
    }

    func testDuplicateNativeOptionsCannotBothClaimTheSameSourceTrack() throws {
        let native = Array(repeating: NativeTrackDescriptor(language: "ja", title: "Main", codecs: ["aac"]), count: 2)
        XCTAssertTrue(NativeTrackIdentity.match(native, to: try fixture().audioTracks).isEmpty)
    }

    private func fixture() throws -> MediaInfo {
        let streams: [[String: Any]] = [
            ["index": 0, "codec_type": "video", "codec_name": "h264"],
            ["index": 2, "codec_type": "audio", "codec_name": "aac", "tags": ["language": "eng", "title": "Main"]],
            ["index": 7, "codec_type": "audio", "codec_name": "aac", "tags": ["language": "eng", "title": "Director Commentary"]],
            ["index": 11, "codec_type": "audio", "codec_name": "aac", "tags": ["language": "jpn", "title": "Main"]],
            ["index": 14, "codec_type": "subtitle", "codec_name": "mov_text", "tags": ["language": "eng", "title": "English"]],
            ["index": 18, "codec_type": "subtitle", "codec_name": "mov_text", "tags": ["language": "eng", "title": "English"], "disposition": ["hearing_impaired": 1]],
            ["index": 23, "codec_type": "subtitle", "codec_name": "mov_text", "tags": ["language": "eng", "title": "English"], "disposition": ["forced": 1]]
        ]
        return try MediaInfo.decodeProbe(JSONSerialization.data(withJSONObject: ["format": ["duration": "30"], "streams": streams]),
                                         source: URL(fileURLWithPath: "/tmp/multitrack.mp4"))
    }
}

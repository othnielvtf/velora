import Foundation

public struct MediaTrack: Identifiable, Equatable, Sendable {
    public let index: Int
    public let ordinal: Int
    public let codec: String
    public let title: String?
    public let language: String
    public let channels: Int?
    public let isDefault: Bool
    public let isForced: Bool
    public let isSDH: Bool
    public var id: Int { index }
    public var supportsTextSubtitles: Bool {
        ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec)
    }
    public var label: String {
        var parts: [String] = []
        if language != "und" {
            parts.append(Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language.uppercased())
        }
        if let title, !title.isEmpty, parts.first?.caseInsensitiveCompare(title) != .orderedSame { parts.append(title) }
        if parts.isEmpty { parts.append("Track \(ordinal + 1)") }
        if let channels {
            let layout = [1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"][channels] ?? "\(channels) ch"
            parts.append("\(layout) · \(codec.uppercased())")
        }
        if isForced { parts.append("Forced") }
        if isSDH { parts.append("SDH") }
        return parts.joined(separator: " · ")
    }

    static func parse(_ streams: [[String: Any]], kind: String) -> [MediaTrack] {
        streams.filter { $0["codec_type"] as? String == kind }.enumerated().compactMap { ordinal, stream in
            guard let index = stream["index"] as? Int, index >= 0 else { return nil }
            let tags = stream["tags"] as? [String: String] ?? [:]
            let disposition = stream["disposition"] as? [String: Int] ?? [:]
            return MediaTrack(index: index, ordinal: ordinal, codec: stream["codec_name"] as? String ?? "unknown",
                              title: tags["title"].map { String($0.prefix(160)) },
                              language: languageTag(tags["language"] ?? "und"), channels: stream["channels"] as? Int,
                              isDefault: disposition["default"] == 1, isForced: disposition["forced"] == 1,
                              isSDH: disposition["hearing_impaired"] == 1)
        }
    }

    public static func languageTag(_ raw: String) -> String {
        let value = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        guard !value.isEmpty, value.count <= 35,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }) else { return "und" }
        let aliases = ["eng":"en", "spa":"es", "fra":"fr", "fre":"fr", "deu":"de", "ger":"de", "ita":"it",
                       "por":"pt", "jpn":"ja", "kor":"ko", "zho":"zh", "chi":"zh", "msa":"ms", "may":"ms",
                       "ind":"id", "ara":"ar", "hin":"hi", "tam":"ta", "tha":"th", "rus":"ru", "vie":"vi",
                       "nld":"nl", "dut":"nl", "tur":"tr", "pol":"pl", "ces":"cs", "cze":"cs", "ukr":"uk"]
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty }), let first = parts.first, (2...3).contains(first.count),
              first.allSatisfy({ $0.isLetter }) else { return "und" }
        return ([aliases[String(first)] ?? String(first)] + parts.dropFirst().map(String.init)).joined(separator: "-")
    }
}

public struct SubtitleSource: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let language: String
    public let isForced: Bool
    public let isSDH: Bool
    public let url: URL
    public let streamIndex: Int

    public init(media: MediaInfo, track: MediaTrack) {
        id = "embedded-\(track.index)"; label = "\(track.label) [\(track.ordinal + 1)]"
        language = track.language; isForced = track.isForced; isSDH = track.isSDH
        url = media.source; streamIndex = track.index
    }

    public init(externalURL: URL) {
        id = "external"; label = "External · \(externalURL.deletingPathExtension().lastPathComponent.prefix(120))"
        language = "und"; isForced = false; isSDH = false; url = externalURL; streamIndex = 0
    }

    public var hlsName: String { Self.quotedValue(label) }
    public var mediaTag: String {
        var value = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(hlsName)\",LANGUAGE=\"\(language)\",DEFAULT=NO,AUTOSELECT=YES,FORCED=\(isForced ? "YES" : "NO"),URI=\"subtitles/\(id)/index.m3u8\""
        if isSDH { value += ",CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\"" }
        return value
    }

    public static func quotedValue(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .replacingOccurrences(of: "\"", with: "'")
    }
}

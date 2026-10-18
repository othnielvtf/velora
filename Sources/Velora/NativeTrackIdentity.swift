import AVFoundation
import VeloraCore

/// Native option order and display names are not source-stream identifiers.
/// Match only when the available source metadata identifies one option uniquely.
struct NativeTrackDescriptor {
    var language: String
    var title: String?
    var codecs: Set<String> = []
    var isForced = false
    var isSDH = false

    func matches(_ track: MediaTrack) -> Bool {
        guard MediaTrack.languageTag(language) == track.language,
              isForced == track.isForced, isSDH == track.isSDH,
              codecs.isEmpty || codecs.contains(track.codec) else { return false }
        if let title = Self.normalized(title), let sourceTitle = Self.normalized(track.title) {
            return title == sourceTitle
        }
        return true
    }

    private static func normalized(_ title: String?) -> String? {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(160)).lowercased()
    }
}

enum NativeTrackIdentity {
    /// Returns native-option offsets mapped to global source-stream indexes.
    /// Multiple indistinguishable variants remain unmapped, including when one
    /// of the source tracks is not exposed by AVFoundation.
    static func match(_ options: [NativeTrackDescriptor], to sources: [MediaTrack]) -> [Int: Int] {
        var candidates = Dictionary(uniqueKeysWithValues: options.enumerated().map { offset, option in
            (offset, Set(sources.filter(option.matches).map(\.index)))
        })
        var result: [Int: Int] = [:]
        while true {
            let singletons = candidates.compactMap { offset, values -> (Int, Int)? in
                values.count == 1 ? (offset, values.first!) : nil
            }
            let unique = singletons.filter { candidate in
                singletons.filter { $0.1 == candidate.1 }.count == 1
            }
            guard !unique.isEmpty else { break }
            for (offset, stream) in unique {
                result[offset] = stream
                candidates[offset] = nil
                for other in Array(candidates.keys) { candidates[other]?.remove(stream) }
            }
        }
        return result
    }

    @MainActor static func options(_ options: [AVMediaSelectionOption], sources: [MediaTrack],
                                   prefix: String, fallbackPrefix: String) async -> [(id: String, option: AVMediaSelectionOption)] {
        var descriptors: [NativeTrackDescriptor] = []
        for option in options {
            let codecs = Set(option.mediaSubTypes.compactMap { codec(for: $0.uint32Value) })
            descriptors.append(NativeTrackDescriptor(language: option.extendedLanguageTag ?? "und",
                                                     title: await NativeMediaSelection.title(of: option), codecs: codecs,
                                                     isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                                                     isSDH: option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)))
        }
        let matched = match(descriptors, to: sources)
        return options.enumerated().map { offset, option in
            (matched[offset].map { "\(prefix)\($0)" } ?? "\(fallbackPrefix)\(offset)", option)
        }
    }

    private static func codec(for value: UInt32) -> String? {
        let bytes = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        switch String(bytes: bytes, encoding: .ascii) {
        case "mp4a", "aac ": return "aac"
        case "ac-3": return "ac3"
        case "ec-3": return "eac3"
        case "alac": return "alac"
        case "fLaC": return "flac"
        case "tx3g": return "mov_text"
        case "wvtt": return "webvtt"
        default: return nil
        }
    }
}

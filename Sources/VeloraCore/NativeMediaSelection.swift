import AVFoundation

@MainActor public enum NativeMediaSelection {
    public static func title(of option: AVMediaSelectionOption) async -> String? {
        guard let item = option.commonMetadata.first(where: { $0.commonKey == .commonKeyTitle }) else { return nil }
        return try? await item.load(.stringValue)
    }

    public static func subtitleOptions(_ sources: [SubtitleSource], in group: AVMediaSelectionGroup?) async -> [String: AVMediaSelectionOption] {
        var remaining = group?.options ?? []
        var names: [String?] = []
        for option in remaining { names.append(await title(of: option)) }
        var result: [String: AVMediaSelectionOption] = [:]
        // displayName is localized by AVFoundation and can discard NAME. The public
        // common-title metadata retains NAME, including same-language SDH variants.
        for source in sources {
            if let index = names.firstIndex(where: { $0 == source.hlsName }) {
                result[source.id] = remaining.remove(at: index); names.remove(at: index)
            }
        }
        for source in sources where result[source.id] == nil {
            let matching = remaining.indices.filter {
                MediaTrack.languageTag(remaining[$0].extendedLanguageTag ?? "und") == source.language &&
                remaining[$0].hasMediaCharacteristic(.containsOnlyForcedSubtitles) == source.isForced &&
                remaining[$0].hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) == source.isSDH
            }
            // Never guess between indistinguishable variants in the same language.
            if matching.count == 1, let index = matching.first {
                result[source.id] = remaining.remove(at: index); names.remove(at: index)
            }
        }
        return result
    }
}

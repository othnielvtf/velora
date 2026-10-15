import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let settings: String
}

/// WebVTT timestamps remain on the movie's timeline, including cues crossing a chunk boundary.
public struct SubtitleDocument: Sendable {
    public let cues: [SubtitleCue]

    public init(webVTT: String) throws {
        let text = webVTT.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard text.hasPrefix("WEBVTT"), text.utf8.count <= 16 * 1024 * 1024 else {
            throw VeloraError("The subtitle file is invalid or larger than 16 MB. Use a UTF-8 SRT, VTT or ASS file.")
        }
        var parsed: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains(" --> ") }), timingIndex <= 1 else { continue }
            let timing = lines[timingIndex].components(separatedBy: " --> ")
            let ending = timing[1].split(whereSeparator: \.isWhitespace)
            guard let endString = ending.first, let start = Self.seconds(timing[0]), let end = Self.seconds(String(endString)),
                  end > start else { throw VeloraError("A subtitle cue has invalid timing.") }
            let body = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
            if !body.isEmpty {
                parsed.append(SubtitleCue(start: start, end: end, text: body,
                                          settings: ending.dropFirst().joined(separator: " ")))
            }
            guard parsed.count <= 100_000 else { throw VeloraError("This subtitle track contains too many cues.") }
        }
        cues = parsed.sorted { $0.start < $1.start }
    }

    public func segment(start: Double, duration: Double) -> String {
        var result = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0\n\n"
        for cue in cues {
            if cue.start >= start + duration { break }
            guard cue.end > start else { continue }
            result += "\(Self.timestamp(cue.start)) --> \(Self.timestamp(cue.end))\(cue.settings.isEmpty ? "" : " " + cue.settings)\n\(cue.text)\n\n"
        }
        return result
    }

    static func seconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!), seconds.isFinite, (0..<60).contains(seconds),
              let minutes = Int(parts[parts.count - 2]), (0..<60).contains(minutes) else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, (0...9999).contains(hours) else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", total / 3_600_000, total / 60_000 % 60,
                      total / 1000 % 60, total % 1000)
    }
}

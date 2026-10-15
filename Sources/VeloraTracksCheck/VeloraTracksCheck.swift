import Foundation
import AVFoundation
import Darwin
import VeloraCore

private final class CaptionCapture: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var activeText = ""
    private var firstTimes: [String: Double] = [:]
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        lock.lock()
        activeText = strings.map(\.string).joined(separator: "\n")
        for string in strings.map(\.string) {
            text += string
            if firstTimes[string] == nil { firstTimes[string] = itemTime.seconds }
        }
        lock.unlock()
    }
    func contains(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; return text.contains(value) }
    func clear() { lock.lock(); text = ""; activeText = ""; firstTimes = [:]; lock.unlock() }
    func isDisplaying(_ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return activeText.contains(value)
    }
    func firstTime(containing value: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return firstTimes.filter { $0.key.contains(value) }.map(\.value).min()
    }
}

/// Run with the generated two-tone fixture from scripts/verify-tracks.sh.
@main struct VeloraTracksCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        func argument(_ name: String) throws -> String {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
                throw VeloraError("Use scripts/verify-tracks.sh, or pass --tools and --input with the two-tone subtitle fixture.")
            }
            return CommandLine.arguments[index + 1]
        }
        let tools = MediaTools(directory: URL(fileURLWithPath: try argument("--tools")))
        let runner = MediaProcessRunner()
        let info = try MediaInfo.inspect(URL(fileURLWithPath: try argument("--input")), tools: tools, runner: runner)
        guard info.audioTracks.count >= 2, info.subtitleTracks.filter(\.supportsTextSubtitles).count >= 2 else {
            throw VeloraError("Expected the generated fixture with two audio and at least two text subtitle tracks.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraTracksCheck-\(UUID())")
        let first = try TranscodeSession(media: info, quality: .hd, tools: tools, audioTrackIndex: info.audioTracks[0].index, cacheRoot: root)
        let second = try TranscodeSession(media: info, quality: .hd, tools: tools, audioTrackIndex: info.audioTracks[1].index, cacheRoot: root)
        let server = StreamHTTPServer(session: second)
        do {
            let firstSegment = try await first.segment(0)
            let secondSegment = try await second.segment(0)
            func frequency(_ url: URL) throws -> Double {
                let pcm = try runner.run(tools.executable("ffmpeg"), arguments: ["-v", "error", "-i", url.path, "-map", "0:a:0", "-t", "0.75", "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"])
                let samples = stride(from: 0, to: pcm.count - 1, by: 2).map { Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8) }
                // Exclude AAC encoder priming and the decode window's trailing padding.
                let steady = samples.dropFirst(4_800).dropLast(4_800)
                guard steady.count > 10_000 else { throw VeloraError("The audio sample was too short") }
                let crossings = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
                return Double(crossings) * 48_000 / Double(steady.count)
            }
            let frequencies = try [frequency(firstSegment), frequency(secondSegment)]
            guard abs(frequencies[0] - 440) < 15, abs(frequencies[1] - 880) < 15 else {
                throw VeloraError("Wrong audio track was encoded: \(frequencies)")
            }
            print("Audio: exact stream indexes produced \(frequencies) Hz")
            let port = try await server.start()
            let masterURL = server.url(host: "127.0.0.1", port: port)
            let base = masterURL.deletingLastPathComponent()
            let source = second.subtitles[0]
            let subtitleBase = base.appendingPathComponent("subtitles/\(source.id)")
            let (playlist, _) = try await URLSession.shared.data(from: subtitleBase.appendingPathComponent("index.m3u8"))
            guard String(decoding: playlist, as: UTF8.self).contains("#EXT-X-ENDLIST") else { throw VeloraError("Subtitle VOD playlist is incomplete") }
            async let a = URLSession.shared.data(from: subtitleBase.appendingPathComponent("segment-1.vtt"))
            async let b = URLSession.shared.data(from: subtitleBase.appendingPathComponent("segment-1.vtt"))
            let ((one, _), (two, _)) = try await (a, b)
            guard one == two, String(decoding: one, as: UTF8.self).contains("English subtitles are on.") else {
                throw VeloraError("Concurrent subtitle extraction or cross-boundary cue failed")
            }
            let (_, invalid) = try await URLSession.shared.data(from: base.appendingPathComponent("subtitles/unknown/segment-0.vtt"))
            guard (invalid as? HTTPURLResponse)?.statusCode == 404 else { throw VeloraError("Subtitle path isolation failed") }
            let item = AVPlayerItem(url: masterURL)
            let capture = CaptionCapture(), output = AVPlayerItemLegibleOutput()
            output.setDelegate(capture, queue: .main); item.add(output)
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = false
            player.isMuted = true
            let deadline = Date().addingTimeInterval(30)
            while item.status == .unknown && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard item.status == .readyToPlay, let group = try await item.asset.loadMediaSelectionGroup(for: .legible) else {
                throw VeloraError("AVPlayer did not expose the HLS subtitle group: \(item.error?.localizedDescription ?? "unknown")")
            }
            print("Native subtitles: \(group.options.map(\.displayName))")
            let mapped = await NativeMediaSelection.subtitleOptions(second.subtitles, in: group)
            guard mapped.count == second.subtitles.count,
                  let english = mapped[second.subtitles[0].id], let japanese = mapped[second.subtitles[1].id] else {
                throw VeloraError("HLS subtitle identity was not preserved")
            }
            item.select(english, in: group); player.play()
            try await wait { capture.contains("English subtitles are on.") }
            let captions = [(0.5, 5.5, "English subtitles are on."),
                            (8.0, 9.0, "Seek to any scene."),
                            (12.0, 13.0, "Your audio and subtitles, your choice."),
                            (23.0, 25.0, "Ending line.")]
            for (start, checkpoint, line) in captions {
                try await wait { player.currentTime().seconds >= checkpoint }
                guard capture.isDisplaying(line), let actual = capture.firstTime(containing: line), abs(actual - start) < 0.15 else {
                    throw VeloraError("Continuous subtitle timing failed at \(checkpoint)s: expected \(line) at \(start)s, got \(capture.firstTime(containing: line) ?? -1)s")
                }
                print("Continuous caption at \(actual)s, still visible at \(checkpoint)s: \(line)")
                guard item.currentMediaSelection.selectedMediaOption(in: group) == english else {
                    throw VeloraError("Subtitle selection was lost during continuous playback")
                }
            }
            let laterSegment = try await second.segment(6)
            let timing = try runner.run(tools.executable("ffprobe"), arguments: [
                "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=start_time", "-of", "json", laterSegment.path
            ])
            let streamTiming = try JSONSerialization.jsonObject(with: timing) as? [String: Any]
            let startTime = (streamTiming?["streams"] as? [[String: Any]])?.first?["start_time"] as? String
            guard let startTime, let pts = Double(startTime), abs(pts - 24) < 0.04 else {
                throw VeloraError("The video transport clock reset at a chunk boundary")
            }
            capture.clear(); player.pause()
            item.select(japanese, in: group)
            guard await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) else { throw VeloraError("Subtitle seek failed") }
            player.play()
            try await wait { capture.contains("日本語") }
            capture.clear(); player.pause()
            guard await player.seek(to: CMTime(seconds: 17, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) else { throw VeloraError("Distant subtitle seek failed") }
            player.play()
            try await wait { capture.contains("音声と字幕") }
            item.select(nil, in: group)
            guard item.currentMediaSelection.selectedMediaOption(in: group) == nil else { throw VeloraError("Subtitles Off failed") }
            player.pause(); player.replaceCurrentItem(with: nil)
            let externalFiles = [
                ("srt", "1\n00:00:00,500 --> 00:00:08,000\nExternal SRT captions.\n"),
                ("vtt", "WEBVTT\n\n00:00:00.500 --> 00:00:08.000\nExternal VTT captions.\n"),
                ("ass", "[Script Info]\nScriptType: v4.00+\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.50,0:00:08.00,Default,,0,0,0,,External ASS captions.\n")
            ]
            for (extensionName, text) in externalFiles {
                let file = root.appendingPathComponent("External.\(extensionName)")
                try text.write(to: file, atomically: true, encoding: .utf8)
                let external = try TranscodeSession(media: info, quality: .hd, tools: tools, externalSubtitle: file, cacheRoot: root)
                do {
                    let vtt = try await external.subtitleSegment(trackID: "external", index: 1)
                    guard String(decoding: vtt, as: UTF8.self).contains("External \(extensionName.uppercased()) captions.") else {
                        throw VeloraError("External \(extensionName) conversion failed")
                    }
                    await external.stop()
                } catch { await external.stop(); throw error }
            }
            if CommandLine.arguments.contains("--original") {
                try await checkOriginal(URL(fileURLWithPath: argument("--original")))
            }
            server.stop(); await first.stop(); await second.stop()
            try? FileManager.default.removeItem(at: root)
            print("PASS: selected audio, native captions, language switching, subtitle seek, Off, external SRT/VTT/ASS, and HTTP isolation")
        } catch {
            server.stop(); await first.stop(); await second.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @MainActor private static func checkOriginal(_ url: URL) async throws {
        let item = AVPlayerItem(url: url), capture = CaptionCapture(), output = AVPlayerItemLegibleOutput()
        output.setDelegate(capture, queue: .main); item.add(output)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.isMuted = true
        let limit = Date().addingTimeInterval(20)
        while item.status == .unknown && Date() < limit { try await Task.sleep(for: .milliseconds(100)) }
        guard item.status == .readyToPlay,
              let audio = try await item.asset.loadMediaSelectionGroup(for: .audible), audio.options.count >= 2,
              let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible), subtitles.options.count >= 2 else {
            throw VeloraError("Original MP4 did not expose audio and subtitle groups")
        }
        item.select(audio.options[1], in: audio)
        guard item.currentMediaSelection.selectedMediaOption(in: audio) == audio.options[1] else { throw VeloraError("Original audio switching failed") }
        guard let english = subtitles.options.first(where: { MediaTrack.languageTag($0.extendedLanguageTag ?? "") == "en" }),
              let japanese = subtitles.options.first(where: { MediaTrack.languageTag($0.extendedLanguageTag ?? "") == "ja" }) else { throw VeloraError("Original subtitle languages missing") }
        item.select(english, in: subtitles); player.play()
        try await wait { capture.contains("English subtitles are on.") }
        capture.clear(); player.pause(); item.select(japanese, in: subtitles)
        _ = await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); try await wait { capture.contains("日本語") }
        item.select(nil, in: subtitles); player.pause(); player.replaceCurrentItem(with: nil)
        print("Original MP4: native audio and subtitle switching passed")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let limit = Date().addingTimeInterval(20)
        while !condition(), Date() < limit { try await Task.sleep(for: .milliseconds(100)) }
        guard condition() else { throw VeloraError("AVPlayer did not deliver the expected subtitle text") }
    }
}

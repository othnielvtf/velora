import Foundation
import AVFoundation
import VeloraCore

@main
struct VeloraCheck {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        func argument(_ name: String) throws -> String {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                throw VeloraError("Usage: VeloraCheck --tools /path/to/Tools --input /path/to/video [--report /path/to/report.json]")
            }
            return arguments[index + 1]
        }
        let tools = MediaTools(directory: URL(fileURLWithPath: try argument("--tools")))
        let input = URL(fileURLWithPath: try argument("--input"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VeloraCheck-\(UUID())")
        let runner = MediaProcessRunner()
        let info = try await Task.detached { try MediaInfo.inspect(input, tools: tools, runner: runner) }.value
        let session = try TranscodeSession(media: info, quality: .fullHD, tools: tools, cacheRoot: root)
        let server = StreamHTTPServer(session: session)
        let port = try await server.start()
        let url = server.url(host: "127.0.0.1", port: port)
        var report: [String: Any] = ["inputCodec": info.videoCodec, "duration": info.duration, "hdr": info.isHDR]
        print("Source: \(info.codecLabel) \(info.width)×\(info.height), \(info.duration)s")
        do {
            let (master, masterResponse) = try await URLSession.shared.data(from: url)
            guard (masterResponse as? HTTPURLResponse)?.statusCode == 200,
                  String(decoding: master, as: UTF8.self).contains("avc1.640029") else { throw VeloraError("Master playlist check failed") }
            let videoURL = url.deletingLastPathComponent().appendingPathComponent("video.m3u8")
            let (playlist, _) = try await URLSession.shared.data(from: videoURL)
            guard String(decoding: playlist, as: UTF8.self).contains("#EXT-X-ENDLIST") else { throw VeloraError("Full VOD timeline is missing") }
            let segmentURL = url.deletingLastPathComponent().appendingPathComponent("segment-0.ts")
            let begin = Date()
            async let first = URLSession.shared.data(from: segmentURL)
            async let same = URLSession.shared.data(from: segmentURL)
            let ((chunk, response), (duplicate, _)) = try await (first, same)
            guard (response as? HTTPURLResponse)?.statusCode == 200, chunk == duplicate, chunk.count > 188 else { throw VeloraError("Coalesced chunk conversion failed") }
            report["firstChunkSeconds"] = Date().timeIntervalSince(begin)
            let chunkFile = root.appendingPathComponent("first.ts"); try chunk.write(to: chunkFile)
            let probe = try await Task.detached {
                try runner.run(tools.executable("ffprobe"), arguments: ["-v", "error", "-show_streams", "-of", "json", chunkFile.path])
            }.value
            let json = try JSONSerialization.jsonObject(with: probe) as? [String: Any]
            let streams = json?["streams"] as? [[String: Any]] ?? []
            guard streams.contains(where: { $0["codec_name"] as? String == "h264" }),
                  info.audioCodec == nil || streams.contains(where: { $0["codec_name"] as? String == "aac" }) else { throw VeloraError("Output codecs are incorrect") }
            var rangeRequest = URLRequest(url: segmentURL); rangeRequest.setValue("bytes=0-187", forHTTPHeaderField: "Range")
            let (ranged, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
            guard ranged == chunk.prefix(188), (rangeResponse as? HTTPURLResponse)?.statusCode == 206 else { throw VeloraError("Byte range handling failed") }
            var headRequest = URLRequest(url: segmentURL); headRequest.httpMethod = "HEAD"
            let (head, headResponse) = try await URLSession.shared.data(for: headRequest)
            guard head.isEmpty, (headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "\(chunk.count)" else { throw VeloraError("HEAD handling failed") }
            rangeRequest.setValue("bytes=999999999-", forHTTPHeaderField: "Range")
            let (_, invalidRange) = try await URLSession.shared.data(for: rangeRequest)
            guard (invalidRange as? HTTPURLResponse)?.statusCode == 416 else { throw VeloraError("Invalid byte range was accepted") }
            let (_, badToken) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/wrong/master.m3u8")!)
            guard (badToken as? HTTPURLResponse)?.statusCode == 404 else { throw VeloraError("Token isolation failed") }
            print("HTTP: manifests, concurrent chunk requests, byte ranges, HEAD and token isolation passed")

            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 4
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = false
            player.isMuted = true
            let ready = Date()
            while item.status == .unknown && Date().timeIntervalSince(ready) < 30 { try await Task.sleep(for: .milliseconds(100)) }
            guard item.status == .readyToPlay else { throw VeloraError("AVPlayer did not load HLS: \(item.error?.localizedDescription ?? "timeout")") }
            report["avPlayerReadySeconds"] = Date().timeIntervalSince(ready)
            report["avPlayerDuration"] = item.duration.seconds
            guard abs(item.duration.seconds - info.duration) < 0.1 else { throw VeloraError("AVPlayer does not expose the complete seekable duration") }
            player.play()
            try await waitForPlayback(player, minimum: 1, timeout: 20)
            let seekTarget = max(0, info.duration - 8)
            let seekStart = Date()
            let sought = await player.seek(to: CMTime(seconds: seekTarget, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard sought else { throw VeloraError("Forward seek failed") }
            player.play()
            try await waitForPlayback(player, minimum: seekTarget + 0.6, timeout: 25)
            report["forwardSeekAndResumeSeconds"] = Date().timeIntervalSince(seekStart)
            let backStart = Date()
            let backTarget = min(2.0, info.duration / 4)
            guard await player.seek(to: CMTime(seconds: backTarget, preferredTimescale: 600)) else { throw VeloraError("Backward seek failed") }
            player.play()
            try await waitForPlayback(player, minimum: backTarget + 0.5, timeout: 20)
            report["backwardSeekAndResumeSeconds"] = Date().timeIntervalSince(backStart)
            player.pause()
            let currentTime = player.currentTime()
            let pixel = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil)
            report["decodedVideoFrame"] = pixel != nil
            guard pixel != nil else { throw VeloraError("Playback clock advanced but no video frame could be decoded") }
            player.replaceCurrentItem(with: nil)
            report["result"] = "PASS"
            report["airPlayReceiverTested"] = false
            server.stop(); await session.stop(); try? FileManager.default.removeItem(at: root)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if let path = try? argument("--report") { try data.write(to: URL(fileURLWithPath: path)) }
        } catch {
            server.stop(); await session.stop(); try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @MainActor private static func waitForPlayback(_ player: AVPlayer, minimum: Double, timeout: Double) async throws {
        let start = Date()
        while player.currentTime().seconds < minimum && Date().timeIntervalSince(start) < timeout {
            if player.currentItem?.status == .failed { throw player.currentItem?.error ?? VeloraError("AVPlayer failed") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard player.currentTime().seconds >= minimum else {
            throw VeloraError("Playback stalled at \(player.currentTime().seconds)s; expected \(minimum)s. \(player.currentItem?.error?.localizedDescription ?? "")")
        }
    }
}

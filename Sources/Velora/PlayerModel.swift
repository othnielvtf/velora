import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import VeloraCore

enum PlaybackMode: String, CaseIterable, Identifiable {
    case compatibility = "TV Compatibility", original = "Original"
    var id: String { rawValue }
}

struct PlaybackTrackOption: Identifiable {
    let id: String
    let label: String
}

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var mode: PlaybackMode = .compatibility
    @Published var quality: StreamQuality = .fullHD
    @Published var addresses = LANAddress.available()
    @Published var selectedAddress = ""
    @Published var media: MediaInfo?
    @Published var position: Double = 0
    @Published var isPlaying = false
    @Published var isPreparing = false
    @Published var isBuffering = false
    @Published var isSeeking = false
    @Published var isAirPlaying = false
    @Published var status = "Your next movie, beautifully connected."
    @Published var errorMessage: String?
    @Published var streamURL: URL?
    @Published var cachedIndices: [Int] = []
    @Published var cacheBytes: Int64 = 0
    @Published var conversionSpeed: Double = 0
    @Published var rate: Float = 1
    @Published var volume: Double = 1 { didSet { player.volume = Float(volume) } }
    @Published private(set) var audioOptions: [PlaybackTrackOption] = []
    @Published private(set) var subtitleOptions: [PlaybackTrackOption] = []
    @Published private(set) var selectedAudioTrackID = ""
    @Published private(set) var selectedSubtitleID = "off"
    @Published private(set) var externalSubtitle: URL?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var nativeAudio: [String: AVMediaSelectionOption] = [:]
    private var nativeSubtitles: [String: AVMediaSelectionOption] = [:]
    private var selectionObserver: NSObjectProtocol?
    private var readyItemID: UUID?
    private var pendingAutoplay = true
    private var session: TranscodeSession?
    private var server: StreamHTTPServer?
    private var probeRunner: MediaProcessRunner?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var seekID = UUID()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var pendingPosition: Double = 0
    private let tools: MediaTools
    private let cacheRoot: URL

    init() {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        tools = MediaTools(directory: resources.appendingPathComponent("Tools"))
        cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.velora.player/Sessions")
        selectedAddress = addresses.first?.address ?? ""
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlaying = player.timeControlStatus == .playing
                    self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    if self.isPlaying { self.status = self.isAirPlaying ? "Playing on your AirPlay device" : "Playing on this Mac" }
                }
            },
            player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    self?.isAirPlaying = player.isExternalPlaybackActive
                    if player.isExternalPlaybackActive { self?.status = "Playing on your AirPlay device" }
                }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.media != nil, self.player.currentItem != nil, !self.isSeeking, !self.isPreparing else { return }
                let seconds = self.player.currentTime().seconds
                guard seconds.isFinite else { return }
                self.position = max(0, seconds)
            }
        }
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in old {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) > 86_400 { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    var duration: Double { media?.duration ?? 0 }
    var cachedFraction: Double {
        guard let media else { return 0 }
        return Double(cachedIndices.count) / Double(StreamTimeline(duration: media.duration).count)
    }
    var busyText: String? {
        if isPreparing { return "Preparing your movie…" }
        if isSeeking { return "Finding your scene…" }
        if isBuffering { return "Buffering…" }
        return nil
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open a movie in Velora"
        panel.message = "Choose a video. TV Compatibility supports HEVC, MKV, MP4, MOV and more."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    func open(_ url: URL, at start: Double = 0, autoplay: Bool = true, preservingTracks: Bool = false) {
        guard url.isFileURL else { errorMessage = "Choose a local video file."; return }
        if ["srt", "vtt", "ass", "ssa"].contains(url.pathExtension.lowercased()) { loadSubtitle(url); return }
        let keptAudio = preservingTracks ? selectedAudioTrackID : ""
        let keptSubtitle = preservingTracks ? selectedSubtitleID : "off"
        let keptExternal = preservingTracks ? externalSubtitle : nil
        close()
        selectedAudioTrackID = keptAudio; selectedSubtitleID = keptSubtitle; externalSubtitle = keptExternal
        let id = UUID(); loadID = id
        let runner = MediaProcessRunner(); probeRunner = runner
        isPreparing = true; status = "Inspecting video, audio and subtitles…"; pendingPosition = start
        pendingAutoplay = autoplay
        let mode = mode, quality = quality, tools = tools, cacheRoot = cacheRoot
        addresses = LANAddress.available()
        if !addresses.contains(where: { $0.address == selectedAddress }) { selectedAddress = addresses.first?.address ?? "" }
        let host = selectedAddress.isEmpty ? "127.0.0.1" : selectedAddress
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await Task.detached {
                    try MediaInfo.inspect(url, tools: tools, runner: runner)
                }.value
                try Task.checkCancellation()
                guard self.loadID == id else { return }
                self.media = info
                self.position = min(max(0, start), info.duration)
                if mode == .compatibility {
                    let selectedAudio = info.audioTracks.first { "audio-\($0.index)" == self.selectedAudioTrackID } ?? info.defaultAudioTrack
                    self.audioOptions = info.audioTracks.map { PlaybackTrackOption(id: "audio-\($0.index)", label: "\($0.label) [\($0.ordinal + 1)]") }
                    self.selectedAudioTrackID = selectedAudio.map { "audio-\($0.index)" } ?? ""
                    self.status = info.isHDR ? "Preparing an SDR stream for your TV…" : "Preparing the first video chunk…"
                    let session = try TranscodeSession(media: info, quality: quality, tools: tools,
                                                       audioTrackIndex: selectedAudio?.index, externalSubtitle: self.externalSubtitle,
                                                       cacheRoot: cacheRoot) { [weak self] event in
                        Task { @MainActor in
                            guard let self, self.loadID == id else { return }
                            self.cachedIndices = event.cachedIndices; self.cacheBytes = event.cachedBytes
                            self.conversionSpeed = event.speed
                        }
                    }
                    self.session = session
                    self.subtitleOptions = session.subtitles.map { PlaybackTrackOption(id: $0.id, label: $0.label) }
                    if !self.subtitleOptions.contains(where: { $0.id == self.selectedSubtitleID }) { self.selectedSubtitleID = "off" }
                    let server = StreamHTTPServer(session: session) { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.loadID == id else { return }
                            self.errorMessage = message
                        }
                    }
                    self.server = server
                    let port = try await server.start()
                    let first = min(session.timeline.count - 1, max(0, Int(start / session.timeline.segmentDuration)))
                    _ = try await session.segment(first)
                    try Task.checkCancellation()
                    guard self.loadID == id else { return }
                    let streamURL = server.url(host: host, port: port)
                    self.streamURL = streamURL
                    self.install(AVPlayerItem(url: streamURL), id: id)
                } else {
                    let asset = AVURLAsset(url: url)
                    guard try await asset.load(.isPlayable) else {
                        throw VeloraError("macOS cannot play this file directly. Select TV Compatibility to prepare a supported stream.")
                    }
                    try Task.checkCancellation()
                    guard self.loadID == id else { return }
                    self.install(AVPlayerItem(asset: asset), id: id)
                }
            } catch is CancellationError { }
            catch {
                guard self.loadID == id else { return }
                self.isPreparing = false; self.status = "Couldn’t open this movie"
                self.errorMessage = error.localizedDescription
                self.server?.stop(); self.session?.cancelProcesses()
                if let session = self.session { Task { await session.stop() } }
            }
        }
    }

    private func install(_ item: AVPlayerItem, id: UUID) {
        item.preferredForwardBufferDuration = 16
        itemObservations = [item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.loadID == id else { return }
                switch item.status {
                case .readyToPlay:
                    guard self.readyItemID != id else { return }
                    self.readyItemID = id
                    await self.configureTracks(for: item, id: id)
                    guard self.loadID == id, self.player.currentItem === item else { return }
                    self.isPreparing = false
                    self.status = self.pendingAutoplay ? "Ready · choose an AirPlay TV or watch here" : "Paused"
                    if self.pendingPosition > 0 {
                        let target = self.pendingPosition; self.pendingPosition = 0
                        self.seek(target, autoplay: self.pendingAutoplay)
                    } else if self.pendingAutoplay { self.player.playImmediately(atRate: self.rate) }
                case .failed:
                    self.isPreparing = false; self.isBuffering = false
                    self.errorMessage = item.error?.localizedDescription ?? "The video stream could not be played."
                default: break
                }
            }
        }]
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.status = "That’s a wrap."; self?.isPlaying = false }
        }
        player.replaceCurrentItem(with: item)
    }

    func reload() {
        guard let url = media?.source else { return }
        open(url, at: position, autoplay: player.rate > 0 || isBuffering, preservingTracks: true)
    }

    func setMode(_ value: PlaybackMode) {
        guard mode != value else { return }
        mode = value; reload()
    }

    private func configureTracks(for item: AVPlayerItem, id: UUID) async {
        async let audible = try? item.asset.loadMediaSelectionGroup(for: .audible)
        async let legible = try? item.asset.loadMediaSelectionGroup(for: .legible)
        let (audio, subtitles) = await (audible, legible)
        guard loadID == id, player.currentItem === item else { return }
        audioGroup = audio; subtitleGroup = subtitles
        if mode == .original {
            let options = audio?.options ?? []
            audioOptions = options.enumerated().map { PlaybackTrackOption(id: "native-audio-\($0.offset)", label: "\($0.element.displayName) [\($0.offset + 1)]") }
            nativeAudio = Dictionary(uniqueKeysWithValues: zip(audioOptions.map(\.id), options))
            if nativeAudio[selectedAudioTrackID] == nil {
                let current = audio.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
                selectedAudioTrackID = audioOptions.first { nativeAudio[$0.id] == current }?.id ?? audioOptions.first?.id ?? ""
            }
            if let audio, let selected = nativeAudio[selectedAudioTrackID] { item.select(selected, in: audio) }
            let legibleOptions = subtitles?.options ?? []
            subtitleOptions = legibleOptions.enumerated().map { PlaybackTrackOption(id: "native-subtitle-\($0.offset)", label: "\($0.element.displayName) [\($0.offset + 1)]") }
            nativeSubtitles = Dictionary(uniqueKeysWithValues: zip(subtitleOptions.map(\.id), legibleOptions))
        } else {
            let mapped = await NativeMediaSelection.subtitleOptions(session?.subtitles ?? [], in: subtitles)
            guard loadID == id, player.currentItem === item else { return }
            nativeSubtitles = mapped
        }
        if nativeSubtitles[selectedSubtitleID] == nil { selectedSubtitleID = "off" }
        if let subtitles { item.select(nativeSubtitles[selectedSubtitleID], in: subtitles) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.loadID == id else { return }
                if let group = self.subtitleGroup {
                    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                    self.selectedSubtitleID = selected == nil ? "off" : (self.subtitleOptions.first { self.nativeSubtitles[$0.id] == selected }?.id ?? "off")
                }
                if self.mode == .original, let group = self.audioGroup {
                    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                    self.selectedAudioTrackID = self.audioOptions.first { self.nativeAudio[$0.id] == selected }?.id ?? ""
                }
            }
        }
    }

    func selectAudio(_ id: String) {
        guard !isPreparing, selectedAudioTrackID != id, audioOptions.contains(where: { $0.id == id }) else { return }
        selectedAudioTrackID = id
        if mode == .original, let group = audioGroup, let option = nativeAudio[id] {
            player.currentItem?.select(option, in: group)
        } else { reload() }
    }

    func selectSubtitle(_ id: String) {
        guard !isPreparing, let item = player.currentItem, let group = subtitleGroup else { return }
        guard id == "off" || nativeSubtitles[id] != nil else {
            errorMessage = "macOS could not select this subtitle track. Try loading an external SRT or VTT file."
            return
        }
        selectedSubtitleID = id
        if errorMessage?.hasPrefix("Subtitles:") == true { errorMessage = nil }
        item.select(id == "off" ? nil : nativeSubtitles[id], in: group)
    }

    func loadSubtitlePanel() {
        guard media != nil, !isPreparing else { return }
        let panel = NSOpenPanel()
        panel.title = "Load Subtitles"
        panel.message = "Choose an SRT, VTT, ASS or SSA file. External subtitles use TV Compatibility mode."
        panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.loadSubtitle(url)
            }
        }
    }

    func loadSubtitle(_ url: URL) {
        guard media != nil else { errorMessage = "Open a movie before loading subtitles."; return }
        guard !isPreparing, url.isFileURL else { return }
        externalSubtitle = url; selectedSubtitleID = "external"
        mode = .compatibility; reload()
    }

    func removeExternalSubtitle() {
        guard externalSubtitle != nil else { return }
        externalSubtitle = nil
        if selectedSubtitleID == "external" { selectedSubtitleID = "off" }
        reload()
    }

    func togglePlayback() {
        guard media != nil, !isPreparing else { return }
        if player.rate != 0 { player.pause(); status = "Paused" }
        else if position >= duration - 0.2 { seek(0, autoplay: true) }
        else { player.playImmediately(atRate: rate) }
    }

    func seek(_ seconds: Double, autoplay: Bool? = nil) {
        guard media != nil, !isPreparing else { return }
        let target = max(0, min(seconds, max(0, duration - 0.05)))
        let resume = autoplay ?? (player.rate > 0 || isBuffering)
        let id = UUID(); seekID = id
        position = target; isSeeking = true
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekID == id else { return }
                self.isSeeking = false
                if finished && resume { self.player.playImmediately(atRate: self.rate) }
            }
        }
    }

    func setRate(_ value: Float) { rate = value; if player.rate > 0 { player.rate = value } }
    func skip(_ seconds: Double) { seek(position + seconds) }

    func close() {
        loadID = UUID(); seekID = UUID()
        loadTask?.cancel(); loadTask = nil; probeRunner?.stop(); probeRunner = nil
        player.pause(); itemObservations.removeAll(); player.replaceCurrentItem(with: nil)
        server?.stop(); server = nil
        if let session { session.cancelProcesses(); Task { await session.stop() } }
        session = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil; readyItemID = nil
        audioGroup = nil; subtitleGroup = nil; nativeAudio = [:]; nativeSubtitles = [:]
        audioOptions = []; subtitleOptions = []; selectedAudioTrackID = ""; selectedSubtitleID = "off"; externalSubtitle = nil
        media = nil; position = 0; streamURL = nil; errorMessage = nil
        cachedIndices = []; cacheBytes = 0; conversionSpeed = 0
        isPreparing = false; isBuffering = false; isSeeking = false; isPlaying = false
        status = "Your next movie, beautifully connected."
    }

    func copyDiagnostics() {
        let text = """
        Velora 0.2 · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Mode: \(mode.rawValue) · Quality: \(quality.description)
        Source: \(media?.source.lastPathComponent ?? "None")
        Video: \(media?.codecLabel ?? "—") \(media?.width ?? 0)×\(media?.height ?? 0) · Audio: \(media?.audioCodec ?? "None")
        HDR source: \(media?.isHDR == true) · AirPlay active: \(isAirPlaying)
        Audio selection: \(selectedAudioTrackID) · Subtitles: \(selectedSubtitleID)
        Audio tracks: \(audioOptions.count) · Subtitle tracks: \(subtitleOptions.count)
        Position: \(position) / \(duration)
        Network: \(selectedAddress) · Server: \(streamURL == nil ? "Inactive" : "Running")
        Cached chunks: \(cachedIndices.count) · Last conversion: \(String(format: "%.2f", conversionSpeed))×
        Status: \(status)
        Error: \(errorMessage ?? "None")
        """
        // The access-token URL is deliberately omitted from copied diagnostics.
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

func timeLabel(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
                         : String(format: "%02d:%02d", total / 60, total % 60)
}

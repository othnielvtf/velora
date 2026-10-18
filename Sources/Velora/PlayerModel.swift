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
    var isPlayable = true
}

@MainActor
final class PlayerModel: ObservableObject {
    let player: AVPlayer
    @Published private(set) var mode: PlaybackMode = .compatibility
    @Published var quality: StreamQuality = .fullHD {
        didSet { if quality != oldValue, mode == .compatibility { reload() } }
    }
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
    private var observedAudioSelection = NativeSelectionState()
    private var observedSubtitleSelection = NativeSelectionState()
    private var selectionObserver: NSObjectProtocol?
    private var readyItemID: UUID?
    private var pendingAutoplay = true
    private var wantsToPlay = false
    private var retainedAudioPropertyList: Any?
    private var retainedSubtitlePropertyList: Any?
    private var audioSelectionUnavailable = false
    private var subtitleSelectionUnavailable = false
    private var nativeItemIsOriginal = false
    private var nativeTimelineOrigin: Double = 0
    private var session: TranscodeSession?
    private var server: StreamHTTPServer?
    private var probeRunner: MediaProcessRunner?
    private var loadTask: Task<Void, Never>?
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var loadID = UUID()
    private var seekID = UUID()
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var pendingPosition: Double = 0
    private let tools: MediaTools
    private let cacheRoot: URL

    init(player: AVPlayer = AVPlayer(), tools: MediaTools? = nil, cacheRoot: URL? = nil) {
        self.player = player
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        self.tools = tools ?? MediaTools(directory: resources.appendingPathComponent("Tools"))
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.velora.player/Sessions")
        let cacheRoot = self.cacheRoot
        selectedAddress = addresses.first?.address ?? ""
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self, !self.isShuttingDown else { return }
                    self.updateNativePlaybackState()
                }
            },
            player.observe(\.rate, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self, !self.isShuttingDown else { return }
                    // Native controls and AirPlay may change rate while an item
                    // is waiting for media, before it reports .playing.
                    if self.audioSelectionUnavailable || self.subtitleSelectionUnavailable {
                        self.updateNativePlaybackState()
                    }
                }
            },
            player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self, !self.isShuttingDown else { return }
                    self.isAirPlaying = player.isExternalPlaybackActive
                    if player.isExternalPlaybackActive { self.status = "Playing on your AirPlay device" }
                }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.media != nil, self.player.currentItem != nil, !self.isSeeking, !self.isPreparing else { return }
                let seconds = self.player.currentTime().seconds
                guard seconds.isFinite else { return }
                self.position = max(0, min(self.duration, seconds - self.nativeTimelineOrigin))
            }
        }
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in old where url.lastPathComponent != "Subtitles" {
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
        guard !isShuttingDown else { return }
        guard url.isFileURL else { errorMessage = "Choose a local video file."; return }
        if ["srt", "vtt", "ass", "ssa"].contains(url.pathExtension.lowercased()) { loadSubtitle(url); return }
        let keptAudio = preservingTracks ? selectedAudioTrackID : ""
        let keptSubtitle = preservingTracks ? selectedSubtitleID : "off"
        let keptExternal = preservingTracks ? externalSubtitle : nil
        let keptAudioPropertyList = preservingTracks && nativeItemIsOriginal ? nativeAudio[selectedAudioTrackID]?.propertyList() : nil
        let keptSubtitlePropertyList = preservingTracks && nativeItemIsOriginal ? nativeSubtitles[selectedSubtitleID]?.propertyList() : nil
        close()
        selectedAudioTrackID = keptAudio; selectedSubtitleID = keptSubtitle; externalSubtitle = keptExternal
        retainedAudioPropertyList = keptAudioPropertyList; retainedSubtitlePropertyList = keptSubtitlePropertyList
        let id = UUID(); loadID = id
        let runner = MediaProcessRunner(); probeRunner = runner
        isPreparing = true; status = "Inspecting video, audio and subtitles…"; pendingPosition = start
        pendingAutoplay = autoplay
        wantsToPlay = autoplay
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
                                                       cacheRoot: cacheRoot, onSubtitlePreparation: { [weak self] preparing in
                        Task { @MainActor in
                            guard let self, self.loadID == id else { return }
                            if preparing { self.status = "Preparing subtitles…" }
                            else if self.status == "Preparing subtitles…" {
                                self.status = self.isPlaying ? (self.isAirPlaying ? "Playing on your AirPlay device" : "Playing on this Mac") : "Paused"
                            }
                        }
                    }) { [weak self] event in
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
                self.wantsToPlay = false
                self.isPreparing = false; self.status = "Couldn’t open this movie"
                self.errorMessage = error.localizedDescription
                self.server?.stop(); self.server = nil
                self.session?.cancelProcesses()
                if let session = self.session { self.retainCleanup(session: session) }
                self.session = nil
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
                    let tracksAvailable = !self.audioSelectionUnavailable && !self.subtitleSelectionUnavailable
                    let autoplay = self.pendingAutoplay && tracksAvailable
                    self.wantsToPlay = autoplay
                    if !tracksAvailable {
                        self.status = "Choose an available audio or subtitle track"
                    } else { self.status = autoplay ? "Ready · choose an AirPlay TV or watch here" : "Paused" }
                    if self.pendingPosition > 0 || self.nativeTimelineOrigin > 0 {
                        let target = self.pendingPosition; self.pendingPosition = 0
                        self.seek(target, autoplay: autoplay)
                    } else if autoplay { self.player.playImmediately(atRate: self.rate) }
                case .failed:
                    self.wantsToPlay = false
                    self.isPreparing = false; self.isBuffering = false
                    self.errorMessage = item.error?.localizedDescription ?? "The video stream could not be played."
                default: break
                }
            }
        }]
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.loadID == id else { return }
                self.status = "That’s a wrap."; self.isPlaying = false; self.wantsToPlay = false
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func reload() {
        guard let url = media?.source else { return }
        open(url, at: position, autoplay: wantsToPlay, preservingTracks: true)
    }

    func setMode(_ value: PlaybackMode) {
        guard mode != value else { return }
        guard canPreserveTracks(in: value) else { return }
        mode = value; reload()
    }

    private func canPreserveTracks(in destination: PlaybackMode, replacingSubtitles: Bool = false) -> Bool {
        if destination == .original, selectedSubtitleID == "external" {
            errorMessage = "Tracks: external subtitles require TV Compatibility. Turn subtitles Off before switching to Original."
            return false
        }
        guard destination == .compatibility, mode == .original else { return true }
        if selectedAudioTrackID.hasPrefix("native-") || (!replacingSubtitles && selectedSubtitleID.hasPrefix("native-")) {
            errorMessage = "Tracks: macOS did not expose enough metadata to identify the selected track in TV Compatibility. Choose another audio track or turn subtitles Off before switching."
            return false
        }
        if !replacingSubtitles, selectedSubtitleID.hasPrefix("embedded-"),
           let track = media?.subtitleTracks.first(where: { "embedded-\($0.index)" == selectedSubtitleID }),
           !track.supportsTextSubtitles {
            errorMessage = "Tracks: the selected image subtitles need an external text subtitle file in TV Compatibility. Turn subtitles Off or load an external file before switching."
            return false
        }
        return true
    }

    private func configureTracks(for item: AVPlayerItem, id: UUID) async {
        async let audible = try? item.asset.loadMediaSelectionGroup(for: .audible)
        async let legible = try? item.asset.loadMediaSelectionGroup(for: .legible)
        let (audio, subtitles) = await (audible, legible)
        guard loadID == id, player.currentItem === item else { return }
        audioGroup = audio; subtitleGroup = subtitles
        nativeItemIsOriginal = mode == .original
        if mode == .original {
            let origin = await originalTimelineOrigin(in: item.asset)
            guard loadID == id, player.currentItem === item else { return }
            nativeTimelineOrigin = origin
            // Native items can include an empty leading edit or an audio-only
            // tail. Both playback modes expose the same video-frame clock.
            item.forwardPlaybackEndTime = CMTime(seconds: origin + duration, preferredTimescale: 600)
            let options = audio?.options ?? []
            let mappedAudio = await NativeTrackIdentity.options(options, sources: media?.audioTracks ?? [], prefix: "audio-", fallbackPrefix: "native-audio-")
            let mappedSubtitles = await NativeTrackIdentity.options(subtitles?.options ?? [], sources: media?.subtitleTracks ?? [], prefix: "embedded-", fallbackPrefix: "native-subtitle-")
            guard loadID == id, player.currentItem === item else { return }
            audioOptions = nativeOptions(mappedAudio, sources: media?.audioTracks ?? [], prefix: "audio-")
            nativeAudio = Dictionary(uniqueKeysWithValues: mappedAudio.map { ($0.id, $0.option) })
            if nativeAudio[selectedAudioTrackID] == nil, let propertyList = retainedAudioPropertyList,
               let restored = audio?.mediaSelectionOption(withPropertyList: propertyList) {
                selectedAudioTrackID = mappedAudio.first(where: { $0.option == restored })?.id ?? selectedAudioTrackID
            }
            if selectedAudioTrackID.isEmpty {
                let current = audio.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
                if let source = media?.defaultAudioTrack {
                    selectedAudioTrackID = "audio-\(source.index)"
                } else {
                    selectedAudioTrackID = mappedAudio.first { $0.option == current }?.id ?? mappedAudio.first?.id ?? ""
                }
            }
            audioSelectionUnavailable = !selectedAudioTrackID.isEmpty && nativeAudio[selectedAudioTrackID]?.isPlayable != true
            subtitleOptions = nativeOptions(mappedSubtitles, sources: media?.subtitleTracks ?? [], prefix: "embedded-")
            nativeSubtitles = Dictionary(uniqueKeysWithValues: mappedSubtitles.map { ($0.id, $0.option) })
            if nativeSubtitles[selectedSubtitleID] == nil, let propertyList = retainedSubtitlePropertyList,
               let restored = subtitles?.mediaSelectionOption(withPropertyList: propertyList) {
                selectedSubtitleID = mappedSubtitles.first(where: { $0.option == restored })?.id ?? selectedSubtitleID
            }
        } else {
            let mapped = await NativeMediaSelection.subtitleOptions(session?.subtitles ?? [], in: subtitles)
            guard loadID == id, player.currentItem === item else { return }
            nativeSubtitles = mapped
        }
        subtitleSelectionUnavailable = selectedSubtitleID != "off" && nativeSubtitles[selectedSubtitleID]?.isPlayable != true
        observedAudioSelection = NativeSelectionState(option: audio.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) })
        observedSubtitleSelection = NativeSelectionState(option: subtitles.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) })
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self, weak item] _ in
            // The observer is delivered on .main. Process its current selection
            // synchronously so an older queued Task cannot replace newer intent.
            MainActor.assumeIsolated {
                guard let self, let item, self.loadID == id, self.player.currentItem === item else { return }
                self.reconcileNativeSelections(in: item)
            }
        }
        if mode == .original, let audio, let selected = nativeAudio[selectedAudioTrackID], selected.isPlayable {
            selectNative(selected, in: audio, item: item, isAudio: true)
        }
        if let subtitles {
            selectNative(subtitleSelectionUnavailable ? nil : nativeSubtitles[selectedSubtitleID], in: subtitles,
                         item: item, isAudio: false)
        }
        updateTrackSelectionError()
    }

    private func originalTimelineOrigin(in asset: AVAsset) async -> Double {
        guard let video = try? await asset.loadTracks(withMediaType: .video).first else { return 0 }
        if let segments = try? await video.load(.segments),
           let start = segments.filter({ !$0.isEmpty }).map({ $0.timeMapping.target.start.seconds })
            .filter(\.isFinite).min() {
            return max(0, start)
        }
        let start = (try? await video.load(.timeRange))?.start.seconds ?? 0
        return start.isFinite ? max(0, start) : 0
    }

    private func reconcileNativeSelections(in item: AVPlayerItem) {
        if let group = subtitleGroup {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            if observedSubtitleSelection.observe(selected) {
                selectedSubtitleID = selected == nil ? "off" : (subtitleOptions.first { nativeSubtitles[$0.id] == selected }?.id ?? "off")
                subtitleSelectionUnavailable = selected?.isPlayable == false
            }
        }
        if mode == .original, let group = audioGroup {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            if observedAudioSelection.observe(selected) {
                if let selected {
                    selectedAudioTrackID = audioOptions.first { nativeAudio[$0.id] == selected }?.id ?? selectedAudioTrackID
                    audioSelectionUnavailable = !selected.isPlayable
                } else { audioSelectionUnavailable = !selectedAudioTrackID.isEmpty }
            }
        }
        updateTrackSelectionError()
    }

    private func selectNative(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup,
                              item: AVPlayerItem, isAudio: Bool) {
        let current = item.currentMediaSelection.selectedMediaOption(in: group)
        let shouldSelect = isAudio ? observedAudioSelection.request(option, current: current)
                                  : observedSubtitleSelection.request(option, current: current)
        if shouldSelect { item.select(option, in: group) }
    }

    /// Published track IDs represent the user's request, which can be unavailable
    /// even while AVFoundation retains a different playable option. Ignore both
    /// unchanged notifications and acknowledgements of our older selection calls;
    /// an actual external change is a new request, including while playback is blocked.
    private struct NativeSelectionState {
        var option: AVMediaSelectionOption?
        private var pending: [AVMediaSelectionOption?] = []

        init(option: AVMediaSelectionOption? = nil) { self.option = option }

        mutating func observe(_ selected: AVMediaSelectionOption?) -> Bool {
            let changed = option != selected
            option = selected
            if let acknowledged = pending.lastIndex(where: { $0 == selected }) {
                pending.removeSubrange(...acknowledged)
                return false
            }
            return changed
        }

        mutating func request(_ selected: AVMediaSelectionOption?, current: AVMediaSelectionOption?) -> Bool {
            _ = observe(current)
            guard current != selected || !pending.isEmpty else { return false }
            pending.append(selected)
            return true
        }
    }

    private func nativeOptions(_ options: [(id: String, option: AVMediaSelectionOption)],
                               sources: [MediaTrack], prefix: String) -> [PlaybackTrackOption] {
        let unavailable = prefix == "audio-" ? " · requires TV Compatibility" : " · unavailable in Original"
        let native = options.enumerated().map { offset, mapped in
            PlaybackTrackOption(id: mapped.id,
                                label: "\(mapped.option.displayName) [\(offset + 1)]" + (mapped.option.isPlayable ? "" : unavailable),
                                isPlayable: mapped.option.isPlayable)
        }
        // AVFoundation may omit unsupported streams entirely. Keep their source
        // identity visible so a requested language cannot silently become another.
        let missing = sources.filter { source in !native.contains { $0.id == "\(prefix)\(source.index)" } }
        return native + missing.map {
            PlaybackTrackOption(id: "\(prefix)\($0.index)", label: "\($0.label) [\($0.ordinal + 1)]" + unavailable, isPlayable: false)
        }
    }

    func selectAudio(_ id: String) {
        guard !isPreparing, selectedAudioTrackID != id, audioOptions.contains(where: { $0.id == id }) else { return }
        selectedAudioTrackID = id
        if mode == .original {
            audioSelectionUnavailable = audioGroup == nil || nativeAudio[id]?.isPlayable != true
            updateTrackSelectionError()
            guard !audioSelectionUnavailable, let group = audioGroup, let option = nativeAudio[id] else { return }
            if let item = player.currentItem { selectNative(option, in: group, item: item, isAudio: true) }
        } else { audioSelectionUnavailable = false; clearTrackSelectionError(); reload() }
    }

    func selectSubtitle(_ id: String) {
        guard !isPreparing, let item = player.currentItem else { return }
        guard id == "off" || subtitleOptions.contains(where: { $0.id == id }) else {
            errorMessage = "macOS could not select this subtitle track. Try loading an external SRT or VTT file."
            return
        }
        selectedSubtitleID = id
        subtitleSelectionUnavailable = id != "off" && (subtitleGroup == nil || nativeSubtitles[id]?.isPlayable != true)
        updateTrackSelectionError()
        guard !subtitleSelectionUnavailable else { return }
        if errorMessage?.hasPrefix("Subtitles:") == true { errorMessage = nil }
        if let group = subtitleGroup {
            selectNative(id == "off" ? nil : nativeSubtitles[id], in: group, item: item, isAudio: false)
        }
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
        guard canPreserveTracks(in: .compatibility, replacingSubtitles: true) else { return }
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
        guard !audioSelectionUnavailable, !subtitleSelectionUnavailable else { return }
        if wantsToPlay { wantsToPlay = false; player.pause(); status = "Paused" }
        else if position >= duration - 0.2 { seek(0, autoplay: true) }
        else { wantsToPlay = true; player.playImmediately(atRate: rate) }
    }

    func seek(_ seconds: Double, autoplay: Bool? = nil) {
        guard media != nil, !isPreparing else { return }
        let target = max(0, min(seconds, max(0, duration - 0.05)))
        if let autoplay { wantsToPlay = autoplay && !audioSelectionUnavailable && !subtitleSelectionUnavailable }
        let id = UUID(); seekID = id
        position = target; isSeeking = true
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target + nativeTimelineOrigin, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekID == id else { return }
                self.isSeeking = false
                if finished && self.wantsToPlay { self.player.playImmediately(atRate: self.rate) }
            }
        }
    }

    func setRate(_ value: Float) { rate = value; if player.rate > 0 { player.rate = value } }
    func skip(_ seconds: Double) { seek(position + seconds) }

    func close() {
        loadID = UUID(); seekID = UUID()
        let previousLoad = loadTask, previousProbe = probeRunner, previousSession = session
        loadTask?.cancel(); loadTask = nil; probeRunner?.stop(); probeRunner = nil
        player.pause(); itemObservations.removeAll(); player.replaceCurrentItem(with: nil)
        server?.stop(); server = nil
        session?.cancelProcesses()
        session = nil
        retainCleanup(load: previousLoad, runner: previousProbe, session: previousSession)
        wantsToPlay = false; audioSelectionUnavailable = false; subtitleSelectionUnavailable = false
        nativeItemIsOriginal = false
        nativeTimelineOrigin = 0
        retainedAudioPropertyList = nil; retainedSubtitlePropertyList = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil; readyItemID = nil
        audioGroup = nil; subtitleGroup = nil; nativeAudio = [:]; nativeSubtitles = [:]
        observedAudioSelection = NativeSelectionState(); observedSubtitleSelection = NativeSelectionState()
        audioOptions = []; subtitleOptions = []; selectedAudioTrackID = ""; selectedSubtitleID = "off"; externalSubtitle = nil
        media = nil; position = 0; streamURL = nil; errorMessage = nil
        cachedIndices = []; cacheBytes = 0; conversionSpeed = 0
        isPreparing = false; isBuffering = false; isSeeking = false; isPlaying = false
        status = "Your next movie, beautifully connected."
    }

    /// Application termination waits for every previously closed movie as well
    /// as the current one, including its detached probe and temporary files.
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        isShuttingDown = true
        close()
        observations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        let pending = Array(cleanupTasks.values)
        let task = Task { for cleanup in pending { await cleanup.value } }
        shutdownTask = task
        await task.value
    }

    private func retainCleanup(load: Task<Void, Never>? = nil, runner: MediaProcessRunner? = nil,
                               session: TranscodeSession? = nil) {
        guard load != nil || runner != nil || session != nil else { return }
        let id = UUID()
        cleanupTasks[id] = Task { [weak self] in
            if let runner { await runner.stopAndWait() }
            if let load { await load.value }
            if let session { await session.stop() }
            self?.cleanupTasks[id] = nil
        }
    }

    private func updateTrackSelectionError() {
        guard audioSelectionUnavailable || subtitleSelectionUnavailable else {
            clearTrackSelectionError()
            if status == "Choose an available audio or subtitle track" { status = "Paused" }
            return
        }
        wantsToPlay = false
        player.pause()
        status = "Choose an available audio or subtitle track"
        let track = audioSelectionUnavailable ? "audio" : "subtitle"
        let alternatives = subtitleSelectionUnavailable ? "Choose an available track or turn subtitles Off." : "Choose an available audio track."
        let imageSubtitle = !audioSelectionUnavailable && media?.subtitleTracks.first(where: { "embedded-\($0.index)" == selectedSubtitleID })?.supportsTextSubtitles == false
        let guidance = imageSubtitle ? "Load an external text subtitle file to replace these image subtitles." : (mode == .original ? "Select TV Compatibility to use the selected track." : "Try an external text subtitle file or another playback mode.")
        errorMessage = "Tracks: the selected \(track) track cannot be played in \(mode.rawValue). \(guidance) \(alternatives)"
    }

    private func updateNativePlaybackState() {
        guard !audioSelectionUnavailable, !subtitleSelectionUnavailable else {
            wantsToPlay = false
            isPlaying = false; isBuffering = false
            if player.rate != 0 || player.timeControlStatus != .paused { player.pause() }
            status = "Choose an available audio or subtitle track"
            return
        }
        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if !isPreparing, !isSeeking {
            if player.timeControlStatus == .paused { wantsToPlay = false }
            else if player.timeControlStatus == .playing { wantsToPlay = true }
        }
        if isPlaying { status = isAirPlaying ? "Playing on your AirPlay device" : "Playing on this Mac" }
    }

    private func clearTrackSelectionError() {
        if !audioSelectionUnavailable, !subtitleSelectionUnavailable, errorMessage?.hasPrefix("Tracks:") == true { errorMessage = nil }
    }

    func copyDiagnostics() {
        let text = """
        Velora 0.2.2 · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
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

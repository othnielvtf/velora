import SwiftUI
import AppKit
import VeloraCore

private let lavender = Color(red: 0.68, green: 0.59, blue: 1)
private let panelColor = Color(red: 0.085, green: 0.09, blue: 0.13)

struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @State private var showingSettings = false
    @State private var isTargeted = false
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @State private var appeared = false
    @StateObject private var windowState = PlayerWindowState()
    @State private var controlsVisible = true
    @State private var pointerInControls = false
    @State private var routePickerPresented = false
    @State private var menuPresented = false
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if windowState.isFullscreen { Color.black }
            else {
                LinearGradient(colors: [Color(red: 0.075, green: 0.075, blue: 0.115), Color(red: 0.035, green: 0.04, blue: 0.065)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            VStack(spacing: windowState.isFullscreen ? 0 : 20) {
                if !windowState.isFullscreen { header }
                videoStage
                if !windowState.isFullscreen {
                    errorBanner
                    transport
                    connectionStrip
                }
            }
            .padding(.horizontal, windowState.isFullscreen ? 0 : 28)
            .padding(.top, windowState.isFullscreen ? 0 : 37)
            .padding(.bottom, windowState.isFullscreen ? 0 : 22)
            if windowState.isFullscreen { fullscreenChrome }
        }
        .ignoresSafeArea(.container, edges: windowState.isFullscreen ? .all : [])
        .frame(minWidth: 870, minHeight: 690)
        .background(PlayerWindowReader(state: windowState).frame(width: 0, height: 0))
        .tint(lavender)
        .sheet(isPresented: $showingSettings) { settings }
        .onChange(of: model.quality) { _, _ in if appeared { model.reload() } }
        .onChange(of: model.selectedAddress) { old, new in if appeared && old != new && model.mode == .compatibility { model.reload() } }
        .onChange(of: windowState.isFullscreen) { _, _ in revealControls() }
        .onChange(of: windowState.interactionCounter) { _, _ in revealControls() }
        .onChange(of: shouldAutoHide) { _, _ in revealControls() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuPresented = true; revealControls() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuPresented = false; revealControls() }
        .onAppear { appeared = true; windowState.onSkip = model.skip }
        .onDisappear { hideControlsTask?.cancel(); windowState.detach() }
    }

    private var videoStage: some View {
        ZStack {
            Color.black
            if model.media != nil {
                MovieSurface(player: model.player, liftCaptions: windowState.isFullscreen && controlsVisible)
                    .overlay {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2, perform: windowState.toggleFullscreen)
                            .accessibilityHidden(true)
                    }
            } else { welcome }
            if model.isAirPlaying {
                VStack(spacing: 12) {
                    Image(systemName: "airplayvideo").font(.system(size: 44, weight: .light)).foregroundStyle(lavender)
                    Text("Playing on your AirPlay device").font(.title3.weight(.medium))
                    Text("Control playback from this Mac.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.94))
            }
            if let text = model.busyText {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text(text).font(.system(size: 13, weight: .medium))
                }
                .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if isTargeted {
                Rectangle().fill(lavender.opacity(0.12))
                Text("Drop your movie here").font(.title2.weight(.medium)).padding(20).background(.ultraThinMaterial, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: windowState.isFullscreen ? 0 : 20))
        .overlay(RoundedRectangle(cornerRadius: windowState.isFullscreen ? 0 : 20)
            .strokeBorder(isTargeted ? lavender : (windowState.isFullscreen ? .clear : .white.opacity(0.08)), lineWidth: 1))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url) }
            }
            return true
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
                Spacer()
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss playback error")
            }
            .padding(12).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var shouldAutoHide: Bool {
        windowState.isFullscreen && model.media != nil && model.isPlaying &&
        !model.isAirPlaying && model.busyText == nil && model.errorMessage == nil &&
        !scrubbing && !pointerInControls && !routePickerPresented && !menuPresented && !showingSettings && !isTargeted
    }

    private func revealControls() {
        hideControlsTask?.cancel()
        NSCursor.setHiddenUntilMouseMoves(false)
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        guard shouldAutoHide else { return }
        hideControlsTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, shouldAutoHide else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
            if windowState.window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    private func controlsHoverChanged(_ inside: Bool) {
        guard pointerInControls != inside else { return }
        pointerInControls = inside
        // Hiding an overlay can itself send a hover-exit notification. Do not reveal it again.
        if inside || controlsVisible { revealControls() }
    }

    private var fullscreenChrome: some View {
        ZStack {
            VStack {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).frame(height: 170)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 180)
            }.allowsHitTesting(false)
            VStack(spacing: 0) {
                fullscreenHeader
                    .padding(.horizontal, 32).padding(.top, windowState.topInset)
                Spacer(minLength: 24)
                VStack(spacing: 14) {
                    errorBanner
                    fullscreenControls
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
    }

    private var fullscreenHeader: some View {
        HStack(spacing: 16) {
            Button(action: windowState.toggleFullscreen) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain).help("Exit full screen (Esc)").accessibilityLabel("Exit full screen")
            VStack(alignment: .leading, spacing: 5) {
                Text(model.media?.source.deletingPathExtension().lastPathComponent ?? "Velora")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(model.mode.rawValue).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 20)
            playbackModeControl
            Button(action: model.openPanel) {
                Image(systemName: "folder").font(.system(size: 15)).frame(width: 38, height: 38)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain).help("Open movie (⌘O)").accessibilityLabel("Open Movie")
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15)).frame(width: 38, height: 38)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain).help("Playback settings").accessibilityLabel("Playback settings")
        }
        .padding(4)
        .onHover(perform: controlsHoverChanged)
    }

    private var fullscreenControls: some View {
        transport
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.4))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .onHover(perform: controlsHoverChanged)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [lavender, Color(red: 0.39, green: 0.3, blue: 0.81)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "play.fill").font(.system(size: 18, weight: .medium)).foregroundStyle(.white).offset(x: 1)
            }.frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("Velora").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text(model.media?.source.deletingPathExtension().lastPathComponent ?? "A better view, anywhere.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                playbackModeControl
                Button(action: model.openPanel) {
                    Label("Open Movie", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                }
                .buttonStyle(.plain).help("Open a local video (⌘O)")
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playback settings")
                .help("Playback settings and diagnostics")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
    }

    private var playbackModeControl: some View {
        HStack(spacing: 2) {
            ForEach(PlaybackMode.allCases) { mode in
                let selected = model.mode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { model.setMode(mode) }
                } label: {
                    Label(mode.rawValue, systemImage: mode == .compatibility ? "airplayvideo" : "film")
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? lavender : .white.opacity(0.6))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(selected ? lavender.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? lavender.opacity(0.22) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(mode == .compatibility ? "Prepare a compatible stream for your AirPlay TV" : "Play the original file using macOS format support")
            }
        }
        .padding(3)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.07)))
        .disabled(model.isPreparing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback mode")
    }

    private var welcome: some View {
        VStack(spacing: 19) {
            ZStack {
                Circle().fill(lavender.opacity(0.06)).frame(width: 126, height: 126)
                Circle().stroke(lavender.opacity(0.1), lineWidth: 1).frame(width: 100, height: 100)
                Image(systemName: "play.tv").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(lavender)
            }
            VStack(spacing: 10) {
                Text("Your movies. Your big screen.").font(.system(size: 29, weight: .medium, design: .rounded)).tracking(-0.6)
                Text("Open a movie, then choose your AirPlay TV.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Button(action: model.openPanel) { Label("Choose a Movie", systemImage: "folder")
                .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 5) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
            Text("HEVC / H.265    ·    MKV    ·    MP4    ·    MOV")
                .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.1).foregroundStyle(.white.opacity(0.35))
            Text("or drop a video anywhere in this window").font(.system(size: 11)).foregroundStyle(.white.opacity(0.28))
        }.padding(30)
    }

    private var transport: some View {
        VStack(spacing: windowState.isFullscreen ? 6 : 13) {
            HStack(spacing: windowState.isFullscreen ? 10 : 12) {
                Text(timeLabel(scrubbing ? scrubTime : model.position)).monospacedDigit()
                    .frame(width: windowState.isFullscreen ? 42 : 58, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.08)).frame(height: 3)
                        if model.duration > 0 {
                            ForEach(model.cachedIndices, id: \.self) { index in
                                Rectangle().fill(lavender.opacity(0.35))
                                    .frame(width: max(1, geo.size.width * min(4, model.duration - Double(index) * 4) / model.duration), height: 3)
                                    .offset(x: geo.size.width * Double(index) * 4 / model.duration)
                            }
                        }
                        Slider(value: Binding(get: { scrubbing ? scrubTime : model.position }, set: { scrubTime = $0 }),
                               in: 0...max(1, model.duration), onEditingChanged: { editing in
                            if editing { scrubTime = model.position; scrubbing = true }
                            else { scrubbing = false; model.seek(scrubTime) }
                        })
                        .controlSize(windowState.isFullscreen ? .mini : .regular)
                        .disabled(model.media == nil || model.isPreparing)
                        .accessibilityLabel("Movie timeline").help("Jump to any scene. Unprepared sections may briefly buffer.")
                    }.frame(maxHeight: .infinity)
                }.frame(height: windowState.isFullscreen ? 16 : 20)
                Text(timeLabel(model.duration)).monospacedDigit()
                    .frame(width: windowState.isFullscreen ? 42 : 58, alignment: .trailing).foregroundStyle(.secondary)
            }.font(.system(size: windowState.isFullscreen ? 10 : 11))
            ZStack {
                if windowState.isFullscreen {
                    Label(model.isAirPlaying ? "AirPlay" : "This Mac", systemImage: model.isAirPlaying ? "airplayvideo" : "laptopcomputer")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                }
                HStack(spacing: windowState.isFullscreen ? 12 : 20) {
                    Button { model.skip(-10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: windowState.isFullscreen ? 18 : 23, weight: .light))
                            .frame(width: windowState.isFullscreen ? 28 : nil, height: windowState.isFullscreen ? 28 : nil)
                            .contentShape(Rectangle())
                    }
                        .help("Back 10 seconds (⌘←)")
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying || model.isBuffering ? "pause.fill" : "play.fill")
                            .font(.system(size: windowState.isFullscreen ? 16 : 20, weight: .semibold))
                            .frame(width: windowState.isFullscreen ? 40 : 52, height: windowState.isFullscreen ? 40 : 52)
                            .background(lavender.opacity(0.17), in: Circle()).foregroundStyle(lavender)
                    }
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play").help("Play / pause (Space)")
                    Button { model.skip(10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: windowState.isFullscreen ? 18 : 23, weight: .light))
                            .frame(width: windowState.isFullscreen ? 28 : nil, height: windowState.isFullscreen ? 28 : nil)
                            .contentShape(Rectangle())
                    }
                        .help("Forward 10 seconds (⌘→)")
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: windowState.isFullscreen ? 10 : 14) {
                    HStack(spacing: 7) {
                        Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 14).accessibilityHidden(true)
                        SlimVolumeSlider(value: $model.volume).frame(width: 68, height: 24)
                    }
                    .help("Volume")
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 14)
                    tracksMenu
                    Menu {
                        ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { speed in
                            Button("\(String(format: "%g", speed))×") { model.setRate(speed) }
                        }
                    } label: { Text("\(String(format: "%g", model.rate))×").font(.system(size: 12, weight: .medium)).frame(width: 35) }
                    .menuStyle(.borderlessButton).fixedSize().help("Playback speed; AirPlay support depends on the receiver")
                    if windowState.isFullscreen {
                        AirPlayPicker(player: model.player, onPresentationChange: { routePickerPresented = $0; revealControls() })
                            .frame(width: 26, height: 26)
                            .help("Choose an AirPlay TV")
                    }
                    Button(action: windowState.toggleFullscreen) {
                        Image(systemName: windowState.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: windowState.isFullscreen ? 13 : 16))
                    }
                    .help(windowState.isFullscreen ? "Exit full screen (Esc)" : "Full screen (⌃⌘F)")
                    .accessibilityLabel(windowState.isFullscreen ? "Exit full screen" : "Enter full screen")
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: windowState.isFullscreen ? 40 : 52)
            .buttonStyle(.plain).disabled(model.media == nil || model.isPreparing)
        }
    }

    private var tracksMenu: some View {
        Menu {
            Section("Audio") {
                if model.audioOptions.isEmpty { Text("No selectable audio tracks") }
                ForEach(model.audioOptions) { option in
                    Toggle(option.label, isOn: Binding(get: { model.selectedAudioTrackID == option.id }, set: { if $0 { model.selectAudio(option.id) } }))
                }
            }
            Section("Subtitles") {
                Toggle("Off", isOn: Binding(get: { model.selectedSubtitleID == "off" }, set: { if $0 { model.selectSubtitle("off") } }))
                ForEach(model.subtitleOptions) { option in
                    Toggle(option.label, isOn: Binding(get: { model.selectedSubtitleID == option.id }, set: { if $0 { model.selectSubtitle(option.id) } }))
                }
                if model.mode == .compatibility, let media = model.media,
                   media.subtitleTracks.contains(where: { !$0.supportsTextSubtitles }) {
                    Text("Image subtitles (PGS / VobSub) need an external text file")
                }
            }
            Divider()
            Button("Load Subtitle File…", action: model.loadSubtitlePanel)
            if model.externalSubtitle != nil { Button("Remove External Subtitles", action: model.removeExternalSubtitle) }
        } label: {
            Image(systemName: model.selectedSubtitleID == "off" ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 15)).frame(width: 24, height: 24)
                .foregroundStyle(model.selectedSubtitleID == "off" ? .white.opacity(0.7) : lavender)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Audio & Subtitles").help("Choose audio language or subtitles")
    }

    private var connectionStrip: some View {
        HStack(spacing: 15) {
            Image(systemName: model.mode == .compatibility ? "tv" : "film")
                .font(.system(size: 19, weight: .light)).foregroundStyle(lavender)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Playback").font(.system(size: 12, weight: .semibold))
                    Text(model.mode == .compatibility ? "H.264 + AAC" : (model.media?.codecLabel ?? "NATIVE"))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.06), in: Capsule()).foregroundStyle(.secondary)
                }
                Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.mode == .compatibility && model.media != nil {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(Int(model.cachedFraction * 100))% prepared").font(.system(size: 11, weight: .medium)).foregroundStyle(lavender)
                    Text(model.conversionSpeed > 0 ? "Last chunk: \(String(format: "%.1f", model.conversionSpeed))× realtime" : model.quality.description)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 29).padding(.horizontal, 6)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text(model.isAirPlaying ? "Connected" : "AirPlay").font(.system(size: 12, weight: .medium))
                Text(model.isAirPlaying ? "Playing on your TV" : "Choose your TV").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            AirPlayPicker(player: model.player).frame(width: 38, height: 38)
                .background(lavender.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .help("Choose an AirPlay TV on the same network")
                .disabled(model.media == nil || model.isPreparing)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(panelColor.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.05)))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A little fine-tuning").font(.title2.weight(.semibold))
                    Text("Keep the picture smooth and the connection simple.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { showingSettings = false }.keyboardShortcut(.defaultAction)
            }
            Form {
                Section("TV Compatibility") {
                    Picker("Streaming quality", selection: $model.quality) {
                        ForEach(StreamQuality.allCases) { Text($0.description).tag($0) }
                    }
                    .disabled(model.isPreparing)
                    Text("Compatibility mode converts video to SDR H.264 at up to 30 fps, with stereo AAC audio. Your original file stays untouched.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.media?.isHDR == true {
                        Label("This HDR source is tone-mapped to SDR in compatibility mode.", systemImage: "sun.max")
                            .font(.system(size: 11)).foregroundStyle(lavender)
                    }
                }
                Section("Network") {
                    if model.addresses.isEmpty {
                        Label("Connect to Wi-Fi or Ethernet to stream to your TV.", systemImage: "wifi.exclamationmark")
                    } else {
                        Picker("Streaming interface", selection: $model.selectedAddress) {
                            ForEach(model.addresses) { Text($0.label).tag($0.address) }
                        }.disabled(model.isPreparing)
                    }
                    Text("Your Mac and TV must be on the same network. Allow Local Network access and incoming connections if macOS asks. Guest Wi-Fi or a VPN can block the TV’s connection.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Refresh interfaces") { model.addresses = LANAddress.available(); if !model.addresses.contains(where: { $0.address == model.selectedAddress }) { model.selectedAddress = model.addresses.first?.address ?? "" } }
                }
                if let media = model.media {
                    Section("This movie") {
                        LabeledContent("Video", value: "\(media.codecLabel) · \(media.width) × \(media.height)")
                        LabeledContent("Audio", value: model.audioOptions.first(where: { $0.id == model.selectedAudioTrackID })?.label ?? "No audio")
                        LabeledContent("Subtitles", value: model.subtitleOptions.first(where: { $0.id == model.selectedSubtitleID })?.label ?? "Off")
                        LabeledContent("Duration", value: timeLabel(media.duration))
                        LabeledContent("Temporary cache", value: ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .file))
                    }
                }
                Section {
                    Text("Seeking to an unprepared scene can briefly buffer. Converted chunks are cached up to 2 GB and removed when you close the movie. AirPlay timing and speed controls vary by TV.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Text("VELORA 0.2 · APPLE SILICON").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                Button("Copy Diagnostics", action: model.copyDiagnostics)
            }
        }.padding(26).frame(width: 560, height: 620).preferredColorScheme(.dark).tint(lavender)
    }
}

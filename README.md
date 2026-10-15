# Velora

**A native Mac video player that prepares HEVC movies for your AirPlay TV.**

Open a movie, choose your TV, and watch. Velora converts video into H.264 and AAC as it is needed, with a seekable timeline and a compact fullscreen interface.

[Download v0.1.0](https://github.com/othnielvtf/velora/releases/tag/v0.1.0) · [Report a problem](https://github.com/othnielvtf/velora/issues)

![Velora in fullscreen with its compact playback panel](docs/screenshots/fullscreen.png)

> **Early preview:** local HEVC playback and streaming have been tested. Physical Samsung, LG and Hisense AirPlay receivers still need testing; compatibility and seek latency vary by TV and source. The downloadable app is ad hoc signed, **not Developer ID signed or notarized**.

## Features

- **HEVC / H.265 playback**, including MKV, MP4 and MOV through TV Compatibility mode.
- **Native AirPlay picker** for compatible TVs on your local network.
- **On-demand conversion** using Apple's VideoToolbox H.264 hardware encoder.
- **Seek anywhere:** four-second chunks are prepared independently, without converting all earlier video first.
- **Clean fullscreen controls** that fade during playback and return with mouse or keyboard activity.
- Timeline scrubbing, ten-second skips, slim volume control and playback speed selection.
- 1080p or 720p compatibility streams, plus an Original mode for formats supported by macOS.
- Local conversion and playback; no account or cloud service required.

## Screenshots

### Windowed playback

![Velora windowed playback](docs/screenshots/windowed.png)

### Ready to play

![Velora welcome screen](docs/screenshots/welcome.png)

Screenshots show the actual app. The landscape is original artwork rendered into an HEVC demo clip; no movie is included in the download.

## Requirements

- Apple silicon Mac (M1 or later).
- macOS 14 Sonoma or later. The release was tested on macOS 26; earlier supported versions need testing.
- An AirPlay-capable TV for TV playback, on the same local network as your Mac.
- Enough free disk space for the temporary conversion cache (up to 2 GB per movie).

Intel Macs are not supported by this release.

## Install

1. Download **Velora-0.1.0-macOS-arm64.zip** from [Releases](https://github.com/othnielvtf/velora/releases/tag/v0.1.0).
2. Unzip it and move **Velora.app** to Applications.
3. Open the app. Because this preview is not notarized, macOS may block the first launch. If you trust this download, use **System Settings → Privacy & Security → Open Anyway**, then confirm the per-app prompt. See [Apple's guidance](https://support.apple.com/en-us/102445).

FFmpeg and FFprobe are included. No Homebrew or separate codec installation is needed.

## Watch on your TV

1. Leave **TV Compatibility** selected.
2. Click **Open Movie**, press **⌘O**, or drop a video onto the window.
3. Wait for the first chunk to prepare, then use the **AirPlay** button to choose your TV.
4. Allow Local Network access and incoming connections if macOS asks.

The Mac must remain awake and connected while watching. Seeking to an uncached position can briefly buffer; Velora does not promise instant seeking or zero startup delay. AirPlay receiver buffering adds its own delay.

Use the settings button to choose stream quality or a LAN interface. If the TV appears but playback fails, check the macOS firewall, Local Network permission, VPN routing and guest Wi-Fi isolation. The TV must be able to reach the Mac.

## Controls

| Action | Shortcut |
| --- | --- |
| Open a movie | ⌘O |
| Play / pause | Space |
| Back / forward ten seconds | ⌘← / ⌘→ |
| Back / forward in fullscreen | ← / → |
| Toggle fullscreen | ⌃⌘F or double-click the video |
| Exit fullscreen | Esc |
| Close the movie | ⇧⌘W |

## How it works

**TV Compatibility** creates a local HLS stream of independently encoded four-second MPEG-TS chunks. Video is H.264 High Profile, up to 1080p30 at 6 Mbps or 720p30 at 3 Mbps, with stereo AAC when audio is present. Smaller sources are not enlarged. The complete VOD timeline is available immediately; requested chunks are generated on demand and cached.

The native AVPlayer handles playback and AirPlay. Velora uses Apple's receiver picker rather than implementing the AirPlay protocol itself. A token-scoped local HTTP server serves only the active movie's playlists and converted chunks. It does not expose the original file or arbitrary folders. Closing a movie stops its server, cancels conversion and removes its cache. The original file is never changed.

**Original** plays the original file with macOS's native format support. HEVC in a supported MP4/MOV may play directly; MKV and unsupported audio often need TV Compatibility. Direct AirPlay depends on the source and receiver.

## Current limitations

- Physical AirPlay TV testing is pending. Please include your TV model and firmware when reporting results.
- No subtitles, multichannel audio passthrough, Dolby Vision preservation or HDR output in compatibility mode.
- Tagged PQ/HLG sources have an SDR tone-mapping path, which needs more real-source validation.
- Speed controls depend on receiver support. There is no trick-play preview track.
- Conversion speed, startup and seeking depend on source complexity, Mac hardware, Wi-Fi and the receiver.
- Only the first video and first audio track are used.

**Copy Diagnostics** includes the movie filename and local network address. Review it before posting an issue; stream access tokens are omitted. For implementation checks and measured local results, see [VERIFICATION.md](VERIFICATION.md).

## Build from source

Install Xcode or its Command Line Tools with **Swift 6 or later**, then:

```sh
git clone https://github.com/othnielvtf/velora.git
cd velora
./scripts/build.sh
open dist/Velora.app
```

The first build downloads checksum-pinned FFmpeg 9.0.2 and zimg 3.0.6 sources and compiles the tools locally. This takes several minutes and requires Internet access. It uses Xcode's compiler, `/usr/bin/python3` (3.9+) and system build tools, without installing global dependencies. Upstream source archives are kept in `.build/media-tools/archives`.

The script creates an ad hoc signed bundle in `dist/Velora.app`. Quit the app before rebuilding over it. Set `VELORA_APP_PATH`, `VELORA_BUILD_DIR` or `VELORA_TOOLS_BUILD_DIR` to choose other output directories. You can also open `Package.swift` in Xcode after building the media tools.

### Verification

```sh
swift test
swift run VeloraCheck \
  --tools "$PWD/Resources/Tools" \
  --input "/absolute/path/to/movie.mkv" \
  --report "/absolute/path/to/report.json"
```

The integration check exercises the real HTTP stream, H.264/AAC output, duplicate requests, byte ranges, token isolation, AVPlayer duration, decoded frames and forward/backward seeks. It does not connect to a TV.

### Source layout

| Path | Purpose |
| --- | --- |
| `Sources/Velora` | SwiftUI interface, native controls and playback state |
| `Sources/VeloraCore` | Metadata, conversion, HLS chunks and LAN server |
| `Sources/VeloraCheck` | Local end-to-end verification executable |
| `Tests/VeloraCoreTests` | Timeline, HTTP and byte-range tests |
| `scripts` | App packaging, icon generation and media-tool builds |

## License

Velora is licensed under **GPL-3.0-or-later**. FFmpeg and zimg retain their own licenses and copyright notices. The release includes a corresponding-source archive for the bundled media tools and their build script. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

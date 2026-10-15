# Changelog

## 0.2.0 — 2026-10-15

- Audio & Subtitles menu in windowed and compact fullscreen playback.
- Select audio languages in TV Compatibility and Original modes. Compatibility switching retains playback position, pause/play state and caption choice.
- Embedded SRT/ASS/SSA/WebVTT/MP4 text subtitles, optional native HLS captions, language switching and Off.
- External UTF-8 SRT/VTT/ASS/SSA loading, replacement and removal; subtitle drag-and-drop and ⇧⌘O.
- SDH and forced-track metadata, including distinct tracks in the same language.
- Captions stay above visible fullscreen controls and return to normal placement when controls fade.
- Eight unit tests and a generated two-language streaming/AVPlayer verification utility.

PGS/VobSub image subtitles and full ASS typography are not supported in TV Compatibility. AirPlay receiver caption rendering still requires physical TV testing.

## 0.1.0 — 2026-10-15

Initial public preview for Apple silicon Macs running macOS 14 or later.

- Native SwiftUI player with TV Compatibility and Original playback modes.
- On-demand HEVC-to-H.264 conversion and stereo AAC for local AirPlay HLS streams.
- Full movie seeking with independently prepared four-second chunks.
- Native AirPlay device picker, 1080p/720p quality selection and LAN interface selection.
- Compact fullscreen panel with auto-hide, slim volume control and keyboard shortcuts.
- Bundled, locally built FFmpeg/FFprobe 9.0.2 and zimg 3.0.6 with corresponding source.

Local playback and streaming checks pass. Physical AirPlay TV validation is pending. This preview is ad hoc signed and is not notarized.

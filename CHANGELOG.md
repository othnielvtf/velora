# Changelog

## 0.2.2 — 2026-10-18

- Build the compatibility timeline from playable video, excluding audio padding and normalizing source timestamp offsets.
- Preserve long held frames in variable frame rate sources and retain sub-frame NTSC tails with the preceding chunk.
- Map Original playback through its native video start so seeking and mode switches retain the same scene.
- Limit subtitle extraction to two jobs and cancel scans when their final requesting client leaves.
- Enforce unavailable-track playback blocks for native play/rate events and recover after native playable-track changes.
- Wait for all active and previously closed media workers to be reaped before quitting, including suspended audio encoders.
- Publish remuxed chunks only after completion; remove partial output on cancellation or failure.
- Validate native audio/subtitle playability and retain unsupported requested tracks with guidance to use TV Compatibility.
- Align audio seek runs to a shared AAC frame grid with preroll, preserving continuity through previously buffered chunks.

- Keep AAC continuous across video chunks, bound audio lookahead, and start distant seeks at the requested scene.
- Cancel abandoned conversion requests without interrupting other clients sharing the same chunk.
- Cache converted subtitles across sessions and allow full-file extraction time based on source size.
- Preserve anamorphic display aspect, selected audio/subtitle tracks across playback modes, and Pause during pending seeks.
- Keep compatibility quality changes from reloading Original playback.
- Separate idle HTTP connections from active requests and enforce header deadlines.
- Enforce media-process timeouts and cancellation with bounded termination, including suspended audio workers.


## 0.2.1 — 2026-10-16

- Fix captions drifting or disappearing during uninterrupted TV Compatibility playback. Video and WebVTT playlists now keep the existing continuous movie clock instead of announcing a timeline reset every four seconds.
- Keep MPEG-TS packet-counter reset signaling inside each independently encoded chunk; full-movie seeking remains available.
- Check actual AVPlayer caption timing and visibility across multiple chunks through the final subtitle, in addition to switching languages and seeking.
- Verification players stay muted and disable external playback so checks do not take over a user's AirPlay route.

The continuous playback failure was reproduced locally before the fix. Physical AirPlay receiver retesting is still needed.

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

# Velora verification

## 0.2.0 — audio and subtitles

Checked on 15 October 2026 on the same Apple M5 Pro/macOS/Swift toolchain described below.

- Eight unit tests passed, including exact global track indexes, default audio disposition, language normalization, safe HLS metadata, SDH tags, WebVTT segment boundaries, multilingual text, empty subtitle segments and invalid timestamps.
- A 30-second HEVC MKV with two audio tracks and three text subtitle tracks passed the real streaming check. The two selected audio streams decoded to the correct 440 Hz and 880 Hz tones, measured after AAC priming/padding.
- AVPlayer exposed English, Japanese and English SDH as separate native subtitle options. HLS NAME identity was verified through common-title metadata, since localized display names omit source track names.
- The actual AVPlayer legible output delivered English and Japanese captions, switched languages, delivered the correct Japanese text after a distant seek, and disabled subtitles with Off.
- Concurrent requests for the same subtitle segment returned the same result. Full subtitle VOD playlists and unknown-track URL rejection passed.
- External SRT, VTT and ASS files converted into correctly timed WebVTT, including cues spanning four-second chunk boundaries.
- A native HEVC MP4 with two AAC tracks and timed-text subtitles passed Original-mode audio selection and English/Japanese caption delivery checks.
- The repository's standalone `scripts/verify-tracks.sh` generated its own H.264/two-tone/WebVTT MKV fixture and passed the complete audio/subtitle integration check using only the bundled tools.
- In the native interface, choosing another audio track retained a paused position of 22.266 seconds and the subtitle selection. English captions rendered visibly above the compact fullscreen controls.
- The existing HEVC/AAC and silent 10-bit PQ-tagged playback integration checks passed again with the updated core and rebuilt tools.
- Subtitle changes made while paused may need playback to resume before the caption display refreshes. The external subtitle file panel was inspected, but its complete interactive import was not verified before user testing began. External SRT/VTT/ASS conversion passed the separate automated check.

Physical AirPlay TV audio/subtitle switching and rendering remain untested. PGS/VobSub bitmap captions, full ASS typography, karaoke and font attachments are outside this version's TV Compatibility support.

## 0.1.0 baseline

Release checks completed on 15 October 2026 on an Apple M5 Pro running macOS 26.6.2, using Swift 6.4, Apple Clang 21 and the macOS 27 SDK. Minimum deployment target: macOS 14. Earlier supported macOS versions and other Mac hardware have not been tested.

## Passed

- Debug and release builds; four unit tests for complete VOD timelines, final chunks, exact boundaries, byte ranges, HTTP parsing and HEAD serialization.
- Deep, strict verification of the ad hoc signed app bundle and its two ad hoc signed helper executables.
- FFmpeg 9.0.2 and zimg 3.0.6 built locally from checksum-pinned, unmodified sources. Helpers link only to macOS system libraries and frameworks; zimg is statically linked.
- Real local HTTP playlists and converted H.264/AAC MPEG-TS chunks, duplicate-request coalescing, byte ranges, HEAD metadata, invalid ranges and token isolation.
- AVPlayer loaded full duration, played, sought forward/backward, resumed and returned a decoded video frame for a synthetic 96-second 720p HEVC MKV with AAC.
- The same integration check passed for a silent 24-second 1080p 10-bit HEVC file explicitly tagged BT.2020/PQ. The metadata inspector reported HDR and exercised zscale/tonemap. This validates the filter path, not color accuracy on a real HDR movie or TV.
- Native UI checks: file opening, fullscreen entry/exit, double-click toggle, three-second idle hiding, keyboard reveal/pause/seek, retained position, volume binding and compact fullscreen layout at 1920×1080.

## Measured local release results

| Synthetic source | First 4-second chunk | AVPlayer ready after prewarm | Forward seek + resumed playback | Backward seek + resumed playback |
| --- | --- | --- | --- | --- |
| 720p HEVC MKV + AAC, 96 s | 1.046 s | 0.311 s | 1.151 s | 2.663 s |
| 1080p 10-bit HEVC, PQ-tagged, silent, 24 s | 0.862 s | 1.034 s | 2.000 s | 2.586 s |

These measurements include at least 0.6 seconds of playback after a forward seek and 0.5 seconds after a backward seek. They are local synthetic checks, not guaranteed performance. They exclude TV discovery, route negotiation, Wi-Fi and receiver buffering. An earlier silent 1080p fixture took 10.693 seconds to seek forward and resume, so latency is not predictable across inputs.

## Pending

Physical Samsung/LG/Hisense AirPlay video and audio, TV-remote seeks, disconnect/reconnect, receiver buffering and rate changes, real HDR color accuracy, long movies, varied source frame rates, and macOS 14/15 compatibility. No physical AirPlay receiver was connected during these checks. The release is an early preview, not a receiver compatibility certification.

## Screenshots

The README images are actual app captures using original landscape artwork encoded as an HEVC demo clip. The windowed screenshots omit the macOS title-bar recording indicator. No playback controls or app content were composited into the images.

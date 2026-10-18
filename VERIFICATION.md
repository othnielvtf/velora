# Velora verification

## 0.2.2 — third audit fixes and follow-up review

Checked on 18 October 2026 on the local Apple silicon Mac with Swift 6.4. All 79 tests passed (58 core and 21 player), with no skips, including the optional native mode-switching check. The release app rebuilt and passed deep strict signature verification. The real HTTP/AVPlayer playback check and two-language audio/subtitle check passed again.

- The compatibility timeline uses video duration rather than container/audio padding, with bounded packet probing when per-video duration is missing. Input seeks account for video starting after the container clock. Original mode maps the same normalized clock through AVFoundation's nonempty video edit, retains scene position across mode changes, and stops before an audio-only tail.
- Video conversion retains the frame preceding an input seek, expands held frames onto the output clock, then trims the requested interval. Actual AAC-padding, timestamp-offset, NTSC, low-frame-rate and variable-frame-rate fixtures request every advertised chunk and check video packet timestamps. Sub-frame final intervals stay with the preceding chunk; its playlist duration and closed AAC tail remain intact.
- Native play, direct rate and immediate-play requests cannot bypass an unavailable audio/subtitle selection. Actual AVPlayer tests verify playable native audio recovery, stale selection notifications, unsupported intent retention and offset-file mode roundtrips.
- Subtitle extraction is limited to two workers per session. Process-backed tests cover ten requested tracks, shared consumers, prompt individual cancellation, last-consumer reaping, queued cancellation, replacement-job identity, stop cleanup and persistent cache reuse.
- Follow-up independent reviews found and resolved two related timing cases: Original-mode empty leading edits and held final video frames. Final read-only reviews found no further actionable defect in the reviewed player, timeline, audio, HTTP, process, cache or cancellation paths. A separate post-fix packet audit passed 26 chunks across five timing fixtures, and a distant seek succeeded after the source audio had already ended.

Physical AirPlay receiver behavior, older supported macOS versions and real HDR color accuracy still need device testing.

## 0.2.2 — second audit fixes

Checked on 18 October 2026. All 58 tests passed (42 core and 16 player tests), including the optional native MP4 mode-switching check. The release bundle rebuilt and passed deep strict signature verification.

- Application termination now waits for current and previously closed probes and sessions. The coordinator tests cover repeated quit requests, last-window termination, and real running/suspended workers that require SIGKILL escalation.
- In the rebuilt native app, opened a generated silent 96-second movie and confirmed its real bundled FFmpeg audio worker was suspended by the lookahead limiter. Seeking and quitting removed the app and worker PIDs and the session directory; no bundle processes remained. Evidence is kept in `.build/second-audit-qa/ShutdownBefore.json` and `ShutdownAfter.json`.
- Remux cancellation/failure tests write partial transport data, then verify it never escapes scratch storage, retries count only published files, and failed replacements retain cached input.
- Actual AVFoundation fixtures verify playable video with unplayable native audio options. Unsupported selections block autoplay, retain the requested language and offer TV Compatibility; supported options still play and switch normally.
- Audio runs start on a common eight-second boundary (375 AAC frames at 48 kHz) with at least one preceding grid block of preroll for nonzero anchors. Mixed original/seek audio chunks now have continuous packet timestamps, unchanged decoded sample counts, and no waveform dips at cached/seek joins in either direction. Odd/even seek starts and multiple encoder runs are covered.
- The 96-second HTTP/AVPlayer check passed full duration, decoded video, byte ranges, HEAD, duplicate requests, token isolation and forward/backward seeking. The 30-second track check passed continuous subtitle timing, language switching/seeking, Off and external SRT/VTT/ASS conversion.

Physical AirPlay receiver behavior, older supported macOS versions, and real HDR color accuracy still need device testing.


## 0.2.2 — first audit fixes

Checked on 18 October 2026 on the local Apple silicon Mac with Swift 6.4.

The final full suite passed all 47 tests (38 core and 9 player tests), including the optional native MP4 mode-switching test. The release bundle rebuilt, passed deep strict signature verification, and launched to the welcome screen.

- Regression checks cover AAC packet timestamps and continuous waveform amplitude across adjacent video chunks, concurrent distant audio requests, EOF cache reuse, missing earlier audio chunks, and stopping a paced audio run.
- A 720×576 anamorphic source with SAR 16:15 is converted to 720×540 square pixels, retaining its 4:3 display aspect.
- Actual-process tests verify stdout/stderr handling, timeout errors even when a TERM handler exits successfully, forced termination, cancellation, and suspended-process timeout accounting.
- Shared-segment tests verify that cancelling one consumer preserves another, cancelling every consumer reaps active workers and removes partials, and cancelled queued requests never launch.
- Real TCP tests cover idle-header admission/expiry, response capacity, peer reset cancellation, valid request-side half-closes, server shutdown, subtitle response deadlines, and no-store video responses.
- Subtitle cache tests verify reuse across instances, source-change invalidation, concurrent extraction deduplication, corruption recovery, atomic publication and bounded storage. Large-file timeout policy uses sparse-file fixtures; a complete 20 GB movie scan was not measured.
- Player tests cover Pause during a pending seek, stale seek callbacks, Original-mode quality changes, and canonical track matching. The optional native MP4 check passed Original → Compatibility → Original audio selection and external VTT loading without changing the selected language.
- The real HTTP/AVPlayer integration check passed manifests, duplicate requests, byte ranges, HEAD, token isolation, full duration, decoded video, and forward/backward seek and resume. The 30-second audio/subtitle check passed continuous English cue timing, Japanese switching/seeking, Off, and external SRT/VTT/ASS conversion.

Physical AirPlay receiver playback, seeking through receiver-cached chunks from a previous seek, older supported macOS versions, and real HDR color accuracy still need device testing.


## 0.2.1 — continuous subtitle playback

Checked on 16 October 2026 on the same Mac and toolchain described below.

- Reproduced the 0.2.0 failure using uninterrupted playback: the caption due at eight seconds arrived around twelve seconds, and the final line was never delivered. The old language-switch and seek checks alone did not catch this.
- Removed unnecessary HLS timeline discontinuities from both video and subtitle playlists. MPEG-TS chunks retain their existing movie-relative timestamps and in-band packet-counter discontinuity flags.
- The regression check now observes active caption text at 5.5, 9, 13 and 25 seconds, verifies the first presentation time of every line to within 150 ms of the source cue, and confirms that the video transport clock is still at 24 seconds in chunk six.
- Eight unit tests, HEVC/AAC and silent HDR-tagged playback/forward/backward seek checks, and the audio/subtitle switching, sidecar and Original-mode checks pass.
- Test players are muted and explicitly disallow external playback to avoid taking over an active AirPlay session.

The fix addresses a reproduced local stream-timing failure. A physical TV has not been used to confirm the corrected receiver behavior; reconnect AirPlay with a new movie session when retesting.

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

#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
qa="${VELORA_TRACKS_QA_DIR:-$root/.build/track-check}"
mkdir -p "$qa"
ffmpeg="$root/Resources/Tools/ffmpeg"
cat > "$qa/English.vtt" <<'VTT'
WEBVTT

00:00:00.500 --> 00:00:08.000
English subtitles are on.

00:00:08.000 --> 00:00:12.000
Seek to any scene.

00:00:12.000 --> 00:00:23.000
Your audio and subtitles, your choice.

00:00:23.000 --> 00:00:30.000
Ending line.
VTT
cat > "$qa/Japanese.vtt" <<'VTT'
WEBVTT

00:00:00.500 --> 00:00:08.000
日本語の字幕が表示されています。

00:00:08.000 --> 00:00:12.000
好きなシーンへ移動できます。

00:00:12.000 --> 00:00:23.000
音声と字幕を選べます。

00:00:23.000 --> 00:00:30.000
映画を楽しみましょう。
VTT
"$ffmpeg" -hide_banner -loglevel error -nostdin -y \
  -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -f lavfi -i sine=frequency=880:sample_rate=48000 \
  -i "$qa/English.vtt" -i "$qa/Japanese.vtt" -t 30 \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s \
  -c:v h264_videotoolbox -b:v 2000k -c:a aac -c:s webvtt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=jpn \
  -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 0 -disposition:s:1 0 \
  "$qa/Tracks.mkv"
swift run --package-path "$root" --scratch-path "${VELORA_BUILD_DIR:-$root/.build}" VeloraTracksCheck \
  --tools "$root/Resources/Tools" --input "$qa/Tracks.mkv"

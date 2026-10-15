#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${VELORA_BUILD_DIR:-$root/.build}"
app="${VELORA_APP_PATH:-$root/dist/Velora.app}"
if [ ! -x "$root/Resources/Tools/ffmpeg" ] || [ ! -x "$root/Resources/Tools/ffprobe" ]; then
    "$root/scripts/fetch-tools.sh"
fi
swift build --package-path "$root" --scratch-path "$build_dir" -c release --product Velora
bin_dir="$(swift build --package-path "$root" --scratch-path "$build_dir" -c release --show-bin-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Tools"
cp "$bin_dir/Velora" "$app/Contents/MacOS/Velora"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/Tools/ffmpeg" "$root/Resources/Tools/ffprobe" "$app/Contents/Resources/Tools/"
cp "$root/THIRD-PARTY-NOTICES.md" "$root/LICENSE" "$app/Contents/Resources/"
cp "$root/Resources/FFmpeg-LICENSE.txt" "$root/Resources/zimg-LICENSE.txt" "$app/Contents/Resources/"
swift "$root/scripts/make-icon.swift" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"

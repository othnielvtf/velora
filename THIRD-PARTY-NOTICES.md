# Third-party notices

## Velora

Velora source code and original project artwork are licensed under GPL-3.0-or-later. The complete license is in `LICENSE`.

## FFmpeg / FFprobe 9.0.2

Velora bundles two standalone executables built from the unmodified FFmpeg 9.0.2 source archive. This configuration is LGPL-2.1-or-later, with GPL and nonfree components disabled. The executables are invoked as separate processes; Velora does not link libav libraries into its Swift executable.

- Project and copyright: [FFmpeg developers](https://ffmpeg.org/).
- Source: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>.
- Source archive SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.
- License: `Resources/FFmpeg-LICENSE.txt` (also copied into the app's Resources directory).
- Build: `scripts/build-tools.py`, using Xcode's Clang, native Apple VideoToolbox/AudioToolbox and statically linked zimg. Network protocols and third-party autodetection are disabled. H.264 VideoToolbox, AAC, WebVTT and PCM (for verification) encoders are enabled; decoders and container support use FFmpeg's built-in implementations.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. Velora is an independent project and is not endorsed by FFmpeg.

The **Velora-0.2.0-media-tools-source.tar.gz** release asset contains the exact upstream FFmpeg and zimg source archives, their license texts, the build script and build instructions. These are hosted alongside the app download at <https://github.com/othnielvtf/velora/releases/tag/v0.2.0>. The script verifies both source checksums before building. No patches are applied to either upstream source tree.

Users may rebuild or replace the tools in `Velora.app/Contents/Resources/Tools` for their own use. After changing bundle contents, its ad hoc signature must be regenerated. See `scripts/build.sh` for the packaging command. No license term restricts modification or reverse engineering for debugging those modifications.

## zimg 3.0.6

- Project: [zimg](https://github.com/sekrit-twc/zimg). Upstream authorship and copyright notices are retained in the complete source archive.
- License: WTFPL Version 2, reproduced in `Resources/zimg-LICENSE.txt` and the app's Resources directory.
- Source: <https://codeload.github.com/sekrit-twc/zimg/tar.gz/refs/tags/release-3.0.6>.
- Source archive SHA-256: `be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577`.

The static library provides resizing and color conversion for the HDR-to-SDR filter. Its portable and ARM NEON source files are compiled directly, as documented in the supplied build script.

## Apple frameworks

SwiftUI, AppKit, AVKit, AVFoundation, Network.framework and the system media frameworks are provided by macOS. They are not redistributed with Velora. AirPlay is a trademark of Apple Inc. TV brand names identify potential receiver devices; they do not imply endorsement or verified compatibility.

## Screenshots

The screenshots show the actual Velora app playing original generated landscape artwork. No third-party film footage, personal media or TV screenshots are included.

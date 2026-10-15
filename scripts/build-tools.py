#!/usr/bin/python3
"""Build self-contained arm64 FFmpeg tools using only Xcode and Python 3.

Unmodified upstream archives are retained for corresponding-source distribution.
zimg is compiled directly from its portable and ARM source files, avoiding an
Autotools dependency. No third-party package manager or global install is used.
"""
import concurrent.futures
import hashlib
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ.get("VELORA_TOOLS_BUILD_DIR", ROOT / ".build" / "media-tools")).resolve()
ARCHIVES = BUILD / "archives"
PREFIX = BUILD / "prefix"
JOBS = min(12, os.cpu_count() or 4)
SOURCES = [
    ("ffmpeg-9.0.2.tar.xz", "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz",
     "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"),
    ("zimg-3.0.6.tar.gz", "https://codeload.github.com/sekrit-twc/zimg/tar.gz/refs/tags/release-3.0.6",
     "be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"),
]


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This build supports Apple silicon macOS only.")
    ARCHIVES.mkdir(parents=True, exist_ok=True)
    (PREFIX / "include").mkdir(parents=True, exist_ok=True)
    (PREFIX / "lib").mkdir(parents=True, exist_ok=True)
    for name, url, digest in SOURCES:
        archive = ARCHIVES / name
        if not archive.exists():
            print("Downloading", name, flush=True)
            run(["curl", "--fail", "--location", "--retry", "2", url, "-o", archive])
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise SystemExit("Checksum mismatch: " + name)
        with tarfile.open(archive) as source:
            # All paths must remain inside BUILD, including symbolic links.
            for member in source.getmembers():
                dest = (BUILD / member.name).resolve()
                if not dest.is_relative_to(BUILD):
                    raise SystemExit("Unsafe archive path")
                if member.issym() or member.islnk():
                    target = (dest.parent / member.linkname).resolve()
                    if not target.is_relative_to(BUILD):
                        raise SystemExit("Unsafe archive link")
            source.extractall(BUILD)

    zimg = BUILD / "zimg-release-3.0.6"
    obj = BUILD / "zimg-objects"
    obj.mkdir(exist_ok=True)
    cpp = sorted(p for p in (zimg / "src/zimg").rglob("*.cpp") if "x86" not in p.parts)

    def compile_cpp(path):
        out = obj / (str(path.relative_to(zimg)).replace("/", "_") + ".o")
        run(["xcrun", "clang++", "-std=c++14", "-O2", "-DNDEBUG", "-DZIMG_ARM",
             "-arch", "arm64", "-mmacosx-version-min=14.0", "-fPIC",
             "-I" + str(zimg / "src/zimg"), "-c", path, "-o", out])
        return out

    print("Building zimg 3.0.6", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        objects = list(pool.map(compile_cpp, cpp))
    run(["xcrun", "libtool", "-static", "-o", PREFIX / "lib/libzimg.a", *objects])
    shutil.copy2(zimg / "src/zimg/api/zimg.h", PREFIX / "include/zimg.h")

    # A narrowly scoped pkg-config adapter for our single external library.
    pkg = BUILD / "zimg-pkg-config"
    pkg.write_text("#!" + sys.executable + "\nimport sys\na=sys.argv[1:]\n"
                   "if '--version' in a: print('1.0.0'); sys.exit(0)\n"
                   "if not any('zimg' in x for x in a): sys.exit(1)\n"
                   "if '--modversion' in a: print('3.0.6')\n"
                   "if '--cflags' in a: print('-I../prefix/include')\n"
                   "if '--libs' in a: print('-L../prefix/lib -lzimg -lc++')\n")
    pkg.chmod(0o755)
    ffmpeg = BUILD / "ffmpeg-9.0.2"
    config = ["./configure", "--prefix=../prefix", "--arch=arm64", "--target-os=darwin",
              "--cc=clang", "--cxx=clang++", "--disable-autodetect", "--disable-shared",
              "--enable-static", "--disable-debug", "--disable-doc", "--disable-ffplay",
              "--disable-network", "--enable-videotoolbox", "--enable-audiotoolbox",
              "--enable-libzimg", "--pkg-config=../zimg-pkg-config",
              "--extra-cflags=-arch arm64 -mmacosx-version-min=14.0",
              "--extra-ldflags=-arch arm64 -mmacosx-version-min=14.0",
              "--disable-encoders", "--enable-encoder=h264_videotoolbox,aac,png"]
    print("Configuring FFmpeg 9.0.2", flush=True)
    run(config, cwd=ffmpeg)
    (BUILD / "ffmpeg-configure.txt").write_text(shlex.join(config) + "\n")
    run(["make", "-j", str(JOBS), "ffmpeg", "ffprobe"], cwd=ffmpeg)
    destination = ROOT / "Resources/Tools"
    destination.mkdir(parents=True, exist_ok=True)
    for tool in ("ffmpeg", "ffprobe"):
        shutil.copy2(ffmpeg / tool, destination / tool)
        run(["strip", "-S", destination / tool])
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", destination / tool])
        run(["codesign", "--verify", "--strict", destination / tool])
    shutil.copy2(zimg / "COPYING", ROOT / "Resources/zimg-LICENSE.txt")
    shutil.copy2(ffmpeg / "COPYING.LGPLv2.1", ROOT / "Resources/FFmpeg-LICENSE.txt")
    print("Built media tools:", destination, flush=True)


if __name__ == "__main__":
    main()

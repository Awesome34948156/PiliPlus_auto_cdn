#!/bin/bash
# Compile and run mpvgl.c -- the check that actually proves a decoded frame
# reaches media_kit's render path.
#
# Why this exists: `--vo=null` (mpvtest.c) proves nothing here, because it never
# touches `vo=libmpv`, the video output media_kit uses. The signal that matters is
# a real GL context plus the render API, which is what mpvgl.c sets up: a CGL 3.2
# core context, mpv_render_context_create(MPV_RENDER_API_TYPE_OPENGL) with no
# MPV_RENDER_PARAM_HW_FRAMES -- exactly media_kit's TextureHW -- rendering into an
# FBO and reading the centre pixel back. Non-black readback + hwdec-current
# videotoolbox is the end-to-end proof.
#
# Usage:
#   ./verify-render.sh <media-file> [dylib]
#
# dylib defaults to $WORK/out/Mpv.macos, the macOS slice relink.sh produces. Give
# it an AV1 file: that is the codec the stock libs could never hardware-decode.
#
# MUST be run with bash, not zsh -- see the note in relink.sh.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${WORK:-$HOME/Library/Caches/piliplus-mpvkit}

MEDIA=${1:-}
DYLIB=${2:-$WORK/out/Mpv.macos}

if [ -z "$MEDIA" ]; then
  echo "usage: $0 <media-file> [dylib]" >&2
  echo "  dylib defaults to $DYLIB" >&2
  exit 2
fi
[ -f "$DYLIB" ] || { echo "no such dylib: $DYLIB" >&2; exit 2; }
[ -f "$MEDIA" ] || { echo "no such media file: $MEDIA" >&2; exit 2; }

# mpv's headers come from the same MPVKit build as the dylib, so the API can't
# drift from the binary. Brew's /opt/homebrew/include/mpv is a *different* mpv
# (0.41 from Homebrew, not necessarily the same n9.0.2) and is not used here.
HEADERS=$WORK/xc/Libmpv.xcframework/macos-arm64_x86_64/Libmpv.framework/Headers
[ -d "$HEADERS" ] || {
  echo "no mpv headers at $HEADERS -- run fetch-xcframeworks.sh first" >&2
  exit 2
}

BIN=$(mktemp -t mpvgl)
trap 'rm -f "$BIN"' EXIT

# Deliberately NOT linked against libmpv: the dylib is dlopen'd at runtime, so the
# only mpv in the process is the one under test.
clang -DGL_SILENCE_DEPRECATION=1 -I "$HEADERS" -o "$BIN" "$HERE/mpvgl.c" \
  -framework OpenGL -ldl

# mpvgl.c exits non-zero unless it rendered frames, read back a non-black centre
# pixel, saw no render errors, and finished with `hwdec-current: videotoolbox` --
# the exit code is the verdict on all three (see README.md).
exec "$BIN" "$MEDIA" "$DYLIB"

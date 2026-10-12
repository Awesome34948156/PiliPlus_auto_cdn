#!/bin/bash
# Relink MPVKit's thirty *static* archives into the *dynamic* libmpv that
# media_kit dlopens.
#
# Why this exists: media_kit loads exactly one thing --
# DynamicLibrary.open('Mpv.framework/Mpv') -- and the media_kit_libs_* packages
# ship an ffmpeg 6.0 build that has h264/hevc/vp9_videotoolbox but *no*
# av1_videotoolbox, so --hwdec=auto silently soft-decodes every AV1 stream even
# on silicon that has an AV1 decoder. MPVKit ships mpv 0.41 + ffmpeg n9.0.2
# (which does have libavcodec/videotoolbox_av1.c), but only as static archives.
# This script produces the one dynamic binary that closes the gap, so not a
# single line of media_kit or PiliPlus has to change.
#
# Usage:
#   ./relink.sh macos         macOS universal (arm64 + x86_64)
#   ./relink.sh ios-device    iOS arm64
#   ./relink.sh ios-sim       iOS arm64 + x86_64
#   ./relink.sh ios           both iOS slices (what package.sh wants)
#
# Output goes to $WORK/out (default ~/Library/Caches/piliplus-mpvkit/out).
# Feed it to package.sh to get the tarball the media_kit libs Makefile expects.
#
# MUST be run with bash, not zsh: zsh does not word-split unquoted variables,
# which silently collapsed the archive list into one argument and broke the
# link (and the stubs object was picked up from a stale macOS build).
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${WORK:-$HOME/Library/Caches/piliplus-mpvkit}
XC=${XC:-$WORK/xc}
OUTDIR=${OUTDIR:-$WORK/out}
IOS_MIN=${IOS_MIN:-15.0}
# Keep in step with MACOSX_DEPLOYMENT_TARGET in macos/Runner.xcodeproj. Without
# this clang stamps the dylib with the SDK's own version (minos 27.0 on a
# macOS 27 SDK) and the framework then refuses to load on anything older.
MACOS_MIN=${MACOS_MIN:-12.0}

[ -d "$XC" ] || {
  echo "no xcframeworks in $XC -- run fetch-xcframeworks.sh first" >&2
  exit 1
}

# Scratch space for the stub objects and clang's own temp dirs, plus the link
# logs.
#
# One directory, one trap: every stub object (one per slice) and the (very long)
# link log live here, so a failure at any point -- including run_link's early
# `return 1` -- leaves nothing behind. Before this, each site called mktemp -d on its own
# and never cleaned up, so every run leaked a directory per slice, and a failed
# link leaked its log on top (the `rm -f` sat after the failure return).
TMPW=$(mktemp -d)
trap 'rm -rf "$TMPW"' EXIT

# ---------------------------------------------------------------- helpers ----

# Xcode puts the swift compat libraries under the default toolchain, the
# command line tools put them directly under the developer dir.
swift_lib() { # $1 = macosx | iphoneos | iphonesimulator
  local dev c
  dev=$(xcode-select -p)
  for c in "$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$1" \
           "$dev/usr/lib/swift/$1"; do
    if [ -d "$c" ]; then echo "$c"; return 0; fi
  done
  echo "no swift libs for $1 under $dev" >&2
  return 1
}

# Every xcframework's static archive for one slice, in a stable order. MPVKit's
# macOS slices are versioned frameworks (Foo.framework/Versions/Current/Foo),
# the iOS ones are flat (Foo.framework/Foo), and MoltenVK is the odd one out --
# it ships a bare `libMoltenVK.a` with no framework wrapper at all.
archives() { # $1 = slice dir, e.g. macos-arm64_x86_64
  local slice="$1" fw n lib found
  for fw in "$XC"/*.xcframework; do
    n=$(basename "$fw" .xcframework)
    found=""
    for lib in "$fw/$slice/$n.framework/Versions/Current/$n" \
               "$fw/$slice/$n.framework/$n"; do
      if [ -f "$lib" ]; then echo "$lib"; found=1; break; fi
    done
    [ -n "$found" ] && continue
    # MoltenVK ships a bare libMoltenVK.a with no framework wrapper.
    for lib in "$fw/$slice"/*.a; do
      [ -f "$lib" ] && echo "$lib"
    done
  done
}

# Split the list into the one archive that gets -force_load'd (Libmpv, whose
# whole point is to drag in everything it references) and the rest.
split_archives() { # $1 = slice dir
  MPV_ARCHIVE=""
  # This one may legitimately end up empty -- a slim $XC holding only Libmpv --
  # so every expansion site guards it. Under bash 3.2, which is what /bin/bash
  # is on macOS, a bare "${OTHER_ARCHIVES[@]}" on an empty array trips `set -u`
  # with "unbound variable" and aborts the run; bash 4.4 fixed that. The
  # `${arr[@]+...}` guard works on both. Do NOT use "${arr[@]:-}" instead --
  # bash 3.2 mishandles it and expands to a single empty argument.
  OTHER_ARCHIVES=()
  local a fws found
  while read -r a; do
    case "$a" in
      */Libmpv.framework/*) MPV_ARCHIVE="$a" ;;
      *) OTHER_ARCHIVES+=("$a") ;;
    esac
  done < <(archives "$1")
  [ -n "$MPV_ARCHIVE" ] || { echo "no Libmpv archive in slice $1" >&2; exit 1; }

  # Every xcframework on disk has to contribute exactly one archive: the
  # force-loaded Libmpv plus the rest. archives() skips one silently when it has
  # no archive for this slice, which would link a dylib quietly short of a
  # component (an under-populated binary that still links) -- so assert the total
  # against the on-disk xcframework count, not a hard-coded magic number.
  fws=("$XC"/*.xcframework)
  [ -e "${fws[0]}" ] || { echo "no xcframeworks in $XC" >&2; exit 1; }
  found=$(( 1 + ${#OTHER_ARCHIVES[@]} ))
  [ "$found" -eq "${#fws[@]}" ] || {
    echo "slice $1: got $found archives but ${#fws[@]} xcframeworks in $XC" >&2
    exit 1
  }

  echo "libmpv: $MPV_ARCHIVE"
  echo "others: ${#OTHER_ARCHIVES[@]} archives"
}

# Run the link, keeping clang's 1.8 GB worth of chatter out of the terminal but
# still failing loudly (and printing the full log) when it actually breaks.
run_link() { # $1 = output, rest = args
  local out="$1"; shift
  local log
  log="$TMPW/link-$(basename "$out").log"
  # TMPDIR is pinned to our scratch dir for the same reason as in build_stubs:
  # clang leaves a temp directory per -arch job (named after the input file)
  # behind in $TMPDIR, empty, every single run.
  if ! TMPDIR="$TMPW" clang "$@" >"$log" 2>&1; then
    echo "--- link FAILED, full log ---" >&2
    cat "$log" >&2
    return 1
  fi
  grep -viE 'alignment \(|may result in unaligned|ignoring duplicate' "$log" || true
  [ -s "$out" ] || { echo "link produced no output at $out" >&2; return 1; }
}

# The two Samba NDR symbols live in a code path (smb://, nfs://) media_kit never
# takes, so they are stubbed. The stub object *must* be built for the same
# target as the dylib or ld refuses it with "building for 'iOS', but linking in
# object file built for 'macOS'".
build_stubs() { # $1 = out.o, rest = target flags
  local out="$1"; shift
  # TMPDIR is pinned into our scratch dir: clang creates an empty temp directory
  # per -arch job in $TMPDIR, named after the input basename, and never removes
  # it -- so a default-TMPDIR run leaks two `stubs-*` dirs per slice on top of
  # whatever this script leaks itself. Inside $TMPW the EXIT trap sweeps them up.
  TMPDIR="$TMPW" clang "$@" -c -o "$out" "$HERE/stubs.c"
}

# The thing that actually matters. hwdec registration in ffmpeg is by hwaccel
# name, not by decoder name, so this is the knob that decides whether AV1 gets
# hardware decode -- and it is the whole reason we are here.
verify() { # $1 = dylib
  local d="$1" c hits leaked
  echo
  echo "=== $(basename "$d") ==="
  echo "size:    $(stat -f%z "$d") bytes"
  echo "minos:   $(otool -l "$d" | grep -m1 minos | tr -d ' ' | cut -d: -f2)"
  leaked=$(nm -gU "$d" | grep -c ' _mpv_' || true)
  echo "_mpv_*:  $leaked exported"
  echo "other:   $(nm -gU "$d" | wc -l | tr -d ' ') total external (leaks if >> $leaked)"
  for c in h264_videotoolbox hevc_videotoolbox vp9_videotoolbox av1_videotoolbox; do
    hits=$(strings -a "$d" | grep -c "$c" || true)
    printf '%-20s %s\n' "$c" "$hits"
  done
  if [ "$(strings -a "$d" | grep -c av1_videotoolbox || true)" -eq 0 ]; then
    echo "!! no av1_videotoolbox in this dylib -- AV1 will still soft-decode" >&2
    return 1
  fi
}

# ------------------------------------------------------------------ macOS ----

link_macos() {
  local out=$OUTDIR/Mpv.macos
  local archs=(${MACOS_ARCHS:-arm64 x86_64})
  local archflags=() a stubs swift
  for a in "${archs[@]}"; do archflags+=(-arch "$a"); done
  swift=$(swift_lib macosx)

  echo "### macOS (${archs[*]}) ###"
  split_archives macos-arm64_x86_64
  stubs="$TMPW/stubs-macos.o"
  build_stubs "$stubs" "${archflags[@]}" -mmacosx-version-min="$MACOS_MIN"

  run_link "$out" "${archflags[@]}" -mmacosx-version-min="$MACOS_MIN" \
    -dynamiclib -o "$out" \
    -force_load "$MPV_ARCHIVE" \
    ${OTHER_ARCHIVES[@]+"${OTHER_ARCHIVES[@]}"} \
    ${OTHER_ARCHIVES[@]+"${OTHER_ARCHIVES[@]}"} \
    "$stubs" \
    -exported_symbols_list "$HERE/mpv.exports" \
    -framework Cocoa -framework IOKit -framework QuartzCore -framework CoreMedia \
    -framework AVFoundation -framework CoreFoundation -framework CoreAudio \
    -framework AudioUnit -framework AudioToolbox -framework OpenGL \
    -framework CoreVideo -framework VideoToolbox -framework CoreText \
    -framework CoreGraphics -framework Foundation -framework Metal \
    -framework Security -framework IOSurface -framework CoreServices \
    -L"$swift" -lswiftCompatibility56 \
    -lz -lbz2 -liconv -lc++ -lxml2 -lresolv \
    -install_name @rpath/Mpv.framework/Versions/A/Mpv
  verify "$out"
}

# -------------------------------------------------------------------- iOS ----

link_ios_slice() { # $1 = out, $2 = target triple, $3 = slice dir
  local out="$1" triple="$2" slice="$3"
  local sdk platform swift stubs
  case "$triple" in
    *-simulator)
      sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
      # iphoneos/ has no x86_64 slice of libswiftCompatibility56.a
      platform=iphonesimulator ;;
    *)
      sdk=$(xcrun --sdk iphoneos --show-sdk-path)
      platform=iphoneos ;;
  esac
  swift=$(swift_lib "$platform")

  echo "### iOS $triple ($slice) ###"
  split_archives "$slice"
  stubs="$TMPW/stubs-$slice.o"
  build_stubs "$stubs" -target "$triple" -isysroot "$sdk"

  run_link "$out" -target "$triple" -isysroot "$sdk" -dynamiclib -o "$out" \
    -force_load "$MPV_ARCHIVE" \
    ${OTHER_ARCHIVES[@]+"${OTHER_ARCHIVES[@]}"} \
    ${OTHER_ARCHIVES[@]+"${OTHER_ARCHIVES[@]}"} \
    "$stubs" \
    -exported_symbols_list "$HERE/mpv.exports" \
    -framework UIKit -framework Foundation -framework AVFoundation \
    -framework CoreAudio -framework AudioToolbox -framework CoreVideo \
    -framework CoreFoundation -framework CoreMedia -framework CoreGraphics \
    -framework CoreText -framework CoreImage -framework CoreServices \
    -framework Metal -framework MetalKit -framework VideoToolbox \
    -framework Security -framework QuartzCore -framework OpenGLES \
    -framework IOSurface -framework MobileCoreServices \
    -framework UniformTypeIdentifiers \
    -L"$swift" -lswiftCompatibility56 \
    -lz -lbz2 -liconv -lc++ -lxml2 -lresolv -lexpat \
    -install_name @rpath/Mpv.framework/Mpv
  verify "$out"
}

link_ios_device() {
  link_ios_slice "$OUTDIR/Mpv.ios-device" "arm64-apple-ios${IOS_MIN}" ios-arm64
}

link_ios_sim() {
  local slice=ios-arm64_x86_64-simulator
  # lipo'd from two single-arch links rather than one -arch pair, because the
  # swift compat path differs per slice and -target beats -arch.
  link_ios_slice "$OUTDIR/Mpv.ios-sim-arm64"  "arm64-apple-ios${IOS_MIN}-simulator"  "$slice"
  link_ios_slice "$OUTDIR/Mpv.ios-sim-x86_64" "x86_64-apple-ios${IOS_MIN}-simulator" "$slice"
  lipo -create "$OUTDIR/Mpv.ios-sim-arm64" "$OUTDIR/Mpv.ios-sim-x86_64" \
       -output "$OUTDIR/Mpv.ios-sim"
  verify "$OUTDIR/Mpv.ios-sim"
}

# ------------------------------------------------------------------ main ----

mkdir -p "$OUTDIR"
case "${1:-}" in
  macos)      link_macos ;;
  ios-device) link_ios_device ;;
  ios-sim)    link_ios_sim ;;
  ios)        link_ios_device; link_ios_sim ;;
  *)          sed -n '2,20p' "$HERE/relink.sh"; exit 2 ;;
esac

echo
echo "done -> $OUTDIR"

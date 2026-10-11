#!/bin/bash
# Put the tarball package.sh produced where media_kit's libs package will find
# it, so its Makefile skips the download.
#
#   ./stage-mpv.sh          # ios + macos, from $OUTDIR
#   ./stage-mpv.sh ios
#   ./stage-mpv.sh restore  # put the stock tarballs back and re-unpack
#
# The tarball we displace is moved to <name>.prev the first time, so `restore`
# and hand-inspection always stay possible.
#
# HOW THIS WORKS, because it is subtle: the Makefile's download rule is a target
# with no prerequisites --
#
#   .cache/xcframeworks/libmpv-xcframeworks-${VERSION}-ios-universal.tar.gz:
#           curl ... && shasum -a 256 -c <<< '<stock sha256>'
#
# -- so make only runs it when that file is *missing*. Drop our own tarball
# there first and neither the download nor the sha256 check happens. The
# stock sha is hard-coded and will not match ours; that is fine and expected.
#
# The Frameworks/ extract rule re-runs every build (its target name contains a
# literal '*', so make can never see it as up to date) and does
# `rm -rf Frameworks/*.xcframework` before unpacking -- which is exactly the
# cleanup that removes the stock Mpv and its ~6 siblings.
#
# Tarballs are read from $IOS_TARBALL / $MACOS_TARBALL; set either to an http(s)
# URL and it will be fetched instead, which is what CI does.
#
# MUST be run with bash, not zsh.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${WORK:-$HOME/Library/Caches/piliplus-mpvkit}
OUTDIR=${OUTDIR:-$WORK/out}
PILIPLUS=${PILIPLUS:-$(cd "$HERE/../../.." && pwd)}

IOS_VERSION=${IOS_VERSION:-v0.39.0}
MACOS_VERSION=${MACOS_VERSION:-v0.6.0}

IOS_TARBALL=${IOS_TARBALL:-$OUTDIR/libmpv-xcframeworks_${IOS_VERSION}_ios-universal-video-default.tar.gz}
MACOS_TARBALL=${MACOS_TARBALL:-$OUTDIR/libmpv-xcframeworks_${MACOS_VERSION}_macos-universal-video-default.tar.gz}

# The iOS libs package comes from the media_kit *fork* at a pinned commit, so
# which ~/.pub-cache/git/media-kit-<sha> checkout is live depends on
# pubspec.lock -- there is a second, unrelated media-kit checkout in there for
# media_kit_video. Read the ref rather than globbing and guessing.
lock_ref() { # $1 = package name in pubspec.lock
  awk -v pkg="  $1:" '
    index($0, pkg) == 1 { f = 1 }
    f && /resolved-ref:/ { gsub(/["\047 ]/, "", $2); print $2; exit }
  ' "$PILIPLUS/pubspec.lock"
}

lock_version() { # $1 = package name in pubspec.lock
  awk -v pkg="  $1:" '
    index($0, pkg) == 1 { f = 1 }
    f && /version:/ { gsub(/["\047 ]/, "", $2); print $2; exit }
  ' "$PILIPLUS/pubspec.lock"
}

require_dir() { # $1 = path
  [ -d "$1" ] || { echo "not a directory: $1" >&2; return 1; }
  echo "$1"
}

# Copy (or download) our tarball into the libs package's .cache under the exact
# filename its Makefile looks for, plus the unversioned symlink rule it also
# declares. Then run make to prove the package unpacks ours.
stage() { # $1 = libs package dir, $2 = tarball or URL, $3 = cached basename, $4 = symlink basename
  local pkg=$1 src=$2 cached=$3 link=$4 cache="$1/.cache/xcframeworks"
  mkdir -p "$cache"

  if [ -f "$src" ]; then
    echo "==> staging $(basename "$src")"
    cp -f "$src" "$cache/$cached.new"
  else
    echo "==> fetching $src"
    curl -fL --retry 3 "$src" -o "$cache/$cached.new"
  fi

  # Keep whatever we displace as <name>.prev, first time only. Without this the
  # tarball you were building against is gone the moment you try ours, and
  # there is no way back short of re-downloading the upstream release.
  if [ -f "$cache/$cached" ] && [ ! -f "$cache/$cached.prev" ] &&
     ! cmp -s "$cache/$cached" "$cache/$cached.new"; then
    echo "==> keeping previous tarball as $cached.prev"
    mv "$cache/$cached" "$cache/$cached.prev"
  fi
  mv -f "$cache/$cached.new" "$cache/$cached"
  ln -sfn "$cached" "$cache/$link"

  echo "==> make in $pkg"
  make -C "$pkg" >/dev/null 2>&1 || { make -C "$pkg"; exit 1; }

  local slice binary
  slice=$(ls "$pkg/Frameworks/Mpv.xcframework" | grep -v '\.plist$' | head -1)
  binary=$pkg/Frameworks/Mpv.xcframework/$slice/Mpv.framework/Mpv
  [ -f "$binary" ] || binary=$(dirname "$binary")/Versions/A/Mpv
  echo "    slice $slice"
  echo "      binary:           $(stat -f%z "$binary") bytes"
  echo "      av1_videotoolbox: $(strings -a "$binary" | grep -c av1_videotoolbox || true)"
  echo "    xcframeworks in Frameworks/: $(ls "$pkg/Frameworks" | grep -c xcframework)"
}

ios_pkg() {
  local ref
  ref=$(lock_ref media_kit_libs_ios_video)
  [ -n "$ref" ] || { echo "media_kit_libs_ios_video not in pubspec.lock" >&2; exit 1; }
  require_dir "$HOME/.pub-cache/git/media-kit-$ref/libs/ios/media_kit_libs_ios_video/ios"
}

macos_pkg() {
  local ver
  ver=$(lock_version media_kit_libs_macos_video)
  [ -n "$ver" ] || { echo "media_kit_libs_macos_video not in pubspec.lock" >&2; exit 1; }
  require_dir "$HOME/.pub-cache/hosted/pub.dev/media_kit_libs_macos_video-$ver/macos"
}

stage_ios() {
  local pkg
  pkg=$(ios_pkg)   # separate statement so `set -e` catches a lookup failure
  stage "$pkg" "$IOS_TARBALL" \
        "libmpv-xcframeworks-${IOS_VERSION}-ios-universal.tar.gz" \
        "libmpv-xcframeworks-ios-universal.tar.gz"
}

stage_macos() {
  local pkg
  pkg=$(macos_pkg)
  stage "$pkg" "$MACOS_TARBALL" \
        "libmpv-xcframeworks-${MACOS_VERSION}-macos-universal.tar.gz" \
        "libmpv-xcframeworks-macos-universal.tar.gz"
}

restore_one() { # $1 = libs package dir, $2 = cached basename
  local cache=$1/.cache/xcframeworks
  [ -f "$cache/$2.prev" ] || { echo "no previous tarball for $2" >&2; return 1; }
  mv -f "$cache/$2.prev" "$cache/$2"
  echo "==> restored previous $2"
  make -C "$1" >/dev/null 2>&1 || { make -C "$1"; exit 1; }
}

case "${1:-all}" in
  ios)     stage_ios ;;
  macos)   stage_macos ;;
  all)     stage_ios; stage_macos ;;
  restore) restore_one "$(ios_pkg)"   "libmpv-xcframeworks-${IOS_VERSION}-ios-universal.tar.gz"
           restore_one "$(macos_pkg)" "libmpv-xcframeworks-${MACOS_VERSION}-macos-universal.tar.gz" ;;
  *)       sed -n '2,10p' "$HERE/stage-mpv.sh"; exit 2 ;;
esac

echo
echo "done. next: ~/flutter/bin/flutter build ios --release --no-codesign --no-pub"

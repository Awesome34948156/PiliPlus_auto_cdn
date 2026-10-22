#!/bin/bash
# Download and unpack the 30 MPVKit xcframeworks that relink.sh links against.
#
# This is slow (about 1.8 GB) and only has to be done once per machine; the
# result is cached in $WORK and relink.sh reuses it.
#
#   ./fetch-xcframeworks.sh
#
# MUST be run with bash, not zsh.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${WORK:-$HOME/Library/Caches/piliplus-mpvkit}
ZIPS=$WORK/zips
XC=$WORK/xc

mkdir -p "$ZIPS" "$XC"

while read -r url; do
  [ -n "$url" ] || continue
  file=$(basename "$url")                 # gmp.xcframework.zip
  ver=$(basename "$(dirname "$url")")     # 3.8.11 -- the release tag lives in the path
  dir=${file%.zip}                        # gmp.xcframework -- the dir unzip creates
  # The version goes in the cache key. Keying on the bare filename meant a
  # version bump reused the old zip *and* skipped the unpack (the "$XC/$dir"
  # test below already passed), so a new release was never actually fetched.
  zip=$ZIPS/$ver-$file
  if [ ! -s "$zip" ]; then
    echo "==> $ver/$file"
    curl -fL --retry 3 --progress-bar "$url" -o "$zip.part"
    mv "$zip.part" "$zip"
  fi

  # Unpack only what is not already on disk, so re-running after a partial
  # failure does not redo everything. The stamp carries the version: keying the
  # guard on the bare dir meant a release bump downloaded the new zip and then
  # skipped the unpack (the dir already existed from the old release), so
  # relink.sh silently linked the previous binaries.
  if [ ! -d "$XC/$dir" ] || [ "$(cat "$XC/$dir/.mpvkit-version" 2>/dev/null)" != "$ver" ]; then
    echo "==> unpack $dir ($ver)"
    rm -rf "$XC/$dir"
    unzip -qo "$zip" -d "$XC"
    printf '%s' "$ver" > "$XC/$dir/.mpvkit-version"
  fi
done < "$HERE/xframeworks.txt"

echo
echo "xframeworks in $XC:"
ls "$XC" | wc -l | tr -d ' ' | sed 's/^/  /'

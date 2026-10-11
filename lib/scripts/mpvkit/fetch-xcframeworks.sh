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
  zip=$ZIPS/$(basename "$url")
  if [ ! -s "$zip" ]; then
    echo "==> $(basename "$url")"
    curl -fL --retry 3 --progress-bar "$url" -o "$zip.part"
    mv "$zip.part" "$zip"
  fi
done < "$HERE/xframeworks.txt"

# Unpack only the frameworks that are not already on disk, so re-running after a
# partial failure does not redo everything.
for zip in "$ZIPS"/*.xcframework.zip; do
  name=$(basename "$zip" .zip)
  if [ ! -d "$XC/$name" ]; then
    echo "==> unpack $name"
    unzip -qo "$zip" -d "$XC"
  fi
done

echo
echo "xframeworks in $XC:"
ls "$XC" | wc -l | tr -d ' ' | sed 's/^/  /'

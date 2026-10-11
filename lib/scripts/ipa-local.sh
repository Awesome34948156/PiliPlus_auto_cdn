#!/bin/bash
# Build an unsigned iOS IPA locally so it can be sideloaded with AltSign.
#
# This mirrors .github/workflows/ios.yml. It is bash rather than a call to
# lib/scripts/build.ps1 because pwsh is not installed on this machine; the
# version-numbering logic below is a faithful copy of that script.
#
#   ./ipa-local.sh
#
# Env:
#   FLUTTER     flutter binary (default ~/flutter/bin/flutter)
#   BUILD_DIR   real build output dir (default ~/Library/Caches/piliplus-build)
#   DEST        where the finished .ipa is copied (default iCloud Downloads)
#   SKIP_BUILD  set to reuse the existing build/ios/iphoneos/Runner.app
#
# Never run `flutter pub get` -- this fork depends on pub-cache patches that are
# applied out of band, and a re-fetch silently drops them.
set -euo pipefail
# 不要用 LC_ALL=C：`flutter build ios` 会拉起 pod install，而 CocoaPods 1.17 在
# Ruby 4.0 上会拿 `Dir.pwd`（ASCII-8BIT）去调 String#unicode_normalize，直接抛
#   Unicode Normalization not appropriate for ASCII-8BIT (Encoding::CompatibilityError)
# 位置是 cocoapods/config.rb:167 Pod::Config#installation_root。C 语言环境把 Ruby
# 的默认外部编码压成二进制，UTF-8 环境才是它要的。（2026-10-11 实测：同一句
# pod install，LC_ALL=C 失败、LC_ALL=en_US.UTF-8 成功。）
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export COPYFILE_DISABLE=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FLUTTER=${FLUTTER:-$HOME/flutter/bin/flutter}
BUILD_DIR=${BUILD_DIR:-$HOME/Library/Caches/piliplus-build}
DEST=${DEST:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads}

cd "$ROOT"

# ---- keep build output off iCloud -------------------------------------------
# iCloud tags everything under the synced Desktop, and codesign then refuses the
# framework with "resource fork, Finder information, or similar detritus not
# allowed". Note `flutter clean` deletes the symlink itself, not just its
# target -- if `build` has gone back to being a real directory, say so loudly.
if [ ! -L build ] || [ "$(readlink build)" != "$BUILD_DIR" ]; then
  if [ -e build ] && [ ! -L build ]; then
    echo "==> replacing real build/ directory (its contents are a stale iCloud build)"
    rm -rf build
  fi
  mkdir -p "$BUILD_DIR"
  ln -sfn "$BUILD_DIR" build
  echo "==> build -> $BUILD_DIR"
fi

# ---- version numbering, copied from lib/scripts/build.ps1 -------------------
version_name=$(sed -nE 's/^version:[[:space:]]*([0-9]+(\.[0-9]+)*).*/\1/p' pubspec.yaml | head -1)
[ -n "$version_name" ] || { echo "no version: line in pubspec.yaml" >&2; exit 1; }
version_code=$(git rev-list --count HEAD)
commit_hash=$(git rev-parse HEAD)

sed -i '' -E "s|^version:.*|version: ${version_name}+${version_code}|" pubspec.yaml
printf '{"pili.name":"%s","pili.code":%d,"pili.hash":"%s","pili.time":%d}\n' \
  "$version_name" "$version_code" "$commit_hash" "$(date +%s)" > pili_release.json

echo "==> version ${version_name}+${version_code} (${commit_hash:0:9})"
echo "    note: pubspec.yaml is now at that version, exactly as a real build leaves it"

# ---- make sure the pub-cache is holding our libmpv -------------------------
echo "==> staging libmpv"
bash "$HERE/mpvkit/stage-mpv.sh" ios | sed 's/^/    /'

# ---- build -----------------------------------------------------------------
if [ -z "${SKIP_BUILD:-}" ]; then
  echo "==> flutter build ios"
  "$FLUTTER" build ios --release --no-codesign \
    --dart-define-from-file=pili_release.json --no-pub
fi

app=$BUILD_DIR/ios/iphoneos/Runner.app
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }

# ---- what actually matters: is our libmpv in there, and is it the right one -
mpv=$app/Frameworks/Mpv.framework/Mpv
[ -f "$mpv" ] || { echo "no Mpv.framework in $app" >&2; exit 1; }
echo
echo "=== $app/Frameworks/Mpv.framework ==="
echo "binary:           $(stat -f%z "$mpv") bytes"
echo "platform:         $(vtool -show-build "$mpv" | awk '/platform/{print $2; exit}')  (2 = iOS, 7 = simulator)"
echo "minos:            $(otool -l "$mpv" | grep -m1 minos | tr -d ' ' | cut -d: -f2)"
echo "av1_videotoolbox: $(strings -a "$mpv" | grep -c av1_videotoolbox || true)"
echo "app size:         $(du -sh "$app" | cut -f1)"
[ "$(strings -a "$mpv" | grep -c av1_videotoolbox || true)" -gt 0 ] ||
  { echo "!! this app has a libmpv without AV1 hwaccel -- AV1 will still soft-decode" >&2; exit 1; }

# ---- package ---------------------------------------------------------------
# Payload must be a real directory so it lands as the archive's first entry; a
# canonical ipa starts with `Payload/` and some installers reject an archive
# whose first entry is `Payload/Runner.app/`. zip follows the inner symlink, so
# the app is still stored as real files.
ipa=PiliPlus_ios_${version_name}+${version_code}.ipa
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
ln -sf "$app" "$stage/Payload/Runner.app"

echo
echo "==> ad-hoc signing frameworks (AltSign needs this)"
find "$stage/Payload/Runner.app/Frameworks" -type d -name "*.framework" \
  -exec codesign --force --sign - --preserve-metadata=identifier,entitlements {} \;

echo "==> zip"
( cd "$stage" && zip -qr9 "$stage/$ipa" Payload )

mkdir -p "$DEST"
cp -f "$stage/$ipa" "$DEST/$ipa"
echo
echo "=== $DEST/$ipa"
echo "size:   $(stat -f%z "$DEST/$ipa") bytes"
echo "sha256: $(shasum -a 256 "$DEST/$ipa" | awk '{print $1}')"

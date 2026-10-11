#!/bin/bash
# Assemble the dylibs relink.sh produced into the Mpv.xcframework tarball that
# media_kit's libs package unpacks, and print the sha256 to pin it with.
#
#   ./package.sh ios     -> libmpv-xcframeworks_v0.39.0_ios-universal-video-default.tar.gz
#   ./package.sh macos   -> libmpv-xcframeworks_v0.6.0_macos-universal-video-default.tar.gz
#   ./package.sh all
#
# The tarball layout is exactly what the libs Makefile expects: one top-level
# directory holding Mpv.xcframework, consumed with `tar --strip-components 1 -C
# Frameworks`. The slice directory *names* are load bearing --
# create_framework_symlinks.sh derives `ios` / `ios-simulator` / `macos` from
# them by cutting on '-' -- so do not rename them.
#
# MUST be run with bash, not zsh.
set -euo pipefail
export LC_ALL=C
export COPYFILE_DISABLE=1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${WORK:-$HOME/Library/Caches/piliplus-mpvkit}
XC=${XC:-$WORK/xc}
OUTDIR=${OUTDIR:-$WORK/out}

# These versions are the media_kit_libs_* packages' own MPV_XCFRAMEWORKS_VERSION
# values. They name the tarball and the cached file it gets staged as; the
# tarball *contents* are ours either way.
IOS_VERSION=${IOS_VERSION:-v0.39.0}
MACOS_VERSION=${MACOS_VERSION:-v0.6.0}
MPV_VERSION=${MPV_VERSION:-0.41.0}
IOS_MIN=${IOS_MIN:-15.0}
MACOS_MIN=${MACOS_MIN:-12.0}

# ---------------------------------------------------------------- helpers ----

# Copy the public headers across from MPVKit's own Libmpv framework, so a
# Consumer of the framework still sees mpv/client.h etc.
copy_headers() { # $1 = source slice, $2 = destination framework dir
  local src=$XC/Libmpv.xcframework/$1/Libmpv.framework dest=$2
  if [ -d "$src/Headers" ]; then cp -R "$src/Headers" "$dest/Headers"; fi
  if [ -d "$src/Modules" ]; then cp -R "$src/Modules" "$dest/Modules"; fi
}

plist() { # $1 = dest, $2 = platform, $3 = minos, $4 = version
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Mpv</string>
	<key>CFBundleIdentifier</key><string>io.mpv.Mpv</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Mpv</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>$4</string>
	<key>CFBundleVersion</key><string>$4</string>
	<key>CFBundleSignature</key><string>????</string>
	<key>MinimumOSVersion</key><string>$3</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$2</string></array>
</dict>
</plist>
PLIST
}

# iOS slices are flat (Mpv.framework/Mpv); macOS slices are versioned
# (Mpv.framework/Versions/A/Mpv + symlinks), matching what upstream ships and
# what our -install_name expects.
mk_ios_slice() { # $1 = framework dir, $2 = binary, $3 = slice, $4 = platform
  local fw=$1
  mkdir -p "$fw"
  cp "$2" "$fw/Mpv"; chmod 755 "$fw/Mpv"
  plist "$fw/Info.plist" "$4" "$IOS_MIN" "$MPV_VERSION"
  copy_headers "$3" "$fw"
  codesign --force --sign - "$fw"
}

mk_macos_slice() { # $1 = framework dir, $2 = binary, $3 = slice
  local fw=$1 v=$1/Versions/A
  mkdir -p "$v/Resources"
  cp "$2" "$v/Mpv"; chmod 755 "$v/Mpv"
  plist "$v/Resources/Info.plist" MacOSX "$MACOS_MIN" "$MPV_VERSION"
  copy_headers "$3" "$v"
  ln -sfn A "$fw/Versions/Current"
  for r in Mpv Headers Modules Resources; do
    [ -e "$v/$r" ] && ln -sfn "Versions/Current/$r" "$fw/$r"
  done
  codesign --force --sign - "$fw"
}

xcframework_plist() { # $1 = dest, then one "identifier platform archs" per slice
  local dest=$1
  shift
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo '	<key>AvailableLibraries</key>'
    echo '	<array>'
    while [ $# -ge 3 ]; do
      echo '		<dict>'
      echo "			<key>BinaryPath</key><string>Mpv.framework/Mpv</string>"
      echo "			<key>LibraryIdentifier</key><string>$1</string>"
      echo '			<key>LibraryPath</key><string>Mpv.framework</string>'
      printf '			<key>SupportedArchitectures</key><array>'
      for a in $3; do printf '<string>%s</string>' "$a"; done
      echo '</array>'
      echo "			<key>SupportedPlatform</key><string>$2</string>"
      case "$1" in
        *simulator*) echo '			<key>SupportedPlatformVariant</key><string>simulator</string>' ;;
      esac
      echo '		</dict>'
      shift 3
    done
    echo '	</array>'
    echo '	<key>CFBundlePackageType</key><string>XFWK</string>'
    echo '	<key>XCFrameworkFormatVersion</key><string>1.0</string>'
    echo '</dict>'
    echo '</plist>'
  } > "$dest"
}

# --no-xattrs: this repo lives on an iCloud-synced Desktop and the file
# provider tags anything written there, which later breaks codesign.
tarball() { # $1 = top-level dir name, $2 = staging root
  local top=$1 root=$2 out=$OUTDIR/$1.tar.gz
  rm -f "$out"
  ( cd "$root" && tar --no-xattrs -czf "$out" "$top" )
  echo
  echo "$out"
  echo "size:   $(stat -f%z "$out") bytes"
  echo "sha256: $(shasum -a 256 "$out" | awk '{print $1}')"
}

# ------------------------------------------------------------------- iOS -----

package_ios() {
  local top=libmpv-xcframeworks_${IOS_VERSION}_ios-universal-video-default
  local stage=$OUTDIR/.stage-ios
  rm -rf "$stage"; mkdir -p "$stage/$top/Mpv.xcframework"

  echo "### iOS -> $top"
  mk_ios_slice "$stage/$top/Mpv.xcframework/ios-arm64/Mpv.framework" \
               "$OUTDIR/Mpv.ios-device" ios-arm64 iPhoneOS
  mk_ios_slice "$stage/$top/Mpv.xcframework/ios-arm64_x86_64-simulator/Mpv.framework" \
               "$OUTDIR/Mpv.ios-sim" ios-arm64_x86_64-simulator iPhoneSimulator
  xcframework_plist "$stage/$top/Mpv.xcframework/Info.plist" \
    ios-arm64 ios 'arm64' \
    ios-arm64_x86_64-simulator ios 'arm64 x86_64'

  # NOTE: deliberately Mpv-only. It is self-contained (ffmpeg, libass, placebos,
  # fontconfig... all static inside), and the pod has nothing else that needs
  # them; shipping the 6 stock siblings again would just bloat the app.
  tarball "$top" "$stage"
  rm -rf "$stage"
}

# ----------------------------------------------------------------- macOS -----

package_macos() {
  local top=libmpv-xcframeworks_${MACOS_VERSION}_macos-universal-video-default
  local stage=$OUTDIR/.stage-macos
  rm -rf "$stage"; mkdir -p "$stage/$top/Mpv.xcframework"

  echo "### macOS -> $top"
  mk_macos_slice "$stage/$top/Mpv.xcframework/macos-arm64_x86_64/Mpv.framework" \
                 "$OUTDIR/Mpv.macos" macos-arm64_x86_64
  xcframework_plist "$stage/$top/Mpv.xcframework/Info.plist" \
    macos-arm64_x86_64 macos 'arm64 x86_64'

  tarball "$top" "$stage"
  rm -rf "$stage"
}

# ------------------------------------------------------------------ main -----

mkdir -p "$OUTDIR"
case "${1:-}" in
  ios)   package_ios ;;
  macos) package_macos ;;
  all)   package_ios; package_macos ;;
  *)     sed -n '2,16p' "$HERE/package.sh"; exit 2 ;;
esac

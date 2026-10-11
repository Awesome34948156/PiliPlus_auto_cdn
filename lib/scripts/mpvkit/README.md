# mpvkit — a libmpv with `av1_videotoolbox`

## Why this exists

AV1 in PiliPlus plays on the CPU, always, even on silicon that has a dedicated
AV1 decoder (M4, A17 Pro and later). `--hwdec=auto` is set, mpv does try, and
then it quietly falls back to `libdav1d`.

The reason is in media_kit's bundled native libs: they ship an **ffmpeg 6.0**
build whose `--enable-hwaccel` list is

```
h263_videotoolbox h264_videotoolbox hevc_videotoolbox
mpeg1_videotoolbox mpeg2_videotoolbox mpeg4_videotoolbox vp9_videotoolbox
```

— no `av1_videotoolbox`. ffmpeg did not grow `libavcodec/videotoolbox_av1.c`
until 8.0, so no `media_kit_libs_*` version on pub.dev fixes this, including the
newest. 60 software-decoded frames per second is where a phone falls behind
real time, which is why it shows up as 1080P60 AV1 stutter specifically.

Note that ffmpeg's VideoToolbox support is registered as an **AVHWAccel**, not
as a decoder — so `ffmpeg -decoders | grep videotoolbox` is empty and tells you
nothing. Look for the hwaccel name in the binary instead.

## What this does

media_kit loads exactly one binary:

```dart
DynamicLibrary.open('Mpv.framework/Mpv')   // macos and ios alike
```

So only that one binary has to change. [MPVKit](https://github.com/mpvkit/MPVKit)
release `1.1.0-n9.0.2` already ships mpv 0.41 + ffmpeg n9.0.2 (which does have
the AV1 hwaccel) for macOS *and* iOS — but as **static** archives. This
directory relinks those thirty archives into one dynamic dylib. Nothing in
media_kit or PiliPlus changes.

## Pipeline

```sh
./fetch-xcframeworks.sh          # once per machine, ~1.8 GB into $WORK
./relink.sh ios                  # or: macos | ios-device | ios-sim
./package.sh ios                 # -> the tarball the libs Makefile wants
./stage-mpv.sh ios               # drop it into pub-cache, run make
../../../../flutter build ios ...
```

`stage-mpv.sh` is the part that makes it stick. media_kit's libs Makefile
downloads its prebuilt tarball into `.cache/xcframeworks/` and unpacks it into
`Frameworks/`; put our tarball at that path first and the download rule never
runs. See the header of `stage-mpv.sh` for why the hard-coded sha256 check never
fires, and `stage-mpv.sh restore` for the way back.

Then build with `~/flutter/bin/flutter ... --no-pub`. Never run `flutter pub
get`: the pub-cache patches this fork depends on are applied out of band.

## Why the tarball contains only `Mpv.xcframework`

Ours is self-contained — ffmpeg, libass, libplacebo, shaderc, MoltenVK,
fontconfig, gnutls and the rest are all linked *into* it. Upstream ships Mpv
plus six sibling frameworks because its Mpv is thin; ours is not. The iOS pod
is `vendored_frameworks = 'Frameworks/*.xcframework'` (a glob) and has nothing
else that references them, so shipping one framework instead of seven is both
correct and a large size win. **Do not add the siblings back.**

## Version correspondence

| | version | where it comes from |
|---|---|---|
| mpv | 0.41.0 | MPVKit `1.1.0-n9.0.2` |
| ffmpeg | n9.0.2 | MPVKit `1.1.0-n9.0.2` |
| iOS tarball | `v0.39.0` | `media_kit_libs_ios_video`'s `MPV_XCFRAMEWORKS_VERSION` |
| macOS tarball | `v0.6.0` | `media_kit_libs_macos_video`'s `MPV_XCFRAMEWORKS_VERSION` |

Those two version numbers only name the files; the contents are always ours.
They have to keep matching the Makefiles the packages actually ship, so if a
`media_kit_libs_*` bump is ever taken, change `IOS_VERSION` / `MACOS_VERSION`
to match (they are overridable as environment variables).

## Traps already paid for

- **`-force_load` only Libmpv.** Force-loading a merge of all thirty archives
  yields "duplicate symbols" (`_ff_vk_*` lands in four different `vulkan.o`,
  `_aes_v8_xts_decrypt` inside Libcrypto). Everything else is listed normally,
  **twice**, which is how the archive ordering resolves.
- **`-exported_symbols_list` with `_mpv_*`.** Without it the dylib exports all
  17,370 ffmpeg/gnutls/placebo globals. Upstream's own Mpv exports exactly 53;
  we export 54 because `mpv_get_time_ns` is new in 0.41.
- **stubs must be built for the same target as the link.** `misc/stubs.c`
  defines two Samba NDR symbols reachable only through `smb://` / `nfs://`.
  Compiled for macOS and linked into an iOS dylib, ld fails with *"building for
  'iOS', but linking in object file built for 'macOS'"*.
- **Swift compat path differs per iOS slice.** `.../usr/lib/swift/iphoneos/` has
  no x86_64, so the simulator link needs `iphonesimulator/`. That is also why
  the simulator dylib is two single-arch links plus `lipo`, rather than one
  `-arch arm64 -arch x86_64` pass.
- **Pin `-mmacosx-version-min`.** With nothing set, clang stamps the dylib with
  the SDK's own version (minos 27.0 on a macOS 27 SDK) and the framework then
  refuses to load on anything older. Keep it in step with
  `MACOSX_DEPLOYMENT_TARGET`.
- **Run these with `bash`, not `zsh`.** zsh does not word-split unquoted
  variables, which silently collapses the archive list into a single argument.
- **Keep the output off iCloud.** Anything written under the iCloud-synced
  Desktop picks up file-provider xattrs, and `codesign` later refuses it with
  *"resource fork, Finder information, or similar detritus not allowed"*.
  `$WORK` defaults to `~/Library/Caches/piliplus-mpvkit` for this reason.

## Verifying it actually works

`--vo=null` proves nothing — it never touches `vo=libmpv`, the video output
media_kit uses. A real check needs a GL context and the render API. The
end-to-end signal that matters is in the app: 播放信息 → `hwdec` should read
`videotoolbox` for an AV1 stream (it reads `no` with the stock libs), and AVC /
HEVC must still read `videotoolbox*` after the swap.

`relink.sh` self-checks each dylib it produces: exported symbol count and the
presence of the four `*_videotoolbox` hwaccel names.

`verify-render.sh` is the real check, and the one to reach for whenever the render
path itself is in question:

```sh
bash verify-render.sh /tmp/bbb_av1_1080.mp4   # dylib defaults to $WORK/out/Mpv.macos
```

It compiles `mpvgl.c` against the MPVKit headers — the same build as the dylib, so
the API cannot drift — and runs it. mpvgl.c stands up a CGL 3.2 core context and
calls `mpv_render_context_create(MPV_RENDER_API_TYPE_OPENGL)` with no
`MPV_RENDER_PARAM_HW_FRAMES`, which is what media_kit's `TextureHW` does, then
renders into an FBO and reads the centre pixel back. Pass = **non-black readback,
0 render errors, `hwdec-current: videotoolbox`**, and the exit code is the verdict:

```
frames rendered through vo=libmpv + GL render API: 30 (errors: 0)
centre pixel readback: R=86 G=82 B=26 A=255  (non-black -> real frame)
hwdec-current: videotoolbox
```

`mpvtest.c` is the cheap first check (`--vo=null`): good for "does it even load and
find the hwaccel", but it reports `videotoolbox-copy` — a copy-back, not the
zero-copy path the real VO takes — so it cannot tell you the render path works.

## macOS status

Verified 2026-10-11 through a full `flutter build macos --release` (179 MB app,
`codesign --verify` clean) and a launch: the app maps our 86 MB
`Mpv.framework/Versions/A/Mpv` at startup, and the stock bundle's six sibling
frameworks (`Avcodec`, `Avformat`, `Ass`, …) are gone as intended. The
hand-swapped-binary hack that used to be needed on macOS is no longer — this is
the proper mechanism.

Not yet checked: actual AV1 playback in the GUI (播放信息 → `hwdec`). The
render path itself was proven separately with a real CGL context. If something
is wrong, `stage-mpv.sh restore` puts the stock tarball back.

**Changing the *set* of vendored frameworks needs a `pod install`.** CocoaPods
expands `vendored_frameworks = 'Frameworks/*.xcframework'` once, when it
generates the Pods project, and then rsyncs each slice by name at build time.
Swap the tarball for one with fewer frameworks and an existing `macos/Pods`
still tries to copy `Ass.xcframework` and friends:

```
rsync: .../media_kit_libs_macos_video/macos/Frameworks/Ass.xcframework/...:
       (l)stat: No such file or directory
error: unexpected service error: The Xcode build system has crashed.
```

That is stale Pods state, not a bad framework. `cd macos && pod install` and
build again. CI is unaffected because it always starts with a fresh checkout
and runs `pod install` after the staging step.

## CI

`lib/scripts/patch.ps1` runs `flutter pub get` and then patches packages in
`~/.pub-cache`. That is where the tarball gets fetched from a GitHub release
asset and staged, because CI always starts with an empty pub-cache. See
`patch.ps1`; the staging logic itself is `stage-mpv.sh`, which accepts an
`IOS_TARBALL` / `MACOS_TARBALL` URL.

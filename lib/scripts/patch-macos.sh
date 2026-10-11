#!/bin/bash
# The macOS half of patch.ps1, in bash -- the machine that builds PiliPlus locally
# has no pwsh, so refreshing the Flutter SDK out of the repo otherwise means
# re-deriving patch.ps1 by hand every time.
#
# Keep this in step with patch.ps1: the two patch lists and their order below are
# copied from patch.ps1 lines 125-132 and 212-214 and must stay identical. Only the
# macOS path is ported -- that is the only one this machine can run.
#
# Usage:
#   bash patch-macos.sh --check      does every SDK patch line up with this SDK?
#   bash patch-macos.sh              apply the 22 SDK patches to $FLUTTER_ROOT
#   bash patch-macos.sh --material   ALSO refresh and patch material_ui (destructive)
#
# FLUTTER_ROOT defaults to ~/flutter.
#
# --check is the one to run first, and it is what makes re-running safe: it reports
# each patch as `would apply`, `already` (reverse-applies, i.e. this SDK already
# carries it) or `NEITHER`, and only the last is a failure. A plain
# `git apply --check` would call every patch on an already-patched SDK a failure,
# which tells you nothing.
#
# KNOWN DIVERGENCE (found 2026-10-11, and the reason --check earns its keep):
# `scroll_position.patch` reports NEITHER. The SDK file is not stale -- it was
# hand-edited *after* the patch went on, and the edit is not in the patch:
#
#   SDK now:  if (_userScrollDirection == ScrollDirection.idle ||
#                (newPixels != setPixels(newPixels) && newPixels >= 0))
#   patch:    if (newPixels != setPixels(newPixels) ||
#                _userScrollDirection == ScrollDirection.idle)
#
# So a from-scratch run of this script reproduces the patch's condition, not the
# SDK's. That is also why moving the SDK tag is done by carrying the working tree
# forward (see the commit that did 3.47.6 -> 3.47.7): re-applying patches from
# scratch would silently revert this edit. Decide which side is right before
# "fixing" anything -- do not reach for `git reset`.
#
# !! --material is destructive, and reads the same in patch.ps1: its material flow
# is `rm -rf material_ui-* && flutter pub get && git apply`, because the patches
# only apply to a *pristine* package. That deletes the patched copy in the pub
# cache first. On this machine material_ui-<ver> is a plain extracted package with
# no .git, so those edits have no diff and no backup -- once pub get rewrites them
# they are unrecoverable. Pass --material only to rebuild that patch set from
# scratch; it is never needed just to move the SDK.
#
# MUST be run with bash, not zsh -- see the note in mpvkit/relink.sh.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
FLUTTER_ROOT=${FLUTTER_ROOT:-$HOME/flutter}
PUBCACHE=${PUBCACHE:-$HOME/.pub-cache}

# patch.ps1 lines 125-132, same order.
SDK_PATCHES=(
  modal_barrier text_selection mouse_cursor image_anim layout_builder
  navigation_drawer popup_menu fab null_safety_for_selectable_region
  selectable_region editable_text text_field scroll_position scrollable
  scrollable_gesture draggable_scrollable_sheet scaffold text text_painter
  sliver refresh_indicator double_tap_gesture
)

# patch.ps1 lines 212-214, same order.
MATERIAL_PATCHES=(
  material/modal_barrier_material material/navigation_drawer material/popup_menu
  material/fab material/text_field material/scaffold material/refresh_indicator
  material/tabs
)

CHECK=0
WITH_MATERIAL=0
for arg in "$@"; do
  case $arg in
    --check)    CHECK=1 ;;
    --material) WITH_MATERIAL=1 ;;
    -h|--help)  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# $1 = directory to apply in, rest = patch names relative to lib/scripts.
# Every apply is a plain `git apply <abs path>` at the default -p1, no extra flags
# -- the same call patch.ps1 makes.
apply_group() {
  local dir=$1; shift
  local p f rc=0
  for p in "$@"; do
    f="$HERE/$p.patch"
    [ -f "$f" ] || { echo "  MISSING      $p.patch" >&2; rc=1; continue; }
    if ( cd "$dir" && git apply --check "$f" ) 2>/dev/null; then
      if [ "$CHECK" = 1 ]; then
        echo "  would apply  $p"
      else
        ( cd "$dir" && git apply "$f" ) && echo "  applied      $p"
      fi
    elif ( cd "$dir" && git apply --check --reverse "$f" ) 2>/dev/null; then
      echo "  already      $p"
    else
      echo "  NEITHER      $p" >&2
      rc=1
    fi
  done
  return $rc
}

matdir() { ls -d "$PUBCACHE"/hosted/pub.dev/material_ui-* 2>/dev/null | tail -1; }

[ -d "$FLUTTER_ROOT/.git" ] || {
  echo "no Flutter checkout at $FLUTTER_ROOT (override with FLUTTER_ROOT=)" >&2
  exit 2
}
printf 'Flutter SDK: %s (%s)\n' "$FLUTTER_ROOT" \
  "$(git -C "$FLUTTER_ROOT" describe --tags 2>/dev/null || echo 'no tag')"

rc=0
[ "$CHECK" = 1 ] && echo "(dry run -- nothing is written)"

echo
echo "SDK patches (cwd = $FLUTTER_ROOT):"
apply_group "$FLUTTER_ROOT" "${SDK_PATCHES[@]}" || rc=1

if [ "$WITH_MATERIAL" = 1 ]; then
  echo
  echo "material_ui patches (cwd = <pub cache>/material_ui-*):"
  if [ "$CHECK" = 1 ]; then
    d=$(matdir)
    if [ -z "$d" ]; then
      echo "  no material_ui in $PUBCACHE -- run 'flutter pub get' first" >&2
      rc=1
    else
      apply_group "$d" "${MATERIAL_PATCHES[@]}" || rc=1
    fi
  else
    # patch.ps1's flow: the patches want a pristine package, so the cached one is
    # deleted and re-fetched before patching. See the warning at the top.
    echo "  ! deleting $(matdir | xargs -n1 basename 2>/dev/null | tr '\n' ' ')" >&2
    rm -rf "$PUBCACHE"/hosted/pub.dev/material_ui-*
    ( cd "$REPO" && "$FLUTTER_ROOT/bin/flutter" pub get ) || exit 1
    d=$(matdir)
    [ -n "$d" ] || { echo "  material_ui still missing after pub get" >&2; exit 1; }
    apply_group "$d" "${MATERIAL_PATCHES[@]}" || rc=1
  fi
fi

echo
if [ "$rc" = 0 ]; then
  echo "OK"
else
  echo "FAILED -- see NEITHER above" >&2
  echo "NEITHER = the patch applies in neither direction, so it does not describe the" >&2
  echo "file it points at. Usual cause: hand-edits on top of the patch (known case in" >&2
  echo 'the header comment). Do not "fix" it with a git reset.' >&2
fi
exit $rc

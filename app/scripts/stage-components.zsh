#!/bin/zsh
# Builds the five files the app puts into the engine, from this checkout as it is, and stages them
# in app/prebuilt/ with a STAMP (the commit and each file's sha256). The app's build takes them
# from there. Starts nothing of Wine; it compiles (minutes), so not while the game runs.
#
#   app/scripts/stage-components.zsh
#
# They are built, never taken from an engine: what sits in work/engine may be older than the
# patches (on 2026-11-23 its driver still had a patch that was taken out again). QL_WORK names
# the work folder with the toolchain and Wine's source, as for scripts/ql.zsh build.
#
#   winemac.so, win32u.so   Wine's Mac driver and win32u with patches/wine
#   libglmt.dylib           glmt/
#   opengl32.so, opengl32.dll   Wine's opengl32 with patches/wine/0004 (the pair)
set -euo pipefail
repo="${0:A:h:h:h}"
source "$repo/scripts/common.zsh"
mac_only
need_engine
out="$repo/app/prebuilt"

say "1/3 glmt (tests, the library, shaders, pixel checks)"
mkdir -p "$LOGS"
"$repo/scripts/build-glmt.zsh" >"$LOGS/build-glmt.log" 2>&1 || { tail -30 "$LOGS/build-glmt.log" >&2; die "glmt does not build: $LOGS/build-glmt.log"; }
say "2/3 the Mac driver and win32u with patches/wine"
"$repo/scripts/build-winemac.zsh"
say "3/3 opengl32, both halves"
"$repo/scripts/opengl32.zsh" build

rm -rf "$out.new"
mkdir -p "$out.new"
for f in winemac.so win32u.so libglmt.dylib opengl32.so opengl32.dll; do
  [[ -f "$STAGE/$f" ]] || die "no $f in $STAGE"
  cp -f "$STAGE/$f" "$out.new/$f"
done
for f in winemac.so win32u.so libglmt.dylib opengl32.so; do
  [[ "$(lipo -archs "$out.new/$f" 2>/dev/null)" == *arm64* ]] || die "$f is not an arm64 Mach-O file"
done
grep -q -a 'libglmt.dylib' "$out.new/winemac.so" || die "winemac.so has no glmt glue"
grep -q -a 'fullscreen space' "$out.new/winemac.so" || die "winemac.so has no full-screen Space (patches/wine/0003)"
! grep -q -a 'WINE_GLMT_CAPTURE' "$out.new/winemac.so" || die "winemac.so still has the display capture that was taken out (a stale build)"
grep -q -a 'WINE_GLMT_BATCH' "$out.new/opengl32.so" || die "opengl32.so has no batching (patches/wine/0004)"
[[ "$(file -b "$out.new/opengl32.dll")" == *PE32\ executable*386* ]] || die "opengl32.dll is not a 32-bit Windows DLL"

commit=$(git -C "$repo" rev-parse HEAD)
[[ -z "$(git -C "$repo" status --porcelain -- glmt patches ci scripts)" ]] || commit="$commit with changes"
{
  print -r -- "commit $commit"
  print -r -- "engine $ENGINE_NAME wine $ENGINE_WINE"
  for f in winemac.so win32u.so libglmt.dylib opengl32.so opengl32.dll; do print -r -- "$(sha256_of "$out.new/$f")  $f"; done
} >"$out.new/STAMP"
rm -rf "$out"
mv "$out.new" "$out"
say "staged in app/prebuilt:"
cat "$out/STAMP"

#!/bin/zsh
# Wine's opengl32 with patches/wine/0004 (OpenGL calls of the game in batches): builds the pair,
# the unix library opengl32.so and the 32-bit opengl32.dll, and puts it into the engine or takes
# it out again. The two have to match: the DLL calls a unix function the engine's own opengl32.so
# does not have, so they go in and out together, and the engine's own are kept as *.stock.
#
#   scripts/opengl32.zsh build      compile and stage the pair (no Wine is started)
#   scripts/opengl32.zsh install    the staged pair into the engine (no session may run)
#   scripts/opengl32.zsh remove     the engine's own pair back
#   scripts/opengl32.zsh status
#
# With the pair in, batching is still off: QL_BATCH=1 (scripts/ql.zsh) turns it on for the game.
# Every 32-bit program of the bottle loads this DLL, Steam's too; without QL_BATCH it makes its
# calls one by one as the engine's own does.
set -euo pipefail
here="${0:A:h}"
source "$here/common.zsh"
mac_only
need_engine

PE32_DIR="$ENGINE/lib/wine/i386-windows"
so="$UNIX_DIR/opengl32.so" dll="$PE32_DIR/opengl32.dll"

installed() { [[ -f "$so.stock" && -f "$dll.stock" ]] && grep -q -a 'WINE_GLMT_BATCH' "$so"; }

case "${1:-}" in
  build)
    "$here/build-winemac.zsh"   # the source with patches/wine, configured
    export MINGW_DIR="$WORK/toolchains/llvm-mingw" SRC="$WORK/src/wine-engine" BUILD="$WORK/build/wine"
    export MACOSX_DEPLOYMENT_TARGET=26.4 WINE_SHALLOW=1
    mkdir -p "$LOGS" "$STAGE"
    say "compiling opengl32.so and the 32-bit opengl32.dll (the first time this builds Wine's import libraries too)"
    "$ROOT/ci/wine.zsh" opengl32 >"$LOGS/build-opengl32.log" 2>&1 || { tail -40 "$LOGS/build-opengl32.log" >&2; die "it does not build: $LOGS/build-opengl32.log"; }
    cp -f "$BUILD/dlls/opengl32/opengl32.so" "$STAGE/opengl32.so"
    cp -f "$BUILD/dlls/opengl32/i386-windows/opengl32.dll" "$STAGE/opengl32.dll"
    say "staged opengl32.so ($(sha256_of "$STAGE/opengl32.so" | cut -c1-12)) and opengl32.dll ($(sha256_of "$STAGE/opengl32.dll" | cut -c1-12))" ;;
  install)
    bottle_running && die "a Wine session of the bottle runs: end it first (scripts/ql.zsh stop)"
    [[ -f "$STAGE/opengl32.so" && -f "$STAGE/opengl32.dll" ]] || die "nothing staged: scripts/opengl32.zsh build"
    [[ -f "$so" && -f "$dll" ]] || die "the engine has no $so or no $dll"
    [[ -f "$so.stock" ]] || cp -p "$so" "$so.stock"
    [[ -f "$dll.stock" ]] || cp -p "$dll" "$dll.stock"
    cp -f "$STAGE/opengl32.so" "$so.new"
    xattr -d com.apple.quarantine "$so.new" 2>/dev/null || true
    codesign --force --sign - "$so.new" 2>/dev/null
    cp -f "$STAGE/opengl32.dll" "$dll.new"
    mv -f "$so.new" "$so"
    mv -f "$dll.new" "$dll"
    say "installed opengl32.so ($(sha256_of "$so" | cut -c1-12)) and the 32-bit opengl32.dll ($(sha256_of "$dll" | cut -c1-12)); QL_BATCH=1 turns batching on for the game" ;;
  remove)
    bottle_running && die "a Wine session of the bottle runs: end it first (scripts/ql.zsh stop)"
    [[ ! -f "$so.stock" ]] || mv -f "$so.stock" "$so"
    [[ ! -f "$dll.stock" ]] || mv -f "$dll.stock" "$dll"
    say "the engine has its own opengl32 again" ;;
  status)
    installed && say "opengl32: the batching pair is in the engine ($(sha256_of "$so" | cut -c1-12), $(sha256_of "$dll" | cut -c1-12))" || say "opengl32: the engine's own" ;;
  *) die "usage: opengl32.zsh build | install | remove | status" ;;
esac

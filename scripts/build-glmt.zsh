#!/bin/zsh
# Build glmt and stage it.
#
#   scripts/build-glmt.zsh             on the Mac: the tests, libglmt.dylib (arm64) into work/stage,
#                                      and the shaders checked with Metal's compiler
#   scripts/build-glmt.zsh --install   and into the engine (scripts/install-glmt.zsh --glmt)
#   scripts/build-glmt.zsh --test      the front end's tests only; these run on any system
#
# The Mac driver that loads it (winemac.so with patches/wine) is scripts/build-winemac.zsh.
set -euo pipefail
source "${0:A:h}/common.zsh"

case "${1:-}" in
  --test) exec make -C "$ROOT/glmt" test ;;
  "" | --install) ;;
  *) die "usage: build-glmt.zsh [--install | --test]" ;;
esac
mac_only
make -C "$ROOT/glmt" test
make -C "$ROOT/glmt"
# the shaders through Metal's compiler now: one that does not compile would otherwise show up only
# at the game's start, as no OpenGL
make -C "$ROOT/glmt" shadercheck
# and the library itself for a few frames on a layer without a window, without Wine
make -C "$ROOT/glmt" smoke
mkdir -p "$STAGE"
cp -f "$ROOT/glmt/build/libglmt.dylib" "$STAGE/libglmt.dylib"
say "staged libglmt.dylib ($(sha256_of "$STAGE/libglmt.dylib" | cut -c1-12))"
[[ "${1:-}" != --install ]] || "${0:A:h}/install-glmt.zsh" --glmt

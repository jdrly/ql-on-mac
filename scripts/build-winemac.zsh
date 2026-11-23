#!/bin/zsh
# Build the engine's Mac driver and its win32u with patches/wine on this Mac and stage them:
# work/stage/winemac.so and work/stage/win32u.so.
# Starts nothing of Wine. The first run downloads the toolchain (llvm-mingw, pinned) and Wine's
# source at the engine's commit (one commit, about 75 MB), configures a Wine tree and compiles for
# some minutes on every core; a later run compiles only what changed.
#
#   scripts/build-winemac.zsh            does nothing if the staged file is from this patch
#   scripts/build-winemac.zsh --force    builds again
#
# Needs Xcode's command line tools and Homebrew's bison, freetype and pkgconf (it says so if one is
# missing, and installs nothing). Homebrew's gnutls and sdl2-compat are used if they are there;
# nothing in the Mac driver depends on them.
set -euo pipefail
source "${0:A:h}/common.zsh"
mac_only

force=${1:-}
[[ -z "$force" || "$force" == --force ]] || die "usage: build-winemac.zsh [--force]"

# What Mach9's release build and my Wine fork's CI use (jdrly/wine, .github/workflows/gw2.yml)
LLVM_MINGW_VERSION=20261104
LLVM_MINGW_SHA256=66cbd5178c4a71b0d473e68ede172f8eb7d15d023e67f39201d0a69e21f6bf3c
LLVM_MINGW_FILE="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal.tar.xz"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW_FILE"
WINE_URL=https://github.com/jdrly/wine   # has the engine's commit; athei rewrote his own branch

export MINGW_DIR="$WORK/toolchains/llvm-mingw"
export SRC="$WORK/src/wine-engine"       # the engine's commit plus the patch, nothing else
export BUILD="$WORK/build/wine"
export MACOSX_DEPLOYMENT_TARGET=26.4     # the engine's
export WINE_SHALLOW=1
log="$LOGS/build-winemac.log"
out="$BUILD/dlls/winemac.drv/winemac.so"

# the staged file is current if it was built from this patch, this commit and this build script
stamp="$ENGINE_WINE $(cat "$ROOT"/patches/wine/*.patch "$ROOT/ci/wine.zsh" | shasum -a 256 | cut -d' ' -f1)"
if [[ -z "$force" && -f "$STAGE/winemac.so" && -f "$STAGE/win32u.so" && "$(cat "$STAGE/winemac.stamp" 2>/dev/null)" == "$stamp" ]]; then
  say "winemac.so and win32u.so are staged and current ($(sha256_of "$STAGE/winemac.so" | cut -c1-12), $(sha256_of "$STAGE/win32u.so" | cut -c1-12))"
  exit 0
fi

xcrun --find clang >/dev/null 2>&1 || die "no Xcode command line tools: xcode-select --install"
command -v brew >/dev/null || die "no Homebrew (https://brew.sh): Wine's configure needs its bison, freetype and pkgconf"
missing=()
for f in bison freetype pkgconf; do brew list --versions $f >/dev/null 2>&1 || missing+=($f); done
(( ${#missing} == 0 )) || die "Homebrew lacks: $missing. Run: brew install $missing"
without=()
for f in gnutls sdl2-compat; do brew list --versions $f >/dev/null 2>&1 || without+=(${f%2-compat}); done
export WINE_WITHOUT="$without"

mkdir -p "$LOGS" "$DOWNLOADS" "$STAGE"
: >"$log"
# run <what> <command...>: the command's output goes to the log; on failure, the log's end here
run() {
  local what=$1; shift
  say "$what"
  print -r -- "=== $(date '+%F %T') $what: $*" >>"$log"
  "$@" >>"$log" 2>&1 || { tail -40 "$log" >&2; die "$what failed: the whole output is in $log"; }
}

if [[ ! -x "$MINGW_DIR/bin/i686-w64-mingw32-clang" ]]; then
  archive="$DOWNLOADS/$LLVM_MINGW_FILE"
  if [[ "$(sha256_of "$archive")" != "$LLVM_MINGW_SHA256" ]]; then
    say "downloading llvm-mingw $LLVM_MINGW_VERSION (the compiler for Wine's Windows side)"
    curl -fL --retry 3 -o "$archive.part" "$LLVM_MINGW_URL"
    [[ "$(sha256_of "$archive.part")" == "$LLVM_MINGW_SHA256" ]] || die "the download's sha256 is not $LLVM_MINGW_SHA256: $archive.part"
    mv -f "$archive.part" "$archive"
  fi
  rm -rf "$MINGW_DIR"
  mkdir -p "$MINGW_DIR"
  run "unpacking llvm-mingw" tar -xf "$archive" -C "$MINGW_DIR" --strip-components 1
  xattr -dr com.apple.quarantine "$MINGW_DIR" 2>/dev/null || true
fi

if [[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$ENGINE_WINE" ]]; then
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init --quiet
  run "fetching Wine's source at the engine's commit ($ENGINE_WINE[1,11])" \
    git -C "$SRC" fetch --quiet --depth 1 "$WINE_URL" "$ENGINE_WINE"
  git -C "$SRC" checkout --quiet --detach FETCH_HEAD
fi

run "applying patches/wine" "$ROOT/ci/wine.zsh" prepare "$ENGINE_WINE" "$ROOT/patches/wine"
if [[ ! -f "$BUILD/Makefile" || -n "$force" ]]; then
  run "configuring Wine (a few minutes the first time${WINE_WITHOUT:+; without $WINE_WITHOUT})" "$ROOT/ci/wine.zsh" configure
fi
run "compiling winemac.so and win32u.so" "$ROOT/ci/wine.zsh" build

cp -f "$out" "$STAGE/winemac.so"
cp -f "$BUILD/dlls/win32u/win32u.so" "$STAGE/win32u.so"
print -r -- "$stamp" >"$STAGE/winemac.stamp"
say "staged winemac.so ($(sha256_of "$STAGE/winemac.so" | cut -c1-12)) and win32u.so ($(sha256_of "$STAGE/win32u.so" | cut -c1-12))"

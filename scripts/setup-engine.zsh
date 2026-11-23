#!/bin/zsh
# Download the pinned arm64 Wine engine (Mach9, see common.zsh), check it and unpack it into
# work/engine. Starts nothing. Then puts my builds back in, if they are staged
# (scripts/install-glmt.zsh).
#
#   scripts/setup-engine.zsh            does nothing if the engine is already there
#   scripts/setup-engine.zsh --force    unpacks it again (a clean engine, then install-glmt)
set -euo pipefail
source "${0:A:h}/common.zsh"
mac_only

force=${1:-}
[[ -z "$force" || "$force" == --force ]] || die "usage: setup-engine.zsh [--force]"
if engine_ok && [[ -z "$force" ]]; then
  say "the engine ($ENGINE_NAME) is in place"
  exit 0
fi
bottle_running && die "a Wine session of the bottle runs: end it first (scripts/ql.zsh stop)"

archive="$DOWNLOADS/${ENGINE_URL:t}"
mkdir -p "$DOWNLOADS"
if [[ "$(sha256_of "$archive")" != "$ENGINE_SHA256" ]]; then
  say "downloading $ENGINE_NAME ($((ENGINE_SIZE / 1048576)) MB)"
  curl -fL --retry 3 -o "$archive.part" "$ENGINE_URL"
  [[ "$(sha256_of "$archive.part")" == "$ENGINE_SHA256" ]] || die "the download's sha256 is not $ENGINE_SHA256: $archive.part"
  mv -f "$archive.part" "$archive"
fi

say "unpacking into $ENGINE"
rm -rf "$ENGINE.new"
mkdir -p "$ENGINE.new"
tar -xJf "$archive" -C "$ENGINE.new" --strip-components 1
# a browser's download carries the quarantine attribute, and tar copies it onto every file
xattr -dr com.apple.quarantine "$ENGINE.new" 2>/dev/null || true
# its SDK and Wine's own tests are not needed to run it
rm -rf "$ENGINE.new/include" "$ENGINE.new/lib/wine/tests" "$ENGINE.new/lib/wine/x86_64-windows" "$ENGINE.new/share/man"
[[ -x "$ENGINE.new/bin/wine" && -f "$ENGINE.new/lib/wine/aarch64-unix/winemac.so" && -f "$ENGINE.new/lib/wine/i386-windows/opengl32.dll" ]] ||
  die "the archive does not unpack to the engine expected (bin/wine, the arm64 Mac driver, the i386 opengl32)"
print -r -- "$ENGINE_SHA256" >"$ENGINE.new/.ql-engine"
rm -rf "$ENGINE"
mv "$ENGINE.new" "$ENGINE"
say "engine: $ENGINE_NAME (Wine $ENGINE_WINE[1,11])"

if [[ -f "$STAGE/winemac.so" && -f "$STAGE/win32u.so" && -f "$STAGE/libglmt.dylib" ]]; then
  "${0:A:h}/install-glmt.zsh"
else
  say "next: build winemac.so and libglmt.dylib, then scripts/install-glmt.zsh (README.md)"
fi

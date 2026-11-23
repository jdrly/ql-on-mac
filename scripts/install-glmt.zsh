#!/bin/zsh
# Put my builds into the engine: winemac.so and win32u.so (the engine's with patches/wine) and
# libglmt.dylib (glmt/). The engine's own files are kept as <file>.stock. Starts nothing.
#
#   scripts/install-glmt.zsh             from work/stage
#   scripts/install-glmt.zsh <folder>    from a folder that holds the three files (a CI run's download)
#   scripts/install-glmt.zsh --glmt      libglmt.dylib only (the driver in the engine stays)
#   scripts/install-glmt.zsh --remove    the engine's own files back, and no glmt
set -euo pipefail
source "${0:A:h}/common.zsh"
mac_only
need_engine
bottle_running && die "a Wine session of the bottle runs: end it first (scripts/ql.zsh stop)"

from=$STAGE files=($GLMT_FILES)
case "${1:-}" in
  --remove)
    for f in winemac.so win32u.so; do
      [[ ! -f "$UNIX_DIR/$f.stock" ]] || mv -f "$UNIX_DIR/$f.stock" "$UNIX_DIR/$f"
    done
    rm -f "$UNIX_DIR/libglmt.dylib"
    say "the engine has its own Mac driver again, and no glmt: scripts/ql.zsh starts neither Steam nor the game"
    exit 0 ;;
  --glmt) files=(libglmt.dylib) ;;
  "") ;;
  *) from=$1 ;;
esac

for f in $files; do
  [[ -f "$from/$f" ]] || die "no $f in $from"
  [[ "$(lipo -archs "$from/$f" 2>/dev/null)" == *arm64* ]] || die "$from/$f is not an arm64 Mach-O file"
done
if (( ${files[(I)winemac.so]} )); then
  grep -q -a 'libglmt.dylib' "$from/winemac.so" || die "$from/winemac.so is not built with patches/wine"
fi
# the engine's own files are kept, once
for f in ${files:#libglmt.dylib}; do
  [[ -f "$UNIX_DIR/$f.stock" ]] || cp -p "$UNIX_DIR/$f" "$UNIX_DIR/$f.stock"
done
for f in $files; do
  cp -f "$from/$f" "$UNIX_DIR/$f.new"
  xattr -d com.apple.quarantine "$UNIX_DIR/$f.new" 2>/dev/null || true
  # macOS runs arm64 code only if it is signed: ad hoc, as the engine's own libraries are
  codesign --force --sign - "$UNIX_DIR/$f.new" 2>/dev/null
  mv -f "$UNIX_DIR/$f.new" "$UNIX_DIR/$f"
  say "installed $f ($(sha256_of "$UNIX_DIR/$f" | cut -c1-12))"
done
glmt_installed || die "the engine's Mac driver is still not the patched one"

#!/bin/zsh
# Runs glmt/tools/batchtest.c, a small 32-bit Windows program, under the engine's Wine as glmt's
# program, once with one crossing per OpenGL call and once with opengl32's batching
# (patches/wine/0004), and compares: the same picture both ways, and what a call costs each way.
#
# STARTS WINE in the bottle (not Steam, not the game) and ends that session again. A window of
# 256x256 is on the screen for a few seconds. It needs the batching pair in the engine
# (scripts/opengl32.zsh build, install) and no session running.
set -euo pipefail
here="${0:A:h}"
source "$here/common.zsh"
mac_only; need_engine; need_bottle; need_glmt
bottle_running && die "a Wine session of the bottle runs: end it first (scripts/ql.zsh stop)"
grep -q -a 'WINE_GLMT_BATCH' "$UNIX_DIR/opengl32.so" || die "the engine's opengl32 is its own: scripts/opengl32.zsh build, then install"

cc="$WORK/toolchains/llvm-mingw/bin/i686-w64-mingw32-clang"
[[ -x "$cc" ]] || die "no llvm-mingw in $WORK/toolchains: scripts/build-winemac.zsh fetches it"
exe="$WORK/build/glmtbatch.exe" log="$LOGS/batchtest.log"
mkdir -p "$WORK/build" "$LOGS"
"$cc" -O2 -Wall -o "$exe" "$ROOT/glmt/tools/batchtest.c" -lopengl32 -lgdi32 -luser32

ql_env
E+=("WINE_GLMT_EXE=glmtbatch.exe" "GLMT_LOG=$LOGS/batchtest-glmt.log")
: >"$log"
run() {
  print -r -- "=== $1" | tee -a "$log"
  ( cd "$BOTTLE" && env "${UNSET[@]}" "${E[@]}" "${@:2}" "$ENGINE/bin/wine" "$exe" ) 2>&1 | grep -a -v '^compatdb:' | tee -a "$log"
}
run "one crossing per call" WINE_GLMT_BATCH=0
run "in batches" WINE_GLMT_BATCH=1
env "${UNSET[@]}" "${E[@]}" "$ENGINE/bin/wineserver" -k 2>/dev/null || true

sums=(${(f)"$(grep -a 'picture checksum [0-9a-f]* *,' "$log" | sed 's/.*picture checksum \([0-9a-f]*\).*/\1/')"})
ends=(${(f)"$(grep -a 'checksum at the end' "$log" | sed 's/.*end \([0-9a-f]*\).*/\1/')"})
grep -a -q 'hands its OpenGL calls over in batches' "$log" || die "FAIL: the second run did not batch (no line from opengl32): $log"
(( ${#sums} == 2 && ${#ends} == 2 )) || die "FAIL: a run did not get to its picture: $log"
[[ "${sums[1]}" == "${sums[2]}" && "${ends[1]}" == "${ends[2]}" && "${sums[1]}" == "${ends[1]}" ]] ||
  die "FAIL: the pictures differ (${sums[1]} ${ends[1]} without batches, ${sums[2]} ${ends[2]} with): $log"
say "PASS: the same picture both ways (${sums[1]}); the timings are above and in $log"

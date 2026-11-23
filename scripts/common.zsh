# Shared paths, pins and Wine environment for the QL on Mac scripts. Sourced, not run.
#
# Everything the scripts make lives in work/ (ignored): the engine, the bottle, staged builds,
# downloads and logs. QL_WORK moves it elsewhere.

ROOT="${${(%):-%x}:A:h:h}"
WORK="${QL_WORK:-$ROOT/work}"
ENGINE="$WORK/engine"       # the unpacked Wine (its bin/, lib/, share/)
BOTTLE="$WORK/bottle"
DOWNLOADS="${QL_DOWNLOADS:-$WORK/downloads}"   # the app keeps these two outside WORK (app/src/qlom.zsh)
LOGS="${QL_LOGS:-$WORK/logs}"
STAGE="$WORK/stage"         # builds of mine that wait to go into the engine

# The engine: athei's Mach9 0.4.0, an arm64 Wine 11.21 that runs x86 Windows code with FEX. Nothing
# in it is x86_64 macOS code, so it needs no Rosetta. Quake Live is 32-bit: its code runs under
# FEX's WoW64 half (xtajit.dll, libwow64fex.so), and every OpenGL call crosses from Wine's i386
# opengl32.dll into the arm64 unix side. Bump the URL, the size, the checksum and the commit together.
ENGINE_NAME=mach9-v0.4.0
ENGINE_URL=https://github.com/athei/mach9/releases/download/v0.4.0/wine-v0.4.0-macos-arm64.tar.xz
ENGINE_SIZE=131698496
ENGINE_SHA256=3b81aac9b93d5652872673b400769ec525f3bc2f1f7e2ec82c9f851d0a0db05d
# athei/wine's commit it was built from (wine-11.21-54): patches/wine applies to it
ENGINE_WINE=501796b0ed15759127c2a5f415d31570cdee34f3
UNIX_DIR="$ENGINE/lib/wine/aarch64-unix"

# My three files in the engine's unix folder:
#   winemac.so     the engine's Mac driver with patches/wine (it hands Quake Live's OpenGL to glmt)
#   libglmt.dylib  glmt/, OpenGL 1.x on Metal
#   win32u.so      the engine's with patches/wine: a negative number in a font's matrix keeps its
#                  sign (without it the game's menu, a web page, has dashes for text)
# scripts/install-glmt.zsh puts them there from STAGE and keeps the engine's own as <file>.stock. Without them the engine would give Quake Live Mesa's OpenGL (Zink on a Vulkan
# driver on Metal), which this project exists to avoid: scripts/ql.zsh then starts neither Steam
# nor the game.
GLMT_FILES=(winemac.so win32u.so libglmt.dylib)

# Quake Live is Steam app 282440
QL_APPID=282440
QL_EXE_NAME=quakelive_steam.exe
QL_FPS="${QL_FPS:-250}"
STEAM_SETUP_URL=https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe
STEAM_DIR="$BOTTLE/drive_c/Program Files (x86)/Steam"
STEAM_EXE='C:\Program Files (x86)\Steam\steam.exe'
QL_DIR="$STEAM_DIR/steamapps/common/Quake Live"

say() { print -r -- "[ql] $*"; }
die() { print -r -- "[ql] $*" >&2; exit 1; }
sha256_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

mac_only() { [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die "this runs on the Apple Silicon Mac, not on $(uname -s) $(uname -m)"; }
engine_ok() { [[ -x "$ENGINE/bin/wine" && "$(cat "$ENGINE/.ql-engine" 2>/dev/null)" == "$ENGINE_SHA256" ]]; }
need_engine() { engine_ok || die "no engine in $ENGINE: run scripts/setup-engine.zsh"; }
need_bottle() { [[ -f "$BOTTLE/system.reg" ]] || die "no bottle in $BOTTLE: run scripts/create-bottle.zsh"; }
# a Wine session runs on this engine: its wineserver, told by the executable's path (Wine rewrites
# the names of its other processes to C:\...\name.exe)
# (no grep -q after a pipe anywhere in these scripts: it ends at its first match, the command
# before it dies of SIGPIPE, and under pipefail the pipeline then fails exactly when it matched)
bottle_running() { [[ -n "$(ps -axww -o comm= 2>/dev/null | awk -v e="$ENGINE/" 'index($0, e) && /wineserver$/' || true)" ]]; }
# the game's process is there (by the name Wine gives it)
game_running() { [[ -n "$(ps -axww -o command= 2>/dev/null | grep -i "[\\\\/]${QL_EXE_NAME:r}\\.exe" || true)" ]]; }

# glmt_installed: both files are in the engine, and its Mac driver is the patched one
glmt_installed() {
  [[ -f "$UNIX_DIR/libglmt.dylib" && -f "$UNIX_DIR/winemac.so" ]] || return 1
  grep -q -a 'libglmt.dylib' "$UNIX_DIR/winemac.so"
}
need_glmt() { glmt_installed || die "glmt is not in the engine, so Quake Live would get the engine's own OpenGL: run scripts/install-glmt.zsh"; }

# ql_env: the environment of every Wine process of the bottle, in the array E.
#   GLMT_BACKEND   metal (default) or null: null draws nothing, to measure what the game, FEX and
#                  Wine's call path cost without Metal
#   GLMT_STATS     N: a line in the log every N frames (fps, OpenGL calls, draws and vertices a frame)
#   GLMT_DEBUG     1: glmt logs OpenGL errors with the entry point, contexts, surfaces, textures
#   GLMT_TRACE     "30 400": the frames in which glmt logs every OpenGL entry point by name
#   GLMT_PRESENT   how frames reach the display when the game wants no vsync: async (the
#                  scripts' default, below), tear (glmt's own default:
#                  every frame at once, never waiting, with tearing), mailbox (one frame per
#                  refresh with display sync on: a refresh late, and it juddered three times),
#                  wait (every frame, waiting for the display), async (as tear, with a thread
#                  of glmt's own taking the display's buffers: the game never waits for them)
#   GLMT_PRESENT_LEAD  mailbox: milliseconds before a refresh by which a frame is presented
#                  (default: one refresh and a learned margin)
#   GLMT_FLIP_TRACE    a file that gets every flip, swap and display link callback as a line
#                  (an absolute path)
#   GLMT_PROFILE   1: every OpenGL call reads the clock, and the statistics get a "profile" line:
#                  how long a frame's OpenGL part takes, what one call costs to make from the
#                  game's side, and how much of a frame the game computes between calls
#   GLMT_LOG       glmt's log file (default: work/logs/glmt.log)
#   QL_BATCH       1 (default; 0: off): the game's OpenGL calls cross to Wine's 64-bit side in batches, one
#                  crossing per draw (patches/wine/0004: WINE_GLMT_BATCH; wine.log says so).
#                  Only with the patched opengl32 pair in the engine: scripts/opengl32.zsh
#   QL_SPACE       1 (default; 0: off): the game's fullscreen window takes a full-screen Space of its own
#                  (patches/wine/0003: WINE_GLMT_FULLSCREEN_SPACE for the Mac driver; wine.log
#                  gets "winemac: fullscreen space: ..." lines that say what the driver did)
#   FPS_HUD        on: Metal's performance HUD on the game
# Variables of the engine's compatdb that would change what every process does are taken out, as
# GW2 on Mac's backend does.
ql_env() {
  E=(
    "WINEPREFIX=$BOTTLE"
    "WINEDEBUG=${WINEDEBUG:--all}"
    "WINEDLLOVERRIDES=winemenubuilder.exe=d"
    "WINEMSYNC=1"
    "GLMT_LOG=${GLMT_LOG:-$LOGS/glmt.log}"
  )
  [[ -z "${GLMT_BACKEND:-}" ]] || E+=("GLMT_BACKEND=$GLMT_BACKEND")
  [[ -z "${GLMT_STATS:-}" ]] || E+=("GLMT_STATS=$GLMT_STATS")
  [[ -z "${GLMT_DEBUG:-}" ]] || E+=("GLMT_DEBUG=$GLMT_DEBUG")
  [[ -z "${GLMT_TRACE:-}" ]] || E+=("GLMT_TRACE=$GLMT_TRACE")
  # The defaults since 2026-11-22, after a duel on each: a presenter
  # thread of glmt's own, the game's window in a Space of its own, OpenGL calls in batches.
  # GLMT_PRESENT=tear, QL_SPACE=0 and QL_BATCH=0 give the old ways back, one by one.
  E+=("GLMT_PRESENT=${GLMT_PRESENT:-async}")
  [[ -z "${GLMT_PRESENT_LEAD:-}" ]] || E+=("GLMT_PRESENT_LEAD=$GLMT_PRESENT_LEAD")
  [[ -z "${GLMT_FLIP_TRACE:-}" ]] || E+=("GLMT_FLIP_TRACE=$GLMT_FLIP_TRACE")
  [[ -z "${GLMT_PROFILE:-}" ]] || E+=("GLMT_PROFILE=$GLMT_PROFILE")
  [[ "${QL_SPACE:-1}" != 1 ]] || E+=("WINE_GLMT_FULLSCREEN_SPACE=1")
  [[ "${QL_BATCH:-1}" != 1 ]] || E+=("WINE_GLMT_BATCH=1")
  # My rules for the engine's compatdb, on top of its built-in ones (wine.log says per process what
  # each rule did): Metal's HUD on the game with FPS_HUD=on.
  {
    [[ "${FPS_HUD:-off}" != on ]] || print -r -- "exe=$QL_EXE_NAME;metal_hud=true"
  } >"$WORK/compatdb.rules"
  E+=("WINE_COMPATDB_FILE=$WORK/compatdb.rules")
  return 0
}

# native_resolution: the main display's size in the pixels Wine's Retina mode counts in (the
# backing store: twice what "UI Looks like" says, or the panel's own where macOS does not scale),
# as WIDTHxHEIGHT. A game at exactly this size is fullscreen without a change of display mode.
native_resolution() {
  system_profiler SPDisplaysDataType 2>/dev/null | awk '
    /Resolution:/ { panel = $2 "x" $4; ui = "" }
    /UI Looks like:/ { ui = ($4 * 2) "x" ($6 * 2) }
    /Main Display: Yes/ { print (ui != "" ? ui : panel); found = 1; exit }
    END { if (!found && panel != "") print (ui != "" ? ui : panel) }'
}
UNSET=(-u WINELOADER -u WINESERVER -u WINEDLLPATH -u DYLD_FALLBACK_LIBRARY_PATH
  -u WINE_COMPATDB -u WINE_COMPATDB_FILE -u WINE_LARGE_ADDRESS_AWARE -u WINE_PROF_SERVICE
  -u WINE_GLMT -u WINE_GLMT_EXE -u WINE_GLMT_LIB -u WINE_GLMT_FULLSCREEN_SPACE -u WINE_GLMT_BATCH)

# wine_cmd <args...>: Wine in the bottle, waiting for it, output to the terminal
wine_cmd() { ql_env; env "${UNSET[@]}" "${E[@]}" "$ENGINE/bin/wine" "$@"; }
# wine_wait: until the bottle's session has ended
wine_wait() { WINEPREFIX="$BOTTLE" "$ENGINE/bin/wineserver" -w; }
# wine_stop: end the bottle's session
wine_stop() { WINEPREFIX="$BOTTLE" "$ENGINE/bin/wineserver" -k 2>/dev/null || true; wine_wait 2>/dev/null || true; }

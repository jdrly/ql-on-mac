#!/bin/zsh
# QL on Mac's one command: build everything, set the bottle up, start Steam and Quake Live.
#
#   scripts/ql.zsh setup     everything up to Steam's window, each step skipped when it is done:
#                            the engine, glmt and the patched Mac driver compiled on this Mac and
#                            put into the engine, the bottle, Steam's installer, then Steam itself.
#                            There I log in and install Quake Live. Run it again after a failure.
#   scripts/ql.zsh build     the compiling half of setup only: starts nothing of Wine. Also after a
#                            change to glmt/ or patches/wine (it needs the session ended: stop).
#   scripts/ql.zsh steam     Steam's window, to log in and to install or update Quake Live
#   scripts/ql.zsh play      Quake Live through Steam, capped at QL_FPS (250) with vsync off
#   scripts/ql.zsh debug     play with everything logged, and the logs followed in this terminal
#                            (Ctrl-C ends the following, not the game): glmt's debug lines (OpenGL
#                            errors with their entry point, contexts, surfaces, textures), a
#                            statistics line every 250 frames, Wine's errors for every process and
#                            its OpenGL warnings for the game (a call glmt has no entry point for
#                            is named there), Metal's HUD
#   scripts/ql.zsh debug null    the same on glmt's null backend, which draws nothing: the frame
#                            rate then is what the game, FEX and Wine's OpenGL call path cost
#                            before Metal does anything (use it with a timedemo)
#   scripts/ql.zsh debug trace   debug with every OpenGL call of the game in wine.log (Wine's
#                            opengl and wgl channels): gigabytes within minutes, for a short look
#   scripts/ql.zsh logs      follow the logs of a running session
#   scripts/ql.zsh stop      end the bottle's Wine session (Steam and the game with it)
#   scripts/ql.zsh status    what is installed and what runs
#   scripts/ql.zsh exe       what the installed quakelive_steam.exe is and which OpenGL names it
#                            binds (read from the file, nothing started)
#   scripts/ql.zsh cvars     the game's saved variables: how many, and which no part of the game
#                            names any more (it has room for 2,048 and ends with MAX_CVARS beyond;
#                            read from the files, nothing started)
#   scripts/ql.zsh cvars trim    takes those out of repconfig.cfg and qzconfig.cfg, the files as
#                            they were kept in work/backups. Not while a session runs; Steam Cloud
#                            carries the result to the other computers
#
# Settings, from the environment:
#   QL_FPS=125               com_maxfps (default: 250, the game's own limit)
#   QL_RES=3840x2160         the game's resolution, fullscreen (default: the display's own pixels,
#                            so no display mode change; keep: what the game's config says)
#   QL_ARGS="+set ..."       more arguments for the game (+set r_fullscreen 0 for a window)
#   GLMT_BACKEND=null  GLMT_STATS=500  GLMT_DEBUG=1  FPS_HUD=on  WINEDEBUG=...
#                            what debug sets, one by one, for play
#   GLMT_PRESENT=tear        every frame at once from the game's own thread (default: async, the
#                            same from a thread of glmt's, so the game never waits for the display)
#   GLMT_PRESENT=mailbox     one frame per refresh with display sync: no tearing, a refresh late
#   GLMT_PROFILE=1           a "profile" line in glmt.log: where a frame's time goes
#   GLMT_FLIP_TRACE=/path    every flip and swap as a line in that file (an absolute path)
#   QL_SPACE=0               not the default: the game's fullscreen window in a full-screen Space
#                            of its own (macOS's native fullscreen), entered once per window
#   QL_BATCH=0               not the default: the game's OpenGL calls in batches (it needs the
#                            patched opengl32 in the engine: scripts/opengl32.zsh build, install)
#                            Like every setting here these reach the game only through a Steam
#                            started by this command: stop first.
#
# steam, play and debug refuse to start while the engine's OpenGL for the game is not glmt (Steam's
# own Play button starts the game too): the engine's own would be Mesa's (Zink on a Vulkan driver on
# Metal), the stack this project is here to replace.
#
# A game started through a Steam that already runs gets that Steam's environment, not this
# command's. Arguments (the frame cap) reach it; GLMT_* and WINEDEBUG do not. So debug wants the
# session ended first, and says so.
set -euo pipefail
source "${0:A:h}/common.zsh"
here="${0:A:h}"

launch() {
  ql_env
  mkdir -p "$LOGS"
  print -r -- "=== $(date '+%F %T') $*" >>"$LOGS/wine.log"
  ( cd "$BOTTLE" && env "${UNSET[@]}" "${E[@]}" nohup "$ENGINE/bin/wine" "$@" </dev/null >>"$LOGS/wine.log" 2>&1 & )
  # These scripts tell a running session by its wineserver (bottle_running): debug's refusal, the
  # install of new builds and setup's second run all hang on it. If it does not see the session
  # that was just started, say so loudly instead of letting those three go wrong quietly.
  sleep 6
  if ! bottle_running; then
    say "WARNING: Wine was started, and bottle_running (scripts/common.zsh) sees no session. Either Wine ended at once ($LOGS/wine.log), or the check misses this engine's wineserver. Processes named wineserver now:"
    ps -axww -o pid=,comm= | grep -i '[w]ineserver' || say "(none)"
  fi
}

# a new session's logs start afresh; the one before stays as <log>.1
rotate_logs() {
  local f
  mkdir -p "$LOGS"
  for f in wine.log glmt.log; do
    [[ ! -s "$LOGS/$f" ]] || mv -f "$LOGS/$f" "$LOGS/$f.1"
    : >"$LOGS/$f"
  done
}

follow_logs() {
  say "following $LOGS/glmt.log and wine.log (Ctrl-C ends this, not the game)"
  touch "$LOGS/glmt.log" "$LOGS/wine.log"
  exec tail -n +1 -F "$LOGS/glmt.log" "$LOGS/wine.log"
}

need_steam() { [[ -f "$STEAM_DIR/steam.exe" ]] || die "Steam is not installed: run scripts/ql.zsh setup"; }
need_game() { [[ -f "$QL_DIR/$QL_EXE_NAME" ]] || die "Quake Live is not installed: scripts/ql.zsh steam, then install it there"; }

# The game's arguments. com_maxfps is the game's own cap; r_swapInterval 0 keeps vsync from holding
# it at the display's refresh rate. The resolution is the display's own, fullscreen: the config
# Steam Cloud brings from the PC names that monitor's size, and a fullscreen game at another size
# than the display's makes macOS switch the display to a scaled mode. QL_RES=WIDTHxHEIGHT picks
# another size, QL_RES=keep leaves the config's. The game writes what it is started with into its
# config, and Steam Cloud takes that back to the PC.
game_args() {
  local res=${QL_RES:-$(native_resolution)} mode=()
  if [[ "$res" == <->x<-> ]]; then
    mode=(+set r_fullscreen 1 +set r_mode -1 +set r_customWidth "${res%x*}" +set r_customHeight "${res#*x}")
  elif [[ "$res" != keep ]]; then
    say "the display's size is not known ("$res"): the game keeps its config's resolution. QL_RES=WIDTHxHEIGHT sets one" >&2
  fi
  print -r -- -applaunch "$QL_APPID" +set com_maxfps "$QL_FPS" +set r_swapInterval 0 $mode ${=QL_ARGS:-}
}

build() {
  mac_only
  bottle_running && die "a Wine session runs on the engine, and its files can't be replaced under it: scripts/ql.zsh stop (not while Steam downloads), then again"
  local free=$(df -k "$ROOT" | awk 'NR == 2 { print int($4 / 1048576) }')
  (( free >= 12 )) || die "only $free GB free where $ROOT is: the engine, the toolchain, Wine's build and the bottle with the game need about 12"
  say "1/4 the engine"
  "$here/setup-engine.zsh"
  say "2/4 glmt (tests, libglmt.dylib, shaders)"
  "$here/build-glmt.zsh" >"$LOGS/build-glmt.log" 2>&1 || { tail -30 "$LOGS/build-glmt.log" >&2; die "glmt does not build: $LOGS/build-glmt.log"; }
  tail -2 "$LOGS/build-glmt.log"
  say "3/4 the Mac driver and win32u with patches/wine"
  "$here/build-winemac.zsh"
  say "4/4 all three into the engine"
  "$here/install-glmt.zsh"
}

exe_report() {
  local exe="$QL_DIR/$QL_EXE_NAME"
  [[ -f "$exe" ]] || die "Quake Live is not installed: no $exe"
  file "$exe"
  print -r -- "--- graphics DLLs named in the file:"
  strings -a "$exe" | grep -i -E '^(opengl32|d3d9|d3d8|ddraw)\.dll$' | sort -u || true
  print -r -- "--- OpenGL entry points it names (id Tech 3 binds them by name at start):"
  strings -a "$exe" | grep -E '^w?gl[A-Z][A-Za-z0-9]+$' | sort -u || true
  print -r -- "--- extensions it names:"
  strings -a "$exe" | grep -E '^W?GL_[A-Z0-9]+_[A-Za-z0-9_]+$' | sort -u || true
}

case "${1:-}" in
  setup)
    mkdir -p "$LOGS"
    if glmt_installed && bottle_running; then
      say "the engine has glmt, and a session runs: nothing to build"
    else
      build
    fi
    [[ -f "$BOTTLE/.ql-bottle" ]] || "$here/create-bottle.zsh"
    [[ -f "$STEAM_DIR/steam.exe" ]] || "$here/install-steam.zsh"
    if [[ -f "$QL_DIR/$QL_EXE_NAME" ]]; then
      say "Quake Live is installed. Next: scripts/ql.zsh play, or scripts/ql.zsh debug"
    else
      bottle_running || { rotate_logs; launch "$STEAM_EXE"; }
      say "Steam is starting (it updates itself first). Then:"
      say "  1. log in and install Quake Live (Library)"
      say "  2. when the download is done, quit Steam from its menu (closing the window leaves it running), or: scripts/ql.zsh stop"
      say "  3. scripts/ql.zsh debug"
      say "The game's first start shows what glmt draws so far, which is clears only (expect a black window); the log says what the game asks for."
    fi ;;
  build)
    mkdir -p "$LOGS"
    build ;;
  steam)
    mac_only; need_engine; need_bottle; need_steam
    # (Steam's own Play button starts the game too)
    need_glmt
    bottle_running || rotate_logs
    launch "$STEAM_EXE"
    say "Steam is starting (log: $LOGS/wine.log)" ;;
  play)
    mac_only; need_engine; need_bottle; need_steam; need_game; need_glmt
    bottle_running || rotate_logs
    # (a line of frame rate and frame times every 1000 frames in glmt.log: four clock reads a frame)
    export GLMT_STATS="${GLMT_STATS:-1000}"
    launch "$STEAM_EXE" $(game_args)
    say "Quake Live is starting, capped at $QL_FPS fps, at ${QL_RES:-$(native_resolution)} (logs: scripts/ql.zsh logs)" ;;
  debug)
    mac_only; need_engine; need_bottle; need_steam; need_game; need_glmt
    mode=${2:-}
    [[ -z "$mode" || "$mode" == null || "$mode" == trace ]] || die "usage: ql.zsh debug [null | trace]"
    bottle_running && die "a Wine session runs (Steam is open), and the game would get its environment, not debug's: scripts/ql.zsh stop first (not while Steam downloads), then debug again"
    export GLMT_DEBUG=1 GLMT_STATS="${GLMT_STATS:-250}" FPS_HUD="${FPS_HUD:-on}"
    # four frames with every OpenGL entry point by name: one early, three later
    export GLMT_TRACE="${GLMT_TRACE:-30 400 1500 6000}"
    # Wine's errors for every process; for the game also the warnings and fixmes of Wine's
    # opengl32 (a call into an entry point glmt does not have is named there) and the fixmes of
    # win32u's OpenGL. Not win32u's warnings: it prints one "not found" line for each of the
    # roughly 3,000 extension names glmt has no entry point for, at every start, by design.
    export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all,$QL_EXE_NAME:warn+opengl,$QL_EXE_NAME:fixme+opengl,$QL_EXE_NAME:fixme+wgl}"
    [[ "$mode" != null ]] || export GLMT_BACKEND=null
    [[ "$mode" != trace ]] || WINEDEBUG="$WINEDEBUG,$QL_EXE_NAME:+opengl,$QL_EXE_NAME:+wgl"
    rotate_logs
    launch "$STEAM_EXE" $(game_args)
    say "Quake Live is starting in debug${mode:+ ($mode)}, capped at $QL_FPS fps, at ${QL_RES:-$(native_resolution)}"
    follow_logs ;;
  logs)
    follow_logs ;;
  stop)
    mac_only; need_engine
    wine_stop
    say "the bottle's session has ended" ;;
  status)
    engine_ok && say "engine: $ENGINE_NAME" || say "engine: none (scripts/ql.zsh setup)"
    if engine_ok; then
      glmt_installed && say "OpenGL for Quake Live: glmt (winemac.so $(sha256_of "$UNIX_DIR/winemac.so" | cut -c1-12), libglmt.dylib $(sha256_of "$UNIX_DIR/libglmt.dylib" | cut -c1-12))" ||
        say "OpenGL for Quake Live: glmt is NOT installed (scripts/ql.zsh build); steam, play and debug refuse to start"
    fi
    [[ -f "$BOTTLE/system.reg" ]] && say "bottle: $BOTTLE" || say "bottle: none (scripts/ql.zsh setup)"
    [[ -f "$STEAM_DIR/steam.exe" ]] && say "Steam: installed" || say "Steam: not installed (scripts/ql.zsh setup)"
    [[ -f "$QL_DIR/$QL_EXE_NAME" ]] && say "Quake Live: installed" || say "Quake Live: not installed (scripts/ql.zsh steam)"
    bottle_running && say "session: running$(game_running && print -n ', the game too')" || say "session: not running" ;;
  exe) exe_report ;;
  cvars)
    [[ -f "$QL_DIR/$QL_EXE_NAME" ]] || die "Quake Live is not installed (scripts/ql.zsh steam)"
    case "${2:-report}" in
      report) python3 "$here/cvars.py" report "$QL_DIR" "$WORK/backups" ;;
      trim)
        bottle_running && die "a session runs: the game writes its configs when it ends, and Steam Cloud carries them. scripts/ql.zsh stop first"
        python3 "$here/cvars.py" trim "$QL_DIR" "$WORK/backups" ;;
      *) die "usage: ql.zsh cvars [trim]" ;;
    esac ;;
  *) die "usage: ql.zsh setup | build | steam | play | debug [null | trace] | logs | stop | status | exe | cvars [trim]" ;;
esac

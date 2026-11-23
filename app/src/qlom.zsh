#!/bin/zsh
# QL on Mac's backend: what the app's window does, as commands. It is this repository's scripts
# (common.zsh rides along in the bundle) pointed at the app's own folders, so the app never
# touches a development checkout's work/.
#
#   qlom.zsh status           the state as key=value lines (what the window shows)
#   qlom.zsh install          the engine, my pieces, the bottle, Steam, then Steam's window to sign
#                             in and install Quake Live. Each step is skipped when it is done, so
#                             running it again continues. STARTS WINE
#   qlom.zsh play             Quake Live through Steam, detached. STARTS WINE
#   qlom.zsh steam            Steam's window. STARTS WINE
#   qlom.zsh stop             ends the bottle's Wine session (Steam and the game)
#   qlom.zsh set fps 125|250
#   qlom.zsh set retina on|off
#   qlom.zsh repair           the engine unpacked again if it is not whole, my pieces put in again
#   qlom.zsh uninstall        everything but the logs: the engine, the bottle with Steam and the game
#   qlom.zsh env              the environment and arguments play would use
#
# Lines for the window start with "@": @step <n> <of> <title>, @progress <bytes> <of>,
# @error <text>, @done. Everything else is for the log.
#
# Where things are:
#   ~/Library/Application Support/QL on Mac/   engine/, bottle/ (Steam, the game), settings.conf
#   ~/Library/Caches/QL on Mac/downloads/      the engine's archive, SteamSetup.exe
#   ~/Library/Logs/QL on Mac/                  install.log, wine.log, glmt.log
# QLOM_ROOT=/abs/dir puts all three under that folder (a sandbox). QLOM_TEST_ENGINE=<archive> and
# QLOM_TEST_STEAM=<file> then stand in for the two downloads, and the Mac-only checks are left
# out: app/scripts/test-backend.zsh runs the whole backend that way on any machine, with a Wine
# that only pretends.
set -euo pipefail
here="${0:A:h}"
APP_NAME="QL on Mac"

if [[ -n "${QLOM_ROOT:-}" ]]; then
  [[ "$QLOM_ROOT" == /* ]] || { print -r -- "@error QLOM_ROOT must be an absolute path" ; exit 1; }
  export QL_WORK="$QLOM_ROOT/support" QL_DOWNLOADS="$QLOM_ROOT/downloads" QL_LOGS="$QLOM_ROOT/logs"
else
  export QL_WORK="$HOME/Library/Application Support/$APP_NAME"
  export QL_DOWNLOADS="$HOME/Library/Caches/$APP_NAME/downloads" QL_LOGS="$HOME/Library/Logs/$APP_NAME"
fi
source "$here/common.zsh"
COMPONENTS="${QLOM_COMPONENTS:-$here/components}"
SETTINGS="$WORK/settings.conf"
LOCK="$WORK/.lock"
PE32_DIR="$ENGINE/lib/wine/i386-windows"
MANIFEST="$STEAM_DIR/steamapps/appmanifest_$QL_APPID.acf"
# my files and where each goes in the engine; the engine's own stays beside it as <file>.stock
UNIX_PIECES=(winemac.so win32u.so libglmt.dylib opengl32.so)
PE32_PIECES=(opengl32.dll)

sandbox=0
if [[ -n "${QLOM_ROOT:-}" ]]; then
  sandbox=1
  if [[ -n "${QLOM_TEST_ENGINE:-}" ]]; then
    ENGINE_URL="file://$QLOM_TEST_ENGINE" ENGINE_SHA256=$(sha256_of "$QLOM_TEST_ENGINE")
    ENGINE_SIZE=$(wc -c <"$QLOM_TEST_ENGINE" | tr -d ' ') ENGINE_NAME=stand-in
  fi
  [[ -z "${QLOM_TEST_STEAM:-}" ]] || STEAM_SETUP_URL="file://$QLOM_TEST_STEAM"
fi
on_mac() { [[ "$(uname -s)" == Darwin ]]; }
need_mac() { (( sandbox )) && [[ -n "${QLOM_TEST_ENGINE:-}" ]] || mac_only; }

fail() { print -r -- "@error $*"; print -r -- "[ql] $*" >&2; exit 1; }
step() { print -r -- "@step $1 $2 $3"; say "$3"; }
log_to() { mkdir -p "$LOGS"; print -r -- "=== $(date '+%F %T') $*" >>"$LOGS/install.log"; }

# --- settings ---------------------------------------------------------------------------------
setting() {
  local v=""
  [[ ! -f "$SETTINGS" ]] || v=$(sed -n "s/^$1=//p" "$SETTINGS" | tail -1)
  print -r -- "${v:-$2}"
}
fps() { local v=$(setting fps 250); [[ "$v" == 125 || "$v" == 250 ]] || v=250; print -r -- $v; }
retina() { local v=$(setting retina on); [[ "$v" == on || "$v" == off ]] || v=on; print -r -- $v; }
cmd_set() {
  local key=${1:-} value=${2:-}
  case "$key=$value" in
    fps=125|fps=250|retina=on|retina=off) ;;
    *) fail "usage: set fps 125|250, set retina on|off" ;;
  esac
  mkdir -p "$WORK"
  { [[ ! -f "$SETTINGS" ]] || grep -v "^$key=" "$SETTINGS" || true; print -r -- "$key=$value"; } >"$SETTINGS.new"
  mv -f "$SETTINGS.new" "$SETTINGS"
  print -r -- "@done"
}

# --- the display --------------------------------------------------------------------------------
# display_sizes: "<pixels> <points>" of the main display, each WIDTHxHEIGHT. With Retina mode Wine
# counts in pixels, without it in points; on a display macOS does not scale the two are the same.
# The app hands them over in QLOM_DISPLAY (it knows them without the second system_profiler takes).
display_sizes() {
  if [[ "${QLOM_DISPLAY:-}" == <->x<->\ <->x<-> ]]; then print -r -- "$QLOM_DISPLAY"; return; fi
  system_profiler SPDisplaysDataType 2>/dev/null | awk '
    function out() { if (panel != "") { print (ui != "" ? uipx : panel), (ui != "" ? ui : panel); done = 1 } }
    /Resolution:/ { panel = $2 "x" $4; ui = "" }
    /UI Looks like:/ { ui = $4 "x" $6; uipx = ($4 * 2) "x" ($6 * 2) }
    /Main Display: Yes/ { out(); exit }
    END { if (!done) out() }'
}
game_resolution() { # the size the game is started at: the display's, in what Wine counts in
  local sizes=($(display_sizes))
  (( $#sizes == 2 )) || return 0
  [[ "$(retina)" == on ]] && print -r -- $sizes[1] || print -r -- $sizes[2]
}

# --- state --------------------------------------------------------------------------------------
components_state() {
  [[ -f "$COMPONENTS/STAMP" ]] || { print -r -- missing; return; }
  [[ -f "$ENGINE/.ql-components" ]] || { print -r -- none; return; }
  cmp -s "$COMPONENTS/STAMP" "$ENGINE/.ql-components" && glmt_installed && print -r -- ok || print -r -- old
}
manifest_value() { [[ ! -f "$MANIFEST" ]] || sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*\"\\([0-9]*\\)\".*/\\1/p" "$MANIFEST" | head -1; }
game_state() {
  local flags=$(manifest_value StateFlags)
  if [[ -f "$QL_DIR/$QL_EXE_NAME" && "$flags" == 4 ]]; then print -r -- ok
  elif [[ -n "$flags" ]]; then print -r -- downloading
  else print -r -- none; fi
}
status() {
  local sizes=($(display_sizes)) session=none
  bottle_running && session=running
  print -r -- "engine=$(engine_ok && print ok || print none)"
  print -r -- "components=$(components_state)"
  print -r -- "bottle=$([[ -f "$BOTTLE/system.reg" ]] && print ok || print none)"
  print -r -- "steam=$([[ -f "$STEAM_DIR/steam.exe" ]] && print ok || print none)"
  print -r -- "game=$(game_state)"
  print -r -- "game_bytes=$(manifest_value BytesDownloaded)"
  print -r -- "game_total=$(manifest_value BytesToDownload)"
  print -r -- "session=$session"
  print -r -- "game_running=$(game_running && print yes || print no)"
  print -r -- "fps=$(fps)"
  print -r -- "retina=$(retina)"
  print -r -- "retina_applied=$(cat "$BOTTLE/.ql-retina" 2>/dev/null || true)"
  print -r -- "display_pixels=${sizes[1]:-}"
  print -r -- "display_points=${sizes[2]:-}"
  print -r -- "busy=$([[ -d "$LOCK" ]] && print yes || print no)"
  print -r -- "logs=$LOGS"
}

# --- one at a time ------------------------------------------------------------------------------
lock() {
  mkdir -p "$WORK"
  if ! mkdir "$LOCK" 2>/dev/null; then
    local pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then fail "QL on Mac is already at work (process $pid)"; fi
    rm -rf "$LOCK"; mkdir "$LOCK"
  fi
  print -r -- $$ >"$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
  trap 'print -r -- "@error Cancelled"; pkill -P $$ 2>/dev/null || true; (( ! wine_busy )) || wine_stop; exit 130' INT TERM
}
wine_busy=0   # 1 while a step of this run has Wine going: a cancel then ends that session

# --- the engine ---------------------------------------------------------------------------------
fetch_engine() {
  local archive="$DOWNLOADS/${ENGINE_URL:t}" pid size
  mkdir -p "$DOWNLOADS"
  if [[ "$(sha256_of "$archive")" != "$ENGINE_SHA256" ]]; then
    say "downloading $ENGINE_NAME ($((ENGINE_SIZE / 1048576)) MB)"
    curl -fsL --retry 3 -C - -o "$archive.part" "$ENGINE_URL" &
    pid=$!
    while kill -0 $pid 2>/dev/null; do
      size=0
      [[ ! -f "$archive.part" ]] || size=$(wc -c <"$archive.part" | tr -d ' ')
      print -r -- "@progress $size $ENGINE_SIZE"
      sleep 0.5
    done
    wait $pid || fail "The engine could not be downloaded. Check the connection and install again."
    [[ "$(sha256_of "$archive.part")" == "$ENGINE_SHA256" ]] || { rm -f "$archive.part"; fail "The engine's download is damaged. Install again."; }
    mv -f "$archive.part" "$archive"
  fi
  say "unpacking the engine"
  rm -rf "$ENGINE.new"
  mkdir -p "$ENGINE.new"
  tar -xJf "$archive" -C "$ENGINE.new" --strip-components 1
  ! on_mac || xattr -dr com.apple.quarantine "$ENGINE.new" 2>/dev/null || true
  rm -rf "$ENGINE.new/include" "$ENGINE.new/lib/wine/tests" "$ENGINE.new/lib/wine/x86_64-windows" "$ENGINE.new/share/man"
  [[ -x "$ENGINE.new/bin/wine" && -f "$ENGINE.new/lib/wine/aarch64-unix/winemac.so" && -f "$ENGINE.new/lib/wine/i386-windows/opengl32.dll" ]] ||
    { rm -rf "$ENGINE.new"; fail "The engine's archive is not what was expected."; }
  print -r -- "$ENGINE_SHA256" >"$ENGINE.new/.ql-engine"
  rm -rf "$ENGINE"
  mv "$ENGINE.new" "$ENGINE"
}

# apply_components: my five files into the engine, the engine's own kept once as <file>.stock.
# Never under a running session: its processes have the old files mapped.
apply_components() {
  local f dir
  [[ -f "$COMPONENTS/STAMP" ]] || fail "This copy of the app has no components. Download it again."
  for f in $UNIX_PIECES $PE32_PIECES; do [[ -f "$COMPONENTS/$f" ]] || fail "The app's $f is missing. Download the app again."; done
  for f in $UNIX_PIECES $PE32_PIECES; do
    dir=$UNIX_DIR; (( ${PE32_PIECES[(I)$f]} )) && dir=$PE32_DIR
    [[ "$f" == libglmt.dylib || -f "$dir/$f.stock" || ! -f "$dir/$f" ]] || cp -p "$dir/$f" "$dir/$f.stock"
    cp -f "$COMPONENTS/$f" "$dir/$f.new"
    if on_mac && [[ "$f" != *.dll ]]; then
      xattr -d com.apple.quarantine "$dir/$f.new" 2>/dev/null || true
      # macOS runs arm64 code only if it is signed: ad hoc, as the engine's own libraries are
      codesign --force --sign - "$dir/$f.new" 2>/dev/null
    fi
    mv -f "$dir/$f.new" "$dir/$f"
  done
  glmt_installed || fail "The engine's Mac driver is not the one for Quake Live."
  cp -f "$COMPONENTS/STAMP" "$ENGINE/.ql-components"
}

# apply_retina: Wine reads RetinaMode when a session starts, so set it with no session before
# and none left after. The game then sees the display in pixels (on) or in points (off).
apply_retina() {
  local want=$(retina)
  [[ "$(cat "$BOTTLE/.ql-retina" 2>/dev/null || true)" != "$want" ]] || return 0
  say "Retina mode $want"
  wine_cmd reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /d "${${want:#off}:+y}${${want:#on}:+n}" /f >>"$LOGS/install.log" 2>&1 ||
    { wine_stop; fail "The bottle's settings could not be written. Details are in $LOGS/install.log."; }
  wine_stop
  print -r -- "$want" >"$BOTTLE/.ql-retina"
}

make_bottle() {
  mkdir -p "$BOTTLE" "$LOGS"
  wine_busy=1
  if [[ ! -f "$BOTTLE/system.reg" ]]; then
    say "creating the bottle (about a minute)"
    wine_cmd wineboot --init >>"$LOGS/install.log" 2>&1 || { wine_stop; fail "Wine could not create the bottle. Details are in $LOGS/install.log."; }
    wine_wait
    [[ -f "$BOTTLE/user.reg" ]] || fail "Wine did not create the bottle. Details are in $LOGS/install.log."
    wine_cmd reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >>"$LOGS/install.log" 2>&1 || true
    wine_stop
    print -r -- "$ENGINE_NAME" >"$BOTTLE/.ql-bottle"
  fi
  apply_retina
  wine_busy=0
}

install_steam() {
  [[ ! -f "$STEAM_DIR/steam.exe" ]] || return 0
  local setup="$DOWNLOADS/SteamSetup.exe"
  mkdir -p "$DOWNLOADS"
  [[ -s "$setup" ]] || { say "downloading SteamSetup.exe from Valve"; curl -fsL --retry 3 -o "$setup.part" "$STEAM_SETUP_URL" || fail "Steam's installer could not be downloaded from Valve."; mv -f "$setup.part" "$setup"; }
  say "installing Steam (Valve's installer, silently)"
  wine_busy=1
  wine_cmd "$setup" /S >>"$LOGS/install.log" 2>&1 || { wine_stop; fail "Valve's installer failed. Details are in $LOGS/install.log."; }
  wine_wait
  wine_busy=0
  [[ -f "$STEAM_DIR/steam.exe" ]] || fail "Valve's installer ended without installing Steam. Details are in $LOGS/install.log."
}

# launch <args...>: Wine in the bottle, detached, so that it outlives this script and the app
launch() {
  ql_env
  mkdir -p "$LOGS"
  print -r -- "=== $(date '+%F %T') $*" >>"$LOGS/wine.log"
  ( cd "$BOTTLE" && env "${UNSET[@]}" "${E[@]}" nohup "$ENGINE/bin/wine" "$@" </dev/null >>"$LOGS/wine.log" 2>&1 & )
}
rotate_logs() {
  local f
  mkdir -p "$LOGS"
  for f in wine.log glmt.log; do
    [[ ! -s "$LOGS/$f" ]] || mv -f "$LOGS/$f" "$LOGS/$f.1"
    : >"$LOGS/$f"
  done
}
game_args() {
  local res=$(game_resolution) mode=()
  [[ "$res" != <->x<-> ]] || mode=(+set r_fullscreen 1 +set r_mode -1 +set r_customWidth "${res%x*}" +set r_customHeight "${res#*x}")
  print -r -- -applaunch "$QL_APPID" +set com_maxfps "$(fps)" +set r_swapInterval 0 $mode
}

# --- commands -----------------------------------------------------------------------------------
cmd_install() {
  need_mac
  lock
  log_to install
  bottle_running && [[ "$(components_state)" != ok ]] && fail "Quit Steam first: the engine's files can't be replaced while it runs."
  step 1 5 "The Wine engine"
  engine_ok || fetch_engine
  step 2 5 "glmt, OpenGL on Metal"
  [[ "$(components_state)" == ok ]] || apply_components
  step 3 5 "The game's bottle"
  make_bottle
  step 4 5 "Steam, from Valve"
  install_steam
  step 5 5 "Quake Live, in Steam"
  if [[ "$(game_state)" != ok ]]; then
    bottle_running || rotate_logs
    launch "$STEAM_EXE" "steam://install/$QL_APPID"
  fi
  print -r -- "@done"
}

cmd_play() {
  need_mac
  engine_ok || fail "Install first."
  [[ -f "$STEAM_DIR/steam.exe" && "$(game_state)" == ok ]] || fail "Quake Live is not installed yet."
  if game_running; then print -r -- "@done running"; return; fi
  lock
  if ! bottle_running; then
    [[ "$(components_state)" == ok ]] || apply_components
    apply_retina
    rotate_logs
  elif [[ "$(components_state)" != ok ]]; then
    fail "Quit Steam first: this version's files go into the engine before the game starts."
  fi
  glmt_installed || fail "glmt is not in the engine. Repair puts it back."
  launch "$STEAM_EXE" $(game_args)
  print -r -- "@done started"
}

cmd_steam() {
  need_mac
  engine_ok && [[ -f "$STEAM_DIR/steam.exe" ]] || fail "Install first."
  lock
  if ! bottle_running; then
    [[ "$(components_state)" == ok ]] || apply_components
    apply_retina
    rotate_logs
  fi
  launch "$STEAM_EXE" "steam://open/main"
  print -r -- "@done"
}

cmd_stop() {
  engine_ok || { print -r -- "@done"; return; }
  wine_stop
  print -r -- "@done"
}

cmd_repair() {
  need_mac
  lock
  log_to repair
  bottle_running && fail "Quit Steam first."
  step 1 3 "The Wine engine"
  if ! engine_ok || [[ ! -x "$ENGINE/bin/wine" || ! -f "$UNIX_DIR/ntdll.so" ]]; then fetch_engine; fi
  step 2 3 "glmt, OpenGL on Metal"
  apply_components
  step 3 3 "The game's bottle"
  rm -f "$BOTTLE/.ql-retina"
  make_bottle
  print -r -- "@done"
}

cmd_uninstall() {
  lock
  log_to uninstall
  if engine_ok; then wine_stop; fi
  bottle_running && fail "Steam or the game still runs. Quit them first."
  rm -rf "$ENGINE" "$ENGINE.new" "$BOTTLE" "$DOWNLOADS" "$SETTINGS" "$WORK/compatdb.rules"
  rm -rf "$LOCK"
  rmdir "$WORK" 2>/dev/null || true
  print -r -- "@done"
}

cmd_env() {
  ql_env
  print -r -l -- "${E[@]}"
  print -r -- "args: $(game_args)"
}

case "${1:-}" in
  status) status ;;
  install) cmd_install ;;
  play) cmd_play ;;
  steam) cmd_steam ;;
  stop) cmd_stop ;;
  set) shift; cmd_set "$@" ;;
  repair) cmd_repair ;;
  uninstall) cmd_uninstall ;;
  env) cmd_env ;;
  *) print -r -- "usage: qlom.zsh status | install | play | steam | stop | set <key> <value> | repair | uninstall | env" >&2; exit 2 ;;
esac

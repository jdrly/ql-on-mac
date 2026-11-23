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
#   qlom.zsh stop             ends the bottle's Wine session (Steam and the game): Steam is asked
#                             to quit first, so that it finishes syncing, then the session ends
#   qlom.zsh set fps 125|250
#   qlom.zsh set retina on|off
#   qlom.zsh set quitsteam on|off   whether the app quits Steam when the game has quit
#   qlom.zsh set steambg on|off     whether Play starts Steam without its window (-silent). Only
#                                   once Steam remembers a login: before that its window has to
#                                   show, to sign in
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
# Steam's own arguments, at every start. -cef-disable-gpu: Steam's web helper (Chrome) deadlocks
# on some starts on this engine's ntdll.so, when its sampler suspends a thread inside dlopen while
# the in-process GPU thread loads a library (jdrly/gw2-on-mac#304 has the stacks; seen here on
# 2026-11-21 and at the app's first install on 2026-11-23). Without the GPU thread the two never
# meet. Steam then draws its own window in software; the game is not touched by this.
STEAM_ARGS=(-cef-disable-gpu)
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
# With the stand-in engine nothing of the test runs as a process a check could find, and a real
# game or Steam on the same machine must not be taken for the test's (it was, on 2026-11-23: nine
# checks failed on the Mac while Quake Live ran there).
if (( sandbox )) && [[ -n "${QLOM_TEST_ENGINE:-}" ]]; then
  # QLOM_TEST_RUNNING="session game steam" says which of them the test wants to be there
  game_running() { [[ " ${QLOM_TEST_RUNNING:-} " == *" game "* ]]; }
  bottle_running() { [[ " ${QLOM_TEST_RUNNING:-} " == *" session "* ]]; }
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
quitsteam() { local v=$(setting quitsteam on); [[ "$v" == on || "$v" == off ]] || v=on; print -r -- $v; }
steambg() { local v=$(setting steambg on); [[ "$v" == on || "$v" == off ]] || v=on; print -r -- $v; }
# Steam has a login it will use by itself at its next start (its own record, as GW2 on Mac reads it)
steam_remembers_login() {
  awk -F'"' 'tolower($2) == "rememberpassword" && $4 == "1" { f = 1 } END { exit !f }' "$STEAM_DIR/config/loginusers.vdf" 2>/dev/null
}
cmd_set() {
  local key=${1:-} value=${2:-}
  case "$key=$value" in
    fps=125|fps=250|retina=on|retina=off|quitsteam=on|quitsteam=off|steambg=on|steambg=off) ;;
    *) fail "usage: set fps 125|250, set retina on|off, set quitsteam on|off, set steambg on|off" ;;
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
  # 4 is "fully installed"; Steam adds bits to it while the game runs or an update waits
  if [[ -f "$QL_DIR/$QL_EXE_NAME" && "$flags" == <-> ]] && (( flags & 4 )); then print -r -- ok
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
  print -r -- "quitsteam=$(quitsteam)"
  print -r -- "steambg=$(steambg)"
  print -r -- "steam_login=$(steam_remembers_login && print yes || print no)"
  print -r -- "display_pixels=${sizes[1]:-}"
  print -r -- "display_points=${sizes[2]:-}"
  print -r -- "busy=$([[ -d "$LOCK" ]] && print yes || print no)"
  print -r -- "launch=$(launch_stage)"
  print -r -- "logs=$LOGS"
}

# --- where a start of the game is ------------------------------------------------------------
# Play leaves a note (.launch: when, whether Steam already ran, the time as Steam's logs write
# it). From it and from what Steam and glmt have written since, status says how far the start
# is, so that the window is not silent for the half minute Steam takes without its window:
#   steam        Wine and Steam are coming up
#   steamupdate  Steam is downloading or installing a new version of itself
#   signin       Steam runs and has not logged on since
#   update       Steam is bringing the game up to date first
#   game         Steam is logged on (or was already running): the game is being started
#   (empty)      no start is under way: none was asked for, or the game draws
#   failed       the session ended before the game came
#   stalled      three minutes and no game (longer where an update or a sign-in by hand runs)
# failed and stalled are said once: the note goes with them.
# Steam's logs start their lines with [2026-11-23 01:50:24], local time.
steam_log_last() { # <log> <since>: the last dated line written since then
  awk -v t="$2" '/^\[20/ && substr($0, 2, 19) >= t { l = $0 } END { print l }' "$STEAM_DIR/logs/$1" 2>/dev/null || true
}
steam_log_has() { # <log> <since> <text>
  awk -v t="$2" -v s="$3" '/^\[20/ && substr($0, 2, 19) >= t && index($0, s) { f = 1 } END { exit !f }' "$STEAM_DIR/logs/$1" 2>/dev/null
}
launch_stage_now() { # <warm|cold> <since>
  local line on=0
  [[ "$1" == warm ]] || steam_log_has connection_log.txt "$2" "[Logged On," && on=1
  # Steam's own update comes before its log-on. Once it is logged on it goes on looking for
  # updates in the background and writes the same lines: those are not this start's.
  if (( ! on )); then
    case "$(steam_log_last bootstrap_log.txt "$2")" in
      *"Downloading update"*|*"Download complete"*|*"Extracting package"*|*"Installing update"*|*"Committing"*|*"Cleaning up"*)
        print -r -- steamupdate; return ;;
    esac
  fi
  line=$(awk -v t="$2" -v s="AppID $QL_APPID state changed" '/^\[20/ && substr($0, 2, 19) >= t && index($0, s) { l = $0 } END { print l }' \
    "$STEAM_DIR/logs/content_log.txt" 2>/dev/null || true)
  case "$line" in *"Update Required"*|*"Update Running"*|*"Update Started"*) print -r -- update; return ;; esac
  if (( on )); then print -r -- game; return; fi
  steam_running && print -r -- signin || print -r -- steam
}
launch_stage() {
  local note="$WORK/.launch" t0 warm stamp age stage limit=180
  [[ -f "$note" ]] || return 0
  read -r t0 warm stamp <"$note" || true
  [[ "$t0" == <-> ]] || { rm -f "$note"; return 0; }
  age=$(( $(date +%s) - t0 ))
  if game_running; then
    # the game draws once glmt has written its first lines since the start
    if [[ -n "$(find "$LOGS/glmt.log" -newer "$note" -size +0 2>/dev/null)" ]] || (( age > 120 )); then
      rm -f "$note"
      return 0
    fi
    print -r -- game; return 0
  fi
  if (( age > 12 )) && ! bottle_running; then rm -f "$note"; print -r -- failed; return 0; fi
  stage=$(launch_stage_now "$warm" "$stamp")
  case "$stage" in
    steamupdate|update) limit=1800 ;;
    signin) steam_remembers_login || limit=900 ;;   # someone is typing a password
  esac
  if (( age > limit )); then rm -f "$note"; print -r -- stalled; return 0; fi
  print -r -- "$stage"
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
    launch "$STEAM_EXE" $STEAM_ARGS "steam://install/$QL_APPID"
  fi
  print -r -- "@done"
}

cmd_play() {
  need_mac
  engine_ok || fail "Install first."
  [[ -f "$STEAM_DIR/steam.exe" && "$(game_state)" == ok ]] || fail "Quake Live is not installed yet."
  if game_running; then print -r -- "@done running"; return; fi
  lock
  local warm=cold
  if ! bottle_running; then
    [[ "$(components_state)" == ok ]] || apply_components
    apply_retina
    rotate_logs
  elif [[ "$(components_state)" != ok ]]; then
    fail "Quit Steam first: this version's files go into the engine before the game starts."
  fi
  # a Steam that is already there is logged on (or shows its window): nothing to wait for
  ! steam_running || warm=warm
  glmt_installed || fail "glmt is not in the engine. Repair puts it back."
  # Without its window once it can sign in by itself: it signs in, starts the game and stays out
  # of sight. A Steam that already runs keeps the window it has.
  local silent=()
  [[ "$(steambg)" != on ]] || ! steam_remembers_login || silent=(-silent)
  print -r -- "$(date +%s) $warm $(date '+%Y-%m-%d %H:%M:%S')" >"$WORK/.launch"
  launch "$STEAM_EXE" $STEAM_ARGS $silent $(game_args)
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
  launch "$STEAM_EXE" $STEAM_ARGS "steam://open/main"
  print -r -- "@done"
}

# Steam itself is there (not its web helper or its service), by the name Wine gives the process
if (( sandbox )) && [[ -n "${QLOM_TEST_ENGINE:-}" ]]; then
  steam_running() { [[ " ${QLOM_TEST_RUNNING:-} " == *" steam "* ]]; }
else
  steam_running() { [[ -n "$(ps -axww -o command= 2>/dev/null | grep -i '[\\/]steam\.exe' || true)" ]]; }
fi

# stop: Steam's own way out first (steam.exe -shutdown), so that it finishes what it is doing:
# after a game that is the sync of the game's config to Steam Cloud. Twenty seconds for that,
# then the session ends whatever is left in it.
cmd_stop() {
  rm -f "$WORK/.launch"
  engine_ok || { print -r -- "@done"; return; }
  if bottle_running && [[ -f "$STEAM_DIR/steam.exe" ]] && steam_running; then
    launch "$STEAM_EXE" -shutdown
    local i
    for i in {1..40}; do
      sleep 0.5
      steam_running || break
    done
  fi
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
  rm -rf "$ENGINE" "$ENGINE.new" "$BOTTLE" "$DOWNLOADS" "$SETTINGS" "$WORK/compatdb.rules" "$WORK/.launch"
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

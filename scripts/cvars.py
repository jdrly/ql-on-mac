#!/usr/bin/env python3
"""Quake Live's saved variables: which are the game's own, which a config once made.

    cvars.py report|trim <Quake Live's folder> <backup folder>

The game has room for 2,048 variables (cvars) and ends with "ERR_FATAL: MAX_CVARS" when a 2,049th
is made (read in quakelive_steam.exe: cmp eax, 0x800 before the error, twice). Every "seta" line
of repconfig.cfg and qzconfig.cfg takes one of them at start, whether or not anything still reads
it, and the game writes them all back when it ends. A config carried along since Quake III
(OSP, CPMA, PunkBuster, old Quake Live) can so fill a third of the table, and a match with bots,
which loads the server's variables too, then runs out (2026-11-22: at the match's start).

report  counts and lists: the game's own (the name is a string in the exe or one of the three game
        DLLs), named only in the pk3s' scripts and pages, and named nowhere. Of the last kind:
        reached (a bind's command or a game variable's value names it, directly or through other
        such variables) and not reached. Values are never printed.
trim    writes repconfig.cfg and qzconfig.cfg without the lines of the variables named nowhere and
        not reached (and never one whose name begins with web_: the menu makes those). The files
        as they were go to the backup folder first. Not while the game or Steam runs: the game
        writes its configs when it ends, and Steam Cloud carries them to the other computers.
        A config executed by hand that sets such variables brings them back.
"""
import os
import re
import shutil
import sys
import time
import zipfile

CONFIGS = ("repconfig.cfg", "qzconfig.cfg")
DLLS = ("qagamex86.dll", "cgamex86.dll", "uix86.dll")
TEXTS = (".js", ".html", ".htm", ".cfg", ".txt", ".menu", ".json", ".css", ".factories", ".h", ".c", ".script")
SET = re.compile(rb"(?i)^\s*set[aus]?\s+(\"[^\"]+\"|\S+)\s*(.*)$")
BIND = re.compile(rb"(?i)^\s*bind\s+\S+\s+(.*)$")
NAME_CHARS = b"abcdefghijklmnopqrstuvwxyz0123456789_+-."


def home_of(game):
    """The folder the game keeps its configs in: <game>/<SteamID>/baseq3."""
    found = [os.path.join(game, d, "baseq3") for d in sorted(os.listdir(game)) if d.isdigit()]
    found = [h for h in found if os.path.isfile(os.path.join(h, CONFIGS[0]))]
    if len(found) != 1:
        sys.exit("cvars: expected one <SteamID>/baseq3 with %s under %s, found %d" % (CONFIGS[0], game, len(found)))
    return found[0]


def read_config(path):
    """(lines as bytes, {name: (line index, value)}, [bind commands])."""
    lines = open(path, "rb").read().splitlines(keepends=True) if os.path.isfile(path) else []
    sets, binds = {}, []
    for i, line in enumerate(lines):
        m = SET.match(line.rstrip(b"\r\n"))
        if m:
            sets[m.group(1).strip(b'"').decode("latin-1")] = (i, m.group(2))
            continue
        m = BIND.match(line.rstrip(b"\r\n"))
        if m:
            binds.append(m.group(1))
    return lines, sets, binds


def game_strings(game, home):
    """The exe and the game DLLs, lowercase, and the text files of the pk3s, lowercase."""
    blob = open(os.path.join(game, "quakelive_steam.exe"), "rb").read().lower() + b"\0"
    packs = []
    for name in sorted(os.listdir(os.path.join(game, "baseq3"))):
        if name.lower().endswith(".pk3"):
            try:
                packs.append(zipfile.ZipFile(os.path.join(game, "baseq3", name)))
            except (OSError, zipfile.BadZipFile):
                print("cvars: could not read %s, left out" % name)
    for dll in DLLS:
        path = os.path.join(home, dll)
        if os.path.isfile(path):
            blob += open(path, "rb").read().lower() + b"\0"
            continue
        for pack in packs:  # not unpacked yet: the game takes them from a pk3
            if dll in pack.namelist():
                blob += pack.read(dll).lower() + b"\0"
                break
        else:
            sys.exit("cvars: %s is neither in %s nor in a pk3: without it the game's own variables cannot be told" % (dll, home))
    text = b""
    for pack in packs:
        for info in pack.infolist():
            if os.path.splitext(info.filename)[1].lower() in TEXTS and info.file_size < 8000000:
                text += pack.read(info).lower() + b"\n"
    return blob, text


def in_binary(blob, name):
    """The name as a whole string in the binaries (ended by a NUL, not the tail of a longer name)."""
    n = name.lower().encode("latin-1") + b"\0"
    i = blob.find(n)
    while i >= 0:
        if i == 0 or blob[i - 1] not in NAME_CHARS:
            return True
        i = blob.find(n, i + 1)
    return False


def in_text(text, name):
    n = re.escape(name.lower().encode("latin-1"))
    return re.search(rb"(?<![a-z0-9_])" + n + rb"(?![a-z0-9_])", text) is not None


def words(command):
    return {w.lower().decode("latin-1") for w in re.split(rb"[^A-Za-z0-9_+.\-/]+", command) if w}


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("report", "trim"):
        sys.exit(__doc__)
    mode, game, backups = sys.argv[1:]
    home = home_of(game)
    files = {c: read_config(os.path.join(home, c)) for c in CONFIGS}
    values, binds = {}, []
    for c in CONFIGS:
        for name, (_, value) in files[c][1].items():
            values[name] = value
        binds += files[c][2]
    blob, text = game_strings(game, home)

    own, paged, made = [], [], []
    for name in values:
        (own if in_binary(blob, name) else paged if in_text(text, name) else made).append(name)
    by_lower = {n.lower(): n for n in made}
    todo, seen, reached = set(), set(), set()
    for b in binds:
        todo |= words(b)
    for n in own + paged:
        todo |= words(values[n])
    while todo:
        w = todo.pop()
        if w in seen:
            continue
        seen.add(w)
        if w in by_lower:
            reached.add(by_lower[w])
            todo |= words(values[by_lower[w]])
    kept_web = sorted((n for n in made if n.lower().startswith("web_") and n not in reached), key=str.lower)
    loose = sorted((n for n in made if n not in reached and not n.lower().startswith("web_")), key=str.lower)

    print("saved variables: %s; %d together, of the game's 2,048"
          % (", ".join("%d in %s" % (len(files[c][1]), c) for c in CONFIGS), len(values)))
    print("  the game's own (named in the exe or a game DLL): %d" % len(own))
    print("  named only in the pk3s' scripts and pages: %d" % len(paged))
    print("  named nowhere in the game: %d; reached from a bind or a game variable: %d; the menu's (web_): %d; "
          "neither: %d" % (len(made), len(reached), len(kept_web), len(loose)))
    if mode == "report":
        print("\nnamed nowhere and not reached (trim would take these out):\n  " + " ".join(loose))
        print("\nnamed nowhere, reached (kept):\n  " + " ".join(sorted(reached, key=str.lower)))
        print("\nnamed nowhere, the menu's (kept):\n  " + " ".join(kept_web))
        return

    if not loose:
        print("nothing to take out")
        return
    stamp = time.strftime("%Y%m%d-%H%M%S")
    os.makedirs(backups, exist_ok=True)
    drop = set(loose)
    for c in CONFIGS:
        lines, sets, _ = files[c]
        gone = {i for name, (i, _) in sets.items() if name in drop}
        if not gone:
            continue
        path = os.path.join(home, c)
        backup = os.path.join(backups, "%s.%s" % (c, stamp))
        shutil.copy2(path, backup)
        tmp = path + ".trim"
        with open(tmp, "wb") as out:
            out.writelines(line for i, line in enumerate(lines) if i not in gone)
        os.replace(tmp, path)
        print("%s: %d lines out, %d left; as it was: %s" % (c, len(gone), len(lines) - len(gone), backup))
    print("to take it back: copy the backup over the file while the game and Steam are not running")


if __name__ == "__main__":
    main()

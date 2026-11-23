#!/usr/bin/env python3
"""Reads a GLMT_FLIP_TRACE of ordinary play: where the held flips are.

    flipread.py trace.txt [glmt.log] [--window 250] [--from S] [--to S]

A flip is "held" when it is on the display more than 7.5 ms after its present (an unsynced flip
takes about 3.3 ms in the game), "composited" when more than 15 ms. The script answers three things:

  - how many flips are held, second by second (stretches with few flips are listed);
  - whether the held flips go with glmt's statistics window (--window frames, GLMT_STATS): the
    share held by the frame's place in the window. With glmt.log the windows are found by their
    lengths (250 / fps of each line); without it frame 0 is the trace's last swap, which is where a
    line fell only if the file was copied while the game ran;
  - how many are held outside the window's busy part and outside the slow stretches;
  - how long nextDrawable took on the game's thread, if the trace has W lines (N lines: on glmt's
    presenter thread, GLMT_PRESENT=async).

Times in the output are seconds from the trace's first swap.
"""
import bisect
import re
import sys


def main():
    args = sys.argv[1:]
    opts = {"--window": 250, "--from": 0.0, "--to": 1e12}
    files = []
    while args:
        a = args.pop(0)
        if a in opts:
            opts[a] = float(args.pop(0))
        else:
            files.append(a)
    if not files:
        sys.exit(__doc__)
    window = int(opts["--window"])

    swaps, flips, waits, own = [], [], [], []
    for line in open(files[0], errors="replace"):
        f = line.split()
        try:
            if f[0] == "S":
                swaps.append(float(f[1]))
            elif f[0] == "W":
                waits.append((float(f[1]), float(f[2])))
            elif f[0] == "N":
                own.append((float(f[1]), float(f[2])))
            elif f[0] == "F" and f[1] == "t" and float(f[3]) > float(f[2]):
                flips.append((float(f[2]), float(f[3])))
        except (IndexError, ValueError):
            pass  # a line cut off at the file's end
    if len(swaps) < 4 * window or not flips:
        sys.exit("too few swaps or unsynced flips in %s" % files[0])
    t0 = swaps[0]
    lo, hi = t0 + opts["--from"], t0 + opts["--to"]

    # the seconds that count: the game near its full rate (not a menu, not a load)
    per_s = {}
    for t in swaps:
        per_s[int(t - t0)] = per_s.get(int(t - t0), 0) + 1
    full = sorted(per_s.values())[int(len(per_s) * 0.9)]
    playing = {s for s, n in per_s.items() if n >= 0.6 * full and lo <= t0 + s < hi}
    print("%d swaps, %d unsynced flips, %.0f s; %d s with the game at 60%% or more of %d swaps a second"
          % (len(swaps), len(flips), swaps[-1] - t0, len(playing), full))

    # where a statistics line fell
    last = len(swaps) - 1
    how = "frame 0 is the trace's last swap (no log given)"
    if len(files) > 1:
        fps = [float(x) for x in re.findall(r"glmt: ([\d.]+) fps, per frame", open(files[1], errors="replace").read())]
        lengths = [window / x for x in fps if x > 0.0]
        n = min(150, len(lengths) - 8, len(swaps) // window - 8)
        best = None
        for e in range(len(swaps) - 1, len(swaps) - 1 - 6 * window, -1):
            d = [swaps[e - window * j] - swaps[e - window * (j + 1)] for j in range(n)]
            for skip in range(8):
                err = sorted(abs(d[j] - lengths[-1 - j - skip]) for j in range(n))[n // 2]
                if best is None or err < best[0]:
                    best = (err, e, skip)
        if n > 10 and best[0] < 0.001:
            last = best[1]
            how = "the log's lines found in the trace to %.2f ms (%d of them after the trace's end)" % (best[0] * 1e3, best[2])
        else:
            how = "the log's windows were NOT found in the trace: frame 0 is the trace's last swap"

    bins = 25
    held, total, composited = [0] * bins, [0] * bins, 0
    flips_s, held_s = {}, {}
    rows = []
    for p, f in flips:
        s = int(p - t0)
        if s not in playing:
            continue
        i = bisect.bisect_left(swaps, p - 1e-5)
        b = ((i - last - 1) % window) * bins // window
        d = f - p
        flips_s[s] = flips_s.get(s, 0) + 1
        composited += d > 0.015
        total[b] += 1
        if d > 0.0075:
            held[b] += 1
            held_s[s] = held_s.get(s, 0) + 1
        rows.append((s, b, d > 0.0075))
    n_flips, n_held = sum(total), sum(held)
    print("held: %d of %d flips (%.1f%%); over 15 ms: %d" % (n_held, n_flips, 100.0 * n_held / n_flips, composited))

    # the display's own hitches: how long the picture stood between two flips. Over 17 ms is a
    # refresh of a 60 Hz display that got no new frame.
    times = sorted(f for p, f in flips if int(p - t0) in playing)
    gaps = [(b - a) * 1000.0 for a, b in zip(times, times[1:]) if b - a < 0.5]
    if gaps:
        print("between two flips: over 12 ms %d times (one in %.1f s), over 17 ms %d (one in %.1f s), over 25 ms %d"
              % (sum(x > 12 for x in gaps), len(playing) / max(1, sum(x > 12 for x in gaps)), sum(x > 17 for x in gaps),
                 len(playing) / max(1, sum(x > 17 for x in gaps)), sum(x > 25 for x in gaps)))

    # slow stretches: seconds with under 80% of the median's flips
    median = sorted(flips_s.values())[len(flips_s) // 2]
    slow = sorted(s for s in playing if flips_s.get(s, 0) < 0.8 * median)
    runs = []
    for s in slow:
        if runs and s - runs[-1][1] <= 2:
            runs[-1][1] = s
        else:
            runs.append([s, s])
    print("median %d flips a second; stretches under 80%% of that: %d" % (median, len(runs)))
    for a, b in runs[:40]:
        print("  %5d to %5d s: %s" % (a, b, " ".join(str(flips_s.get(x, 0)) for x in range(a, b + 1))))
    starts = [a for a, b in runs]
    if len(starts) > 2:
        print("  their starts apart, s: %s" % " ".join(str(y - x) for x, y in zip(starts, starts[1:])))

    # W lines (builds since 2026-11-21 23:55): what nextDrawable cost the game's thread
    w = sorted(ms for t, ms in waits if int(t - t0) in playing)
    if w:
        print("nextDrawable on the game's thread, ms: median %.2f, 99%% %.2f, longest %.2f; over 1 ms: %d (%.1f a second), "
              "over 4 ms: %d" % (w[len(w) // 2], w[int((len(w) - 1) * 0.99)], w[-1], sum(x > 1.0 for x in w),
                                 sum(x > 1.0 for x in w) / max(1, len(playing)), sum(x > 4.0 for x in w)))

    # N lines (GLMT_PRESENT=async): the same call on glmt's presenter thread, where it holds nobody
    w = sorted(ms for t, ms in own if int(t - t0) in playing)
    if w:
        print("async: nextDrawable on glmt's own thread, ms: median %.2f, 99%% %.2f, longest %.2f; over 4 ms: %d; "
              "frames shown %d of %d swaps" % (w[len(w) // 2], w[int((len(w) - 1) * 0.99)], w[-1], sum(x > 4.0 for x in w),
                                               n_flips, sum(per_s[s] for s in playing)))

    share = [100.0 * h / t if t else 0.0 for h, t in zip(held, total)]
    print("held by the frame's place in the statistics window of %d frames (%s),\n  in 25 parts, %%: %s"
          % (window, how, " ".join("%.0f" % x for x in share)))
    quiet_bins = set(sorted(range(bins), key=lambda b: share[b])[: bins // 2])
    slow_s = {x for a, b in runs for x in range(a, b + 1)}
    q = [h for s, b, h in rows if b in quiet_bins and s not in slow_s]
    if q:
        print("held in the quieter half of the window, outside the slow stretches: %d of %d (%.1f%%)"
              % (sum(q), len(q), 100.0 * sum(q) / len(q)))


if __name__ == "__main__":
    main()

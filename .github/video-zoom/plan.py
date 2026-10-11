#!/usr/bin/env python3
"""plan.py - decide how far to zoom, and where the window sits, at every moment of a
1080p stage video.

Two rules, measured twice a second on a small grey copy of the picture:

1. Nobody on stage is cut off. The camera operator already zooms in and out, so this
   measures how wide the people/stage content is (the black wings do not count) and
   allows only as much zoom as keeps that content inside a centred window, up to ZMAX.
2. No audience in the picture. The audience sits at the bottom of the frame: on a lit
   stage floor it is the dark band below the stage's front edge plus any dark figure
   rising from it; in dark spotlight scenes it shows as lit faces along the bottom edge,
   outside the spotlight's columns. The window's bottom edge must stay above that band,
   which sets a minimum zoom and pushes the window up when needed. Rule 2 wins when the
   two conflict (the sides then lose a little), and may push the zoom past ZMAX up to ZAUD.

Both curves are slope-limited (SLOPE zoom per second, VSLOPE pixels per second for the
window's bottom edge) so the picture moves like a slow, steady camera push, never a jump,
and the zoom is 1.0 outside [START, END].

usage: plan.py IN OUT_DIR ZMAX YSHIFT START END FPS [OFFSET] [CUT]
writes: OUT_DIR/zoom.expr    ffmpeg expression: zoom factor at time t (t counted from OFFSET)
        OUT_DIR/bottom.expr  ffmpeg expression: lowest allowed window bottom, in source pixels
        OUT_DIR/plan.csv     t, left, right, audience_top, allowed, zoom, bottom
        OUT_DIR/boxes.txt    every 30 s: t cw ch x y (for the review sheet)
        OUT_DIR/summary.txt
"""
import sys, subprocess, numpy as np

inp, out = sys.argv[1], sys.argv[2]
ZMAX, YS, S, E, FPS = (float(v) for v in sys.argv[3:8])
OFF = float(sys.argv[8]) if len(sys.argv) > 8 else 0.0
CUT = float(sys.argv[9]) if len(sys.argv) > 9 and float(sys.argv[9]) > 0 else None   # film ends here: later samples are free
W, H = 1920, 1080
SW, SH, RATE = 240, 135, 2          # analysis resolution and samples per second
BAND = (0.48, 0.76)                  # rows (fraction of height) where people stand, below the side screens
BRIGHT, FRACTION, MARGIN = 60, 0.15, 40
AUD_MARGIN = 32                      # pixels kept clear above the detected audience
SLOPE, VSLOPE = 0.06, 60.0           # zoom per second, window-bottom pixels per second
ZAUD = 1.40                          # the zoom may go this far (above ZMAX) only to keep the audience out
TOL, VTOL = 0.004, 3.0               # curve simplification tolerances

def audience_top(g):
    """Row above which the picture is free of the audience, and which case applied."""
    F = float(np.median(g[int(0.60 * SH):int(0.85 * SH), int(0.25 * SW):int(0.75 * SW)]))
    if F >= 25:                                           # lit stage floor
        dark = g < max(0.45 * F, 18)
        rowfrac = dark.mean(axis=1)
        edge = SH; r = SH - 1
        while r >= int(0.70 * SH) and rowfrac[r] > 0.5:   # the dark band below the stage edge
            edge = r; r -= 1
        # heads along the bottom edge, possibly rising above the band: dark runs from the
        # bottom, per column, with short gaps allowed for lit faces
        lim = int(0.15 * SH); c0, c1 = int(0.08 * SW), int(0.92 * SW)
        runs = np.zeros(SW, dtype=int)
        for c in range(c0, c1):
            k = 0; gap = 0; last = 0
            while k < lim:
                if dark[SH - 1 - k, c]:
                    last = k + 1; gap = 0
                else:
                    gap += 1
                    if gap > 6:
                        break
                k += 1
            runs[c] = last
        sm = np.array([np.median(runs[max(c0, c - 2):min(c1, c + 3)]) for c in range(c0, c1)])
        heads = int(SH - sm.max())
        top = min(edge, heads)
        return top, "lit"
    # dark floor: lit faces along the bottom edge, outside the spotlight's columns
    lit = g > 70
    spot = lit[int(0.50 * SH):int(0.80 * SH), :].mean(axis=0) > 0.10
    cols = np.ones(SW, dtype=bool)
    if spot.any():
        c0, c1 = np.flatnonzero(spot)[[0, -1]]
        cols[max(0, c0 - 5):c1 + 6] = False
    if not cols.any():
        return SH, "dark"
    outside = lit[:, cols].mean(axis=1)
    top = SH; gap = 0
    for r in range(SH - 1, int(0.75 * SH) - 1, -1):
        if outside[r] > 0.02:
            top = r; gap = 0
        else:
            gap += 1
            if gap > 1:
                break
    return top, "dark"

raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', inp, '-vf', f'fps={RATE},scale={SW}:{SH}:flags=area,format=gray',
                      '-f', 'rawvideo', 'pipe:1'], capture_output=True).stdout
n = len(raw) // (SW * SH)
fr = np.frombuffer(raw[:n * SW * SH], dtype=np.uint8).reshape(n, SH, SW)
t = np.arange(n) / RATE
inside = (t >= S) & (t <= E)

# rule 1: horizontal content extent -> most zoom allowed
band = fr[:, int(BAND[0] * SH):int(BAND[1] * SH), :]
content = (band > BRIGHT).mean(axis=1) > FRACTION
left = np.full(n, np.nan); right = np.full(n, np.nan); allowed = np.full(n, ZMAX)
for i in range(n):
    cols = np.flatnonzero(content[i])
    if cols.size == 0:
        continue
    l = cols[0] * W / SW; r = (cols[-1] + 1) * W / SW
    left[i] = l; right[i] = r
    half = max(W / 2 - l, r - W / 2) + MARGIN
    allowed[i] = min(ZMAX, max(1.0, (W / 2) / half))
allowed[~inside] = 1.0
if CUT is not None:
    allowed[(t > CUT) & inside] = ZMAX

# rule 2: audience band -> lowest allowed window bottom
aud = np.full(n, float(H)); how = [""] * n
for i in range(n):
    row, how[i] = audience_top(fr[i])
    aud[i] = row * H / SH
bottom = np.minimum(aud - AUD_MARGIN, H)
bottom[~inside] = H
if CUT is not None:
    bottom[(t > CUT) & inside] = H

# slope-limited curves
step = SLOPE / RATE; vstep = VSLOPE / RATE
zhi = allowed.copy()                                  # lower envelope of "allowed"
for i in range(1, n): zhi[i] = min(zhi[i], zhi[i - 1] + step)
for i in range(n - 2, -1, -1): zhi[i] = min(zhi[i], zhi[i + 1] + step)
benv = bottom.copy()                                  # lower envelope of the window bottom
for i in range(1, n): benv[i] = min(benv[i], benv[i - 1] + vstep)
for i in range(n - 2, -1, -1): benv[i] = min(benv[i], benv[i + 1] + vstep)
need = np.maximum(1.0, H / np.maximum(benv, 1.0))     # zoom needed to fit above the audience
need[~inside] = 1.0
zlo = need.copy()                                     # upper envelope of "need"
for i in range(1, n): zlo[i] = max(zlo[i], zlo[i - 1] - step)
for i in range(n - 2, -1, -1): zlo[i] = max(zlo[i], zlo[i + 1] - step)
z = np.maximum(zhi, np.minimum(zlo, ZAUD))
z[~inside] = 1.0

def rdp(arr, idx, tol):
    a, b = idx[0], idx[-1]
    if b - a < 2:
        return [a, b]
    seg = arr[a] + (arr[b] - arr[a]) * (t[a:b + 1] - t[a]) / (t[b] - t[a])
    dev = np.abs(arr[a:b + 1] - seg); k = int(np.argmax(dev))
    if dev[k] <= tol:
        return [a, b]
    return rdp(arr, list(range(a, a + k + 1)), tol)[:-1] + rdp(arr, list(range(a + k, b + 1)), tol)

def expression(arr, tol, fmt, outside):
    knots = rdp(arr, list(range(n)), tol) if n > 1 else [0]
    kt = [t[i] - OFF for i in knots]; kv = [float(arr[i]) for i in knots]
    terms = []
    for i in range(len(knots) - 1):
        t0, t1, v0, v1 = kt[i], kt[i + 1], kv[i], kv[i + 1]
        if t1 < 0:
            continue
        slope = (v1 - v0) / (t1 - t0)
        terms.append(f"gte(t,{t0:.3f})*lt(t,{t1:.3f})*({fmt % v0}+{slope:.6f}*(t-{t0:.3f}))")
    if not terms:
        return str(outside), len(knots)
    return "(" + "+".join(terms) + f"+gte(t,{kt[-1]:.3f})*{outside}+lt(t,{kt[0]:.3f})*{outside})", len(knots)

sys.setrecursionlimit(10000)
zexpr, zk = expression(z, TOL, "%.4f", 1)
bexpr, bk = expression(benv, VTOL, "%.1f", H)
open(f"{out}/zoom.expr", "w").write(zexpr)
open(f"{out}/bottom.expr", "w").write(bexpr)

def window(zf, bf):
    cw = int(W / zf / 2) * 2; ch = int(H / zf / 2) * 2
    x = int((W - cw) / 4) * 2
    y = (H - ch) / 2 + YS * ch
    y = min(y, bf - ch)
    y = int(min(max(y, 0), H - ch) / 2) * 2
    return cw, ch, x, y

with open(f"{out}/plan.csv", "w") as fh:
    fh.write("t,left,right,audience_top,case,allowed,zoom,bottom\n")
    for i in range(n):
        fh.write(f"{t[i]:.1f},{left[i]:.0f},{right[i]:.0f},{aud[i]:.0f},{how[i]},{allowed[i]:.3f},{z[i]:.3f},{benv[i]:.0f}\n")
with open(f"{out}/boxes.txt", "w") as fh:
    tt = S
    while n and tt <= min(E, t[-1]):
        cw, ch, x, y = window(float(np.interp(tt, t, z)), float(np.interp(tt, t, benv)))
        fh.write(f"{tt:.0f} {cw} {ch} {x} {y}\n")
        tt += 30
zi = z[inside] if inside.any() else z
with open(f"{out}/summary.txt", "w") as fh:
    fh.write(f"samples {n} at {RATE}/s; zoom knots {zk} ({len(zexpr)} chars), bottom knots {bk} ({len(bexpr)} chars)\n")
    fh.write(f"zoom inside [{S:.0f},{E:.0f}]: mean {zi.mean():.3f}, min {zi.min():.3f}, max {zi.max():.3f}\n")
    for lv in (1.25, 1.2, 1.15, 1.1, 1.05):
        fh.write(f"  time at >= {lv}x: {100 * (zi >= lv).mean():.0f}%\n")
    ai = aud[inside]
    fh.write(f"audience top inside: median {np.median(ai):.0f}px, lowest {ai.min():.0f}px; "
             f"dark-floor samples {100 * np.mean([h == 'dark' for h, k in zip(how, inside) if k]):.0f}%\n")
    short = inside & (benv < H / z)                     # window taller than the room above the audience
    fh.write(f"audience not fully excluded (zoom cap reached): {100 * short[inside].mean():.1f}% of the time\n")
    fh.write("tightest moments (sides allowed < 1.1x):\n")
    runs = []; start = None
    for i in range(n):
        tight = inside[i] and allowed[i] < 1.1
        if tight and start is None: start = t[i]
        if not tight and start is not None: runs.append((start, t[i])); start = None
    if start is not None: runs.append((start, t[-1]))
    for a, b in runs[:60]:
        fh.write(f"  {a:7.1f}s - {b:7.1f}s\n")
print(open(f"{out}/summary.txt").read())

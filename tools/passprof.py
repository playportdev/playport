#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The [pass-prof] lines of one run (Settings' Diagnostics, GPU time per pass:
DXMT_PASS_PROF=1, patches/dxmt 0008) as tables: each sampled frame, then the
passes that cost most GPU time a frame, alike passes together.

  passprof.py LOG          print the tables of an s1-host.log

winemetal samples every encoder of two frames in every 1200 presents (the first
at present 600) and prints, 12 presents later, one line per encoder, then one
per frame:

  [pass-prof] report N at present P: ...
  [pass-prof]  fF pI cbC WxH xS c0=FMT/LS d=FMT/LS st draws=D prims=P vtx=MS frag=MS v@.. f@A..B
  [pass-prof]  fF pI cbC blit|compute gpu=MS at=A..B
  [pass-prof] frame F: N passes, D draws, sum vtx MS ms, sum frag MS ms, span MS ms

A pass's cost is its vertex plus fragment time (a blit's or compute's, its
gpu time); the two stages overlap on the GPU, so a frame's sum can exceed its
span, and a span across command buffers includes the time between them.
Alike passes share a kind, size and attachments (format/load-store).
"""

import re
import sys

PASS = re.compile(r"\[pass-prof\]  f(\d+) p(\d+) cb(\d+) (.*)$")
RENDER = re.compile(r"(\d+x\d+) x(\d+) (.*?)\s*draws=(\d+) prims=(\d+) vtx=([\d.]+) frag=([\d.]+)")
OTHER = re.compile(r"(blit|compute) gpu=([\d.]+)")
FRAME = re.compile(r"\[pass-prof\] frame (\d+): (\d+) passes, (\d+) draws, sum vtx ([\d.]+) ms, "
                   r"sum frag ([\d.]+) ms, span ([\d.]+) ms")
REPORT = re.compile(r"\[pass-prof\] report (\d+) at present (\d+):")


def parse(lines):
    """[{report, present, frame, passes: [{kind, key, draws, ms}], draws, vtx, frag, span}]"""
    frames, report, present, cur = [], None, None, {}
    for line in lines:
        if "[pass-prof]" not in line:
            continue
        if m := REPORT.search(line):
            report, present, cur = int(m[1]), int(m[2]), {}
        elif m := PASS.search(line):
            f = cur.setdefault(int(m[1]), [])
            rest = m[4]
            if r := RENDER.match(rest):
                key = f"{r[1]} x{r[2]} {r[3]}".strip()
                f.append({"kind": "render", "key": key, "draws": int(r[4]),
                          "ms": float(r[6]) + float(r[7]), "frag": float(r[7])})
            elif o := OTHER.match(rest):
                f.append({"kind": o[1], "key": o[1], "draws": 0, "ms": float(o[2]), "frag": 0.0})
        elif m := FRAME.search(line):
            frames.append({"report": report, "present": present, "frame": int(m[1]),
                           "passes": cur.get(int(m[1]), []), "draws": int(m[3]),
                           "vtx": float(m[4]), "frag": float(m[5]), "span": float(m[6])})
    return frames


def report(lines):
    """The tables as text; "" when the run has no [pass-prof] frame."""
    frames = parse(lines)
    if not frames:
        return ""
    out = ["sampled frames (ms; a pass's cost is vertex + fragment, a blit's or compute's its gpu time)",
           f"{'report':>6} {'present':>7} {'frame':>5} {'passes':>6} {'draws':>5} {'vtx':>7} {'frag':>7} {'span':>7}"]
    for f in frames:
        out.append(f"{f['report']:>6} {f['present']:>7} {f['frame']:>5} {len(f['passes']):>6} {f['draws']:>5} "
                   f"{f['vtx']:>7.3f} {f['frag']:>7.3f} {f['span']:>7.3f}")
    n = len(frames)
    groups = {}
    for f in frames:
        for p in f["passes"]:
            g = groups.setdefault(p["key"], {"ms": 0.0, "count": 0, "draws": 0})
            g["ms"] += p["ms"]
            g["count"] += 1
            g["draws"] += p["draws"]
    total = sum(g["ms"] for g in groups.values())
    out += ["", f"alike passes over the {n} sampled frames, by GPU time a frame",
            f"{'ms/frame':>8} {'share':>6} {'passes':>6} {'draws':>6}  pass (a frame's passes and draws)"]
    for key, g in sorted(groups.items(), key=lambda kv: -kv[1]["ms"])[:30]:
        out.append(f"{g['ms'] / n:>8.3f} {100 * g['ms'] / total if total else 0:>5.1f}% {g['count'] / n:>6.2f} "
                   f"{g['draws'] / n:>6.1f}  {key}")
    out.append(f"{total / n:>8.3f} total a frame")
    return "\n".join(out) + "\n"


def main(argv):
    if len(argv) != 1:
        sys.exit(__doc__)
    with open(argv[0], errors="replace") as f:
        text = report(f.readlines())
    if not text:
        sys.exit(f"{argv[0]}: no [pass-prof] frame (was GPU time per pass on in Settings' Diagnostics?)")
    print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

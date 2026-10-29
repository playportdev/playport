#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tables from one run's [pass-prof] lines (Settings › Diagnostics › GPU time
per pass; DXMT_PASS_PROF / MESA_KK_PASS_PROF). Usage: passprof.py LOG.

Both drivers sample two frames every 1200 presents, first at 600. DXMT reports
vertex + fragment stage time (overlapping stages can exceed the frame span).
KosmicKrisp reports encoder-boundary elapsed GPU time, in ms, not stage time;
its frame span includes gaps between encoders/command buffers. Pipeline limits
are proxies, NOT register/spill counts: max_threads can be capped by the
requested workgroup size, and render pipelines may report no limit (0).
Native-copy/empty compute encoders, including copy + dispatch mixtures, report
NA rather than a false zero. GPU sums exclude them and are explicitly partial;
the span is the extent of valid sampled timestamps, not GPU busy time (PLA-474).
"""

import re
import sys

PASS = re.compile(r"\[pass-prof\]  f(\d+) p(\d+) cb(\d+) (.*)$")
RENDER = re.compile(r"(\d+x\d+) x(\d+) (.*?)\s*draws=(\d+) prims=(\d+) vtx=([\d.]+) frag=([\d.]+)")
ENCODER_RENDER = re.compile(r"render (\d+x\d+) x(\d+)(.*?) draws=(\d+) gpu=([\d.]+)")
OTHER = re.compile(r"(blit|compute) gpu=(NA|[\d.]+)")
FRAME = re.compile(r"\[pass-prof\] frame (\d+): (\d+) passes, (\d+) draws, sum vtx ([\d.]+) ms, "
                   r"sum frag ([\d.]+) ms, span ([\d.]+) ms")
ENCODER_FRAME = re.compile(r"\[pass-prof\] frame (\d+): (\d+) passes, (\d+) draws, sum gpu ([\d.]+) ms, "
                           r"span (NA|[\d.]+) ms(?:, untimed (\d+))?")
REPORT = re.compile(r"\[pass-prof\] report (\d+) at present (\d+):")
PIPELINE = re.compile(r"\[pass-prof\] pipeline (\S+) kind=(render|compute) msl=([a-f0-9]+) "
                      r"max_threads=(\d+) static_tg_bytes=(\d+) requested_threads=(\d+)")
PIPE_REF = re.compile(r"\bpipeline=(\S+)")


def parse(lines):
    """Complete sampled frames; passes retain index/cb and pipeline-limit metadata.

    Pipeline pointers are run-local references, resolved when a pass is read,
    never grouping keys. Hashes survive address reuse and comparisons of runs.
    Unknown/mixed pipelines are explicit, not assigned the last bound shader.
    A truncated frame is excluded, never silently treated as a cheap frame.
    """
    frames, pipelines, report_id, present, cur = [], {}, None, None, {}
    for line in lines:
        if "[pass-prof]" not in line:
            continue
        if m := PIPELINE.search(line):
            pipelines[m[1]] = {"kind": m[2], "msl": m[3], "max_threads": int(m[4]),
                               "static_tg_bytes": int(m[5]), "requested_threads": int(m[6])}
        elif m := REPORT.search(line):
            report_id, present, cur = int(m[1]), int(m[2]), {}
        elif m := PASS.search(line):
            rest, p = m[4], None
            if r := RENDER.match(rest):
                key = f"{r[1]} x{r[2]} {r[3]}".strip()
                p = {"kind": "render", "key": key, "draws": int(r[4]),
                     "ms": float(r[6]) + float(r[7]), "frag": float(r[7])}
            elif r := ENCODER_RENDER.match(rest):
                p = {"kind": "render", "key": f"{r[1]} x{r[2]}{r[3]}",
                     "draws": int(r[4]), "ms": float(r[5]), "frag": None}
            elif o := OTHER.match(rest):
                p = {"kind": o[1], "key": o[1], "draws": 0,
                     "ms": None if o[2] == "NA" else float(o[2]), "frag": 0.0}
            if p is not None:
                p.update(index=int(m[2]), cb=int(m[3]), pipeline=None)
                if ref := PIPE_REF.search(rest):
                    p["pipeline"] = pipelines.get(ref[1])
                    identity = p["pipeline"]["msl"] if p["pipeline"] else (
                        "mixed" if ref[1] == "mixed" else "unknown")
                    p["key"] += f" pipeline={identity}"
                if p["ms"] is None:
                    reason = re.search(r"\breason=(\S+)", rest)
                    p["key"] += f" unavailable={reason[1] if reason else 'not-reported'}"
                cur.setdefault(int(m[1]), []).append(p)
        elif (m := FRAME.search(line)) or (m := ENCODER_FRAME.search(line)):
            passes = cur.pop(int(m[1]), [])
            if report_id is None or len(passes) != int(m[2]):
                continue
            encoder = "sum gpu" in m[0]
            untimed = sum(p["ms"] is None for p in passes)
            if encoder and m[6] is not None and untimed != int(m[6]):
                continue
            span = m[5] if encoder else m[6]
            frames.append({"report": report_id, "present": present, "frame": int(m[1]),
                           "passes": passes, "draws": int(m[3]),
                           "gpu": float(m[4]) if encoder else None,
                           "vtx": None if encoder else float(m[4]),
                           "frag": None if encoder else float(m[5]),
                           "span": None if span == "NA" else float(span), "untimed": untimed})
    return frames


def report(lines):
    """The tables as text; empty when the run has no complete sampled frame."""
    frames = parse(lines)
    if not frames:
        return ""
    out = ["sampled frames (ms; KosmicKrisp: encoder elapsed; DXMT: vertex + fragment; intervals/stages may overlap)",
           "gpu/sums include known timings only; untimed copy/empty encoders are NOT free; span is sampled timestamp extent",
           f"{'report':>6} {'present':>7} {'frame':>5} {'passes':>6} {'draws':>5} {'untimed':>7} {'gpu':>9} {'vtx':>7} {'frag':>7} {'span':>9}"]

    def ms(value, width, precision=3):
        return f"{value:>{width}.{precision}f}" if value is not None else f"{'-':>{width}}"

    for f in frames:
        out.append(f"{f['report']:>6} {f['present']:>7} {f['frame']:>5} {len(f['passes']):>6} {f['draws']:>5} {f['untimed']:>7} "
                   f"{ms(f['gpu'], 9, 6)} {ms(f['vtx'], 7)} {ms(f['frag'], 7)} {ms(f['span'], 9, 6)}")
    n = len(frames)
    groups, unavailable, limits = {}, {}, {}
    for f in frames:
        for p in f["passes"]:
            if p["ms"] is None:
                unavailable[p["key"]] = unavailable.get(p["key"], 0) + 1
            else:
                g = groups.setdefault(p["key"], {"ms": 0.0, "count": 0, "draws": 0})
                g["ms"] += p["ms"]
                g["count"] += 1
                g["draws"] += p["draws"]
            if info := p["pipeline"]:
                key = (info["kind"], info["msl"], info["max_threads"],
                       info["static_tg_bytes"], info["requested_threads"])
                limits[key] = info
    total = sum(g["ms"] for g in groups.values())
    out += ["", f"alike passes over the {n} sampled frames, by known GPU time a frame",
            f"{'ms/frame':>8} {'share':>6} {'passes':>6} {'draws':>6}  pass (a frame's passes and draws)"]
    for key, g in sorted(groups.items(), key=lambda kv: -kv[1]["ms"])[:30]:
        out.append(f"{g['ms'] / n:>8.3f} {100 * g['ms'] / total if total else 0:>5.1f}% {g['count'] / n:>6.2f} "
                   f"{g['draws'] / n:>6.1f}  {key}")
    out.append(f"{total / n:>8.3f} total a frame" + (" (PARTIAL: known timings only)" if unavailable else ""))
    if unavailable:
        out += ["", "unavailable timings (excluded above, NOT zero GPU cost; PLA-474)",
                f"{'passes/frame':>12}  pass"]
        for key, count in sorted(unavailable.items(), key=lambda kv: -kv[1]):
            out.append(f"{count / n:>12.2f}  {key}")
    if limits:
        out += ["", "sampled pipeline limits (NOT register/spill counts; 0 max = unavailable; requested caps max)",
                "kind    MSL hash         max_threads static_tg_bytes requested_threads"]
        for key, info in sorted(limits.items()):
            out.append(f"{info['kind']:7} {info['msl']:16} {info['max_threads']:>11} "
                       f"{info['static_tg_bytes']:>15} {info['requested_threads']:>17}")
    return "\n".join(out) + "\n"


def main(argv):
    if len(argv) != 1:
        sys.exit(__doc__)
    with open(argv[0], errors="replace") as f:
        text = report(f.readlines())
    if not text:
        sys.exit(f"{argv[0]}: no complete [pass-prof] frame (was GPU time per pass on, capture off, and present 600 reached?)")
    print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

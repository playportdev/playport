#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Apple's GPU and trace tools on a Mac, driven without Xcode's window (decision 0165).

pp gpu live, profile and trace call these; docs/GPU-DEBUGGING.md#on-a-mac says what each
answers. Every tool here is Apple's command-line one:

  gpucapture   captures a running process that started with Metal's capture layer
               (pp ui --capture-layer) into a .gputrace on this Mac
  gpudebug     replays a .gputrace on the phone and profiles it (per-encoder, per-draw
               and per-shader GPU time, counters, limiters)
  xctrace      Instruments' recorder: Metal System Trace, Time Profiler, ... of the whole
               phone (--all-processes; attaching to Playport finds no process)

The phone is a remote device of these tools only while Xcode runs (its GPU tools agent
publishes it): ensure_agent() starts Xcode hidden, with no window, when it does not.
Nothing here builds, installs, launches or uninstalls the app.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import phonelib  # noqa: E402

PROCESS = "S1Probe"


def require():
    """Refuse off a Mac or without Apple's tools; the reason, or None."""
    if sys.platform != "darwin":
        return "Apple's GPU tools run on a Mac with Xcode 27 (docs/GPU-DEBUGGING.md#on-a-mac)"
    for t in ("gpucapture", "gpudebug", "xcrun"):
        if not shutil.which(t):
            return f"{t} is not on PATH: macOS 27 and Xcode 27 are needed"
    return None


def run(cmd, secs=120, check=True, log=None):
    """A tool's stdout; its stderr appended to LOG when given."""
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=secs)
    if log:
        with open(log, "a") as f:
            f.write(f"$ {' '.join(cmd)}\n[exit {r.returncode}]\n{r.stdout}{r.stderr}\n")
    if check and r.returncode != 0:
        tail = (r.stderr.strip() or r.stdout.strip()).splitlines()[-1:] or [""]
        raise phonelib.PhoneError(f"{os.path.basename(cmd[0])} {cmd[1] if len(cmd) > 1 else ''} failed "
                                  f"(exit {r.returncode}): {tail[0][:200]}")
    return r.stdout


def devices():
    """[(id, name, model, os version)] gpucapture can reach; id 0 is this Mac."""
    out = []
    for line in run(["gpucapture", "--list-devices"], 60).splitlines():
        f = re.split(r"\s{2,}", line.strip())
        if len(f) == 4 and f[0].isdigit():
            out.append((int(f[0]), f[1], f[2], f[3].split()[-1]))
    return out


def phone_device():
    """The phone's (id, name) for gpucapture and gpudebug, or None."""
    for d in devices():
        if d[0] != 0 and re.match(r"iP(hone|ad)", d[2]):
            return d[0], d[1]
    return None


def agent_running():
    return subprocess.run(["pgrep", "-x", "GPUToolsAgentService"], capture_output=True).returncode == 0


def ensure_agent(ev, wait=120):
    """The phone as gpucapture's and gpudebug's remote device: starts Xcode hidden (open -gj,
    no window, no project) when its GPU tools agent is not running, then waits for the phone."""
    started = False
    if phone_device() is None and not agent_running():
        subprocess.run(["open", "-g", "-j", "-a", "Xcode"], check=False)
        started = True
    t0 = time.monotonic()
    while time.monotonic() - t0 < wait:
        d = phone_device()
        if d:
            ev("gpu-tools", device=d[0], xcode_started=started, after_s=round(time.monotonic() - t0, 1))
            return d
        time.sleep(3)
    raise phonelib.PhoneError(f"the phone is not among gpucapture's devices after {wait} s "
                              "(gpucapture --list-devices): is it cabled and trusted, Developer Mode on?")


def capturable(device):
    """The pid of Playport's process gpucapture can capture on DEVICE, or None."""
    text = run(["gpucapture", "list"], 60, check=False)
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 3 and f[0].isdigit() and f[1] == str(device) and f[2] == PROCESS:
            return int(f[0])
    return None


BOUNDARY_RE = re.compile(r"^\s*(\d+)\s+(Device|Queue|Layer|Scope)\s+(.*?)\s+([\d.]+)\s+(\d+)\s*$")


def boundaries(pid, device, log=None):
    """[{id, type, label, gpu_ms, count}] of a capturable process."""
    rows = []
    for line in run(["gpucapture", "boundaries", "-p", str(pid), "-d", str(device)], 60, log=log).splitlines():
        m = BOUNDARY_RE.match(line)
        if m:
            rows.append({"id": int(m[1]), "type": m[2], "label": m[3], "gpu_ms": float(m[4]), "count": int(m[5])})
    return rows


def pick_boundary(rows, want):
    """The boundary WANT names: an id; layer (the CAMetalLayer that presented most), queue
    (the command queue with the most GPU time) or device."""
    if want.isdigit():
        hit = [r for r in rows if r["id"] == int(want)]
    else:
        hit = [r for r in rows if r["type"].lower() == want]
        key = (lambda r: r["count"]) if want == "layer" else (lambda r: r["gpu_ms"])
        hit.sort(key=key, reverse=True)
    if not hit:
        raise phonelib.PhoneError(f"no {want} boundary among {[(r['id'], r['type'], r['label']) for r in rows]}")
    return hit[0]


def capture(pid, device, boundary, count, path, log=None, secs=900, unused=False):
    """gpucapture start: COUNT iterations of BOUNDARY into PATH (a .gputrace on this Mac).
    Without UNUSED it records only the resources the frame uses: with every resource, a
    D3D12 game's heaps (vkd3d-proton's, 10 GB in The Witcher 3) were downloaded until the
    game ended mid-capture ("process crashed or disconnected", 2026-10-28)."""
    said = run(["gpucapture", "start", "-p", str(pid), "-d", str(device), "-b", str(boundary), "-c", str(count),
                *([] if unused else ["-du"]), "-o", path], secs, log=log)
    if not os.path.exists(path):
        errors = [l.strip() for l in said.splitlines() if l.strip().lower().startswith("error")]
        raise phonelib.PhoneError(f"gpucapture wrote no {path}" + (f": {errors[-1]}" if errors else ""))
    return path


# -- gpudebug: replay and profile on the phone

class Session:
    """One gpudebug session on a trace, replaying on DEVICE; terminated on exit."""

    def __init__(self, trace, device, out, log):
        self.log, self.out = log, out
        text = run(["gpudebug", "-q", "--json", "-t", trace, "-d", str(device), "-o", out, "--timeout", "3600",
                    "-c", "status"], 600, log=log)
        m = re.search(r"Session (\d+) created", text) or re.search(r'"session"\s*:\s*(\d+)', text)
        if not m:
            listed = run(["gpudebug", "-l"], 60, check=False, log=log)
            m = re.search(r"^\s*(\d+)\s.*" + re.escape(os.path.basename(trace)), listed, re.M)
        if not m:
            raise phonelib.PhoneError(f"gpudebug made no session for {trace} ({log})")
        self.id = m[1]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        run(["gpudebug", "--terminate", self.id], 60, check=False, log=self.log)

    def cmd(self, *commands, secs=600, json_out=True):
        args = ["gpudebug", "-q", *(["--json"] if json_out else []), "-s", self.id]
        for c in commands:
            args += ["-c", c]
        return run(args, secs, check=False, log=self.log)

    def status(self):
        for line in reversed(self.cmd("status", secs=120).splitlines()):
            s = line[line.find("{"):] if "{" in line else ""
            try:
                return json.loads(s)
            except ValueError:
                continue
        return {}


def json_lines(text):
    """Each JSON object a gpudebug reply printed (after its prompt)."""
    out = []
    for line in text.splitlines():
        i = line.find("{")
        if i < 0:
            continue
        try:
            out.append(json.loads(line[i:]))
        except ValueError:
            pass
    return out


# -- xctrace

def phone_name():
    """The phone's name as xctrace's --device-name takes it (devicectl's list)."""
    path = os.path.join(phonelib.BUILD, "tmp", "devicectl-list.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    run(["xcrun", "devicectl", "list", "devices", "--json-output", path], 60, check=False)
    try:
        with open(path) as f:
            doc = json.load(f)
    finally:
        with __import__("contextlib").suppress(OSError):
            os.remove(path)   # it carries the UDID
    for d in doc.get("result", {}).get("devices", []):
        hw, dp = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
        if hw.get("platform") == "iOS" and hw.get("reality") == "physical" \
                and d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
            return dp.get("name")
    return None


def xctrace_record(template, secs, path, log=None):
    """Instruments' TEMPLATE for SECS of the whole phone, into PATH (.trace)."""
    name = phone_name()
    if not name:
        raise phonelib.PhoneError("devicectl lists no connected phone (xcrun devicectl list devices)")
    run(["xcrun", "xctrace", "record", "--template", template, "--device-name", name, "--all-processes",
         "--time-limit", f"{int(secs)}s", "--output", path, "--no-prompt"], secs + 600, log=log)
    if not os.path.exists(path):
        raise phonelib.PhoneError(f"xctrace wrote no {path}")
    return path


# -- reading an embedded profile (no phone needed)

# The counters read per encoder: (group under performance/timeline/counters, counter), as
# gpudebug names them for the A19 Pro on iOS 27.0.1. Each is a time series (~33 µs a sample).
COUNTERS = (
    ("occupancy", "total_occupancy"), ("occupancy", "fs_occupancy"), ("occupancy", "kernel_occupancy"),
    ("occupancy", "vs_occupancy"),
    ("alu", "alu_utilization"), ("f32", "f32_limiter"), ("f16", "f16_utilization"),
    ("instruction_throughput", "instruction_throughput_limiter"),
    ("control_flow", "control_flow_limiter"),
    ("texture_read", "texture_read_limiter"), ("texture_filtering", "texture_filtering_limiter"),
    ("texture_write", "texture_write_limiter"),
    ("last_level_cache", "last_level_cache_limiter"), ("l1_cache", "l1_cache_limiter"),
    ("mmu", "mmu_limiter"),
    ("shader_launch_limiter", "fragment_shader_launch_limiter"),
    ("shader_launch_limiter", "compute_shader_launch_limiter"),
    ("shader_launch_limiter", "vertex_shader_launch_limiter"),
    ("bandwidth", "gpu_bandwidth"), ("gpu_peak_bandwidth", "gpu_peak_bandwidth"),
)
# Short column names for the table
SHORT = {"total_occupancy": "occ", "fs_occupancy": "fsOcc", "kernel_occupancy": "csOcc", "vs_occupancy": "vsOcc",
         "alu_utilization": "alu", "f32_limiter": "f32", "f16_utilization": "f16",
         "instruction_throughput_limiter": "instr", "control_flow_limiter": "ctrl",
         "texture_read_limiter": "texRd", "texture_filtering_limiter": "texFlt", "texture_write_limiter": "texWr",
         "last_level_cache_limiter": "llc", "l1_cache_limiter": "l1", "mmu_limiter": "mmu",
         "fragment_shader_launch_limiter": "fsLaunch", "compute_shader_launch_limiter": "csLaunch",
         "vertex_shader_launch_limiter": "vsLaunch", "gpu_bandwidth": "GB/s", "gpu_peak_bandwidth": "peakBW"}


def oneshot(trace, commands, log, secs=900):
    """gpudebug --oneshot on TRACE with its embedded profile loaded first; each JSON reply."""
    args = ["gpudebug", "-q", "--json", "--oneshot", "-t", trace, "-c", "profile load"]
    for c in commands:
        args += ["-c", c]
    return json_lines(run(args, secs, check=False, log=log))


def read_profile(trace, out, log):
    """The embedded profile of TRACE: the encoder timeline [{name, label, start, end, dur}] (ns)
    and each COUNTERS series {counter: [(t, v)]}, raw JSON kept under OUT/profile/."""
    raw = os.path.join(out, "profile")
    os.makedirs(raw, exist_ok=True)
    replies = oneshot(trace, ["go /performance/timeline/encoders", "list --all"], log)
    kids = next((o["children"] for o in reversed(replies) if "children" in o), [])
    with open(os.path.join(raw, "timeline-encoders.json"), "w") as f:
        json.dump(kids, f, indent=1)
    encoders = []
    for k in kids:
        v = k.get("values", [])
        if len(v) >= 4:
            encoders.append({"name": k["name"], "label": str(v[0].get("value", "")).strip('"'),
                             "start": v[1]["value"], "end": v[2]["value"], "dur": v[3]["value"]})
    cmds = []
    for group, name in COUNTERS:
        cmds += [f"go /performance/timeline/counters/{group}",
                 f"fetch {name} --out {os.path.join(raw, name + '.json')}"]
    oneshot(trace, cmds, log)
    series = {}
    for _, name in COUNTERS:
        path = os.path.join(raw, name + ".json")
        if os.path.exists(path):
            with open(path) as f:
                d = json.load(f)
            series[name] = ([(s["t"], s["v"]) for s in d.get("samples", [])], d.get("unit"), d.get("average"))
    return encoders, series


def window_mean(samples, start, end):
    """The mean of the samples in [start, end], or the nearest sample for a short window."""
    vals = [v for t, v in samples if start <= t <= end]
    if vals:
        return sum(vals) / len(vals)
    if not samples:
        return None
    mid = (start + end) / 2
    return min(samples, key=lambda s: abs(s[0] - mid))[1]


def per_encoder(encoders, series):
    """Each encoder with its counters' means over its interval; the whole-frame encoders gpudebug
    reports for empty ones (start 0, the frame's span) are left out. Sorted by duration."""
    span = max((e["end"] for e in encoders), default=0)
    rows = []
    for e in encoders:
        if e["start"] == 0 and e["end"] == span and len(encoders) > 1:
            continue
        r = dict(e)
        for name, (samples, _, _) in series.items():
            r[name] = window_mean(samples, e["start"], e["end"])
        rows.append(r)
    rows.sort(key=lambda r: -r["dur"])
    return rows, span


def busy_ns(encoders, span):
    """The union of the encoders' intervals (whole-frame ones left out)."""
    iv = sorted((e["start"], e["end"]) for e in encoders if not (e["start"] == 0 and e["end"] == span))
    total, cur = 0, None
    for s, t in iv:
        if cur is None or s > cur[1]:
            if cur:
                total += cur[1] - cur[0]
            cur = [s, t]
        else:
            cur[1] = max(cur[1], t)
    return total + (cur[1] - cur[0] if cur else 0)


def profile_report(trace, encoders, series, top=40):
    rows, span = per_encoder(encoders, series)
    busy = busy_ns(encoders, span)
    names = [n for _, n in COUNTERS if n in series]
    lines = [f"profile of {os.path.basename(trace)}",
             f"encoders {len(rows)}; frame span {span / 1e6:.2f} ms; GPU busy (union) {busy / 1e6:.2f} ms", "",
             "whole frame (gpudebug's averages):"]
    lines += ["  " + "  ".join(f"{SHORT[n]}={series[n][2]:.1f}" for n in names if series[n][2] is not None), ""]
    head = f"{'encoder':<8} {'label':<30} {'ms':>6} {'%':>5}  " + " ".join(f"{SHORT[n]:>7}" for n in names)
    lines += [f"top {top} encoders by GPU time; counters are the mean over each encoder's interval "
              "(% of peak, bandwidth GB/s); with overlapping encoders a counter covers all that ran", head]
    for r in rows[:top]:
        cells = " ".join(f"{r[n]:>7.1f}" if r.get(n) is not None else f"{'-':>7}" for n in names)
        lines.append(f"{r['name']:<8} {r['label'][:30]:<30} {r['dur'] / 1e6:>6.2f} {100 * r['dur'] / max(busy, 1):>5.1f}  {cells}")
    return "\n".join(lines) + "\n", rows

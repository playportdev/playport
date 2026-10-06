# SPDX-License-Identifier: GPL-3.0-or-later
"""pp perf: one measured title run: frame rate, frame and GPU time, CPU cluster
use and the SoC's thermal power budget, second by second.

  pp perf [--out DIR] [--title ID] [--secs S] [--shot WHEN ...] [--cool MIN] [--settings JSON]
          [--pad WHEN:SCRIPT ...] [--no-hud] [--no-counters] [--energy] [--pass-prof] [--cpu-prof] [--gpu-capture FRAME] [--expect-ipa IPA|SHA256] [--any-build]
          [--keep-settings] [--dry-run]
  pp perf --analyze DIR [--frames auto|hud|layer|present]
  pp perf --compare DIR DIR ... [--window LO:HI] [--json]

WHEN is SECS after the launch, or first-frame+SECS after the game's first
frame. The launch is the product UI's Play of --title (default app-367520,
Hollow Knight), through `pp ui`. Settings' Metal HUD is turned on first, in
a launch of its own: a dev build that starts with it on also has Metal log the
HUD's figures (MetalHUD in HostIO.swift). --no-hud turns it off instead: the
HUD's per-frame logging costs the process CPU work, and frames are then
counted from the game layer's per-16-drawable `[frames] HH:MM:SS.mmm n=N` lines
(PacedMetalLayer in HostIO.swift, either backend), or in a run from before
them, DXMT's per-16-present `[iOS DXMT] Present #N t=` lines.
--settings JSON is saved as the title's launch settings first, as its page
does. The HUD switch and --settings last for this run (one device lock
session) and are undone at the app's next launch outside it, unless
--keep-settings. --expect-ipa and --any-build are pp ui's: by default the phone
must have the IPA this checkout installed. What is recorded, all of it from sources that exist
without a special build:

  metal-HUD lines   libMTLHud's once-a-second line, which the app's stderr
                    (s1-host.log) carries unredacted: the presented-frame
                    counter, Metal and app memory (MiB), then one
                    (frame interval ms, GPU time ms) pair per frame
  [xp] lines        the runtime's 250 ms census (Madeira server_ios.c
                    ios_xprobe_main): process CPU ms split by P and E cluster,
                    each cluster's effective GHz, energy
  [srv], [srv-t]    madeira-unix 0037, once a second: the wineserver
                    requests by kind (sel select, ev event, mtx mutex, sem
                    semaphore, hdl handles, msg message queue, oth the
                    rest) and by type, and each thread's with the ms it
                    spent in round trips (rt) and blocked in a select (blk):
                    the srv/f column (requests per frame), server.txt, and
                    summary.json's server (per frame over the played
                    buckets, and the busiest thread's share of its time)
  CPMS budgets      the kernel's thermal power budgets (mW) for each CPMS
                    client, from the device syslog, each logged when it
                    changes (ApplePPMCPMS setDetailedThermalPowerBudget;
                    before iOS 27, `Budget Trace`): the limits the SoC is
                    held to. The budget column is the lowest client, each
                    carried forward (below)
  power.txt         the battery gauge's power telemetry every 5 s
                    (`diagnostics battery single`, PowerTelemetryData):
                    SystemLoad is the whole phone's draw in mW (SoC, display,
                    radios), whether the charger or the battery supplies it
                    (SystemPowerIn, BatteryPower); the sysmW column, with
                    the battery's current (InstantAmperage, mA, negative
                    while discharging) as batmA
  [CB_SUMMARY], mprotect_exec, Present machexc_delta
                    FEX's translated-block count, the runtime's protection
                    changes and DXMT's mach-exception count: the jit/s,
                    mprot/s and exc/s columns, and hitches.txt
  [shader-time], [pso-wait]
                    patches/dxmt 0005: shader and pipeline compiles and the
                    draws that waited for one (hitches.txt)
  [pass-prof]       only with --pass-prof (Settings' Diagnostics, GPU time per
                    pass; patches/dxmt 0008): every encoder of two frames in
                    every 1200 presents, its GPU time, size and attachments
                    (passes.txt, tools/passprof.py)
  [wprof]           only with --cpu-prof (Settings' Diagnostics, CPU sampling;
                    patches/madeira-unix 0028): the busiest threads' samples
                    (profile.txt, tools/sampleprof.py)
  gpu.txt           `dvt graphics`, once a second: the GPU's device,
                    renderer and tiler utilization %, busy time at whatever
                    clock the GPU runs (the gpu%, ren% and til% columns)
  energy.txt        only with --energy: `dvt energy <pid>`, Xcode's energy
                    gauge for the app, its CPU and GPU cost in the gauge's
                    own units (the cpuE, gpuE columns). The gauge answers
                    about ten times a second and perturbs the title: on the
                    save-slot screen it came with 26-37 frames over 8.5 ms
                    per 5 s against 0-4 without it, so a run with it is not
                    comparable
The last two are stamped with the workstation's wall time, which matched the
phone's to about 0.1 s.

Before launching it ends any running instance of the app and moves
s1-host.log aside (--keep-log skips that). The kernel logs a client's budget
only when it changes, so each client holds its last value until its next
line and the budget column is the lowest client with those values carried
forward (a `-`: none logged yet). A client held at its floor (660 mW for
client 9 on the A19 Pro) parks the P cores: the P% column falls to 0.
summary.json has each client's lowest and last value, and the app's
ProcessInfo.thermalState at the launch and at each change (thermal_start,
thermal_states; a run that did not start at nominal started hot).
thermalmonitord logs a pressure level only when it changes, so after each
run a follower keeps its lines in $PLAYPORT_BUILD/thermal-follow.log for an
hour. --cool MIN waits until MIN minutes have passed since the last pp perf
run or pp ui play ended ($PLAYPORT_BUILD/perf-last.json, last-play.json) and
then until the last pressure level logged since is 0 (at most --cool-max
minutes), so runs start alike; a level older than the follower's hour counts as
none. The phone exposes no temperature reading, and 15 minutes is not a cold
start: a native run after 15 minutes met its first power budget at 90 s, one
after 2.5 hours at 223 s (docs/evidence/2026-09-29-hk-gameplay-baseline.md).
--pad launches with the scripted pad and pushes each SCRIPT (a file or a name
in tools/pad/, as `pp pad push` takes) at its WHEN; first-frame+SECS follows
the game's own start rather than the JIT and runtime start before it. The
log's `vpad: step` lines mark what the pad was doing. --secs after the game's first frame the app is killed: a title left
running keeps heating the phone. Everything goes to DIR (default $PLAYPORT_BUILD/perf-runs/<time>):
the `pp ui` run directory (run/), budget.txt, power.txt, this-launch.log (the launch's part of
s1-host.log), and summary.txt / summary.json / threads.txt / server.txt / hitches.txt from
--analyze, and argv.txt (the command). summary.json has the battery's charge at the
first and last power.txt sample and whether a charger was on (battery_start_pct,
battery_end_pct, charger): runs at different charge do not compare, and a run
that starts under 30 % on no charger warns. The last line is always a `result`
event with the directory, the summary, the start-up self-check (`selfcheck`), the
JIT pool's use (`pool`), the runtime's known limits (`limits`) and the FEX host
band's use (`band`), all from the
`pp ui` run: ok false with a `why` when the run failed (the `pp ui` run's why
and hint, such as jit-unreachable with exit 4; the analysis's reason when there
was nothing to analyse; terminated with exit 143 on SIGTERM, which ends the app
and the monitors first). It holds the device lock for
the whole run. summary.json's summary also has the played buckets' fps_mean,
fps_p10, ft_avg_ms and gpu_avg_ms, and run.json what the run was asked for.

--compare DIR ... sets finished runs side by side from those files (and the
play's launched event, for runs from before run.json): the figures, the launch
settings that differ (env.NAME for each environment entry, in runs from before
the game's page dropped them), and the frame rate per 30 s of the table;
--json prints the same as one object.
"""

import argparse
import contextlib
import json
import os
import re
import signal
import subprocess
import threading
import time

import pad
import phonelib
from phonelib import SOCK

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
UI_RUN = os.path.join(REPO, "tools", "ui.py")
BUDGET_RE = re.compile(r"^(\d{4}-\d\d-\d\d) (\d\d):(\d\d):([\d.]+) .*Budget Trace: clientId 0, .*"
                       r"Requested Budget (\d+), Granted Budget (\d+), Thermal Budget (\d+)")
# iOS 27: one line a second for each CPMS client (and detail) holding the SoC
CPMS_RE = re.compile(r"^\d{4}-\d\d-\d\d (\d\d):(\d\d):([\d.]+) .*setDetailedThermalPowerBudget: "
                     r"clientId (\d+), details \d+, Thermal Budget (\d+)")
LAST = os.path.join(phonelib.BUILD, "perf-last.json")
LAST_PLAY = os.path.join(phonelib.BUILD, "last-play.json")   # tools/ui.py: the last play's end
# thermalmonitord's lines after a run ends, for --cool: it logs the pressure
# level only when it changes, so a phone cooling down says so here
FOLLOW = os.path.join(phonelib.BUILD, "thermal-follow.log")
FOLLOW_PID = os.path.join(phonelib.BUILD, "thermal-follow.pid")
FOLLOW_S = 3600
# the battery gauge's PowerTelemetryData (mW) and the battery's own current
POWER_KEYS = ("SystemLoad", "AccumulatedSystemLoad", "SystemLoadAccumulatorCount", "SystemPowerIn", "BatteryPower",
              "InstantAmperage", "CurrentCapacity", "ExternalConnected")
HUD_RE = re.compile(r"(\d\d):(\d\d):([\d.]+) S1Probe\[\d+:\d+\] metal-HUD: (\d+),([\d.]+),([\d.]+),?(.*)")
THERMAL_STATE_RE = re.compile(r"title: thermal: (\w+)( at launch)?")
THERM_RE = re.compile(r"^\d{4}-\d\d-\d\d (\d\d):(\d\d):([\d.]+) .*<Notice> (Thermal pressure level|mTLL =) (\d+)")
XP_RE = re.compile(r"^\[xp\] (\d\d):(\d\d):([\d.]+) \S+ dt=([\d.]+) cpu=(\d+) \(thr [\d.]+\) P=(\d+) E=(\d+) "
                   r"run=(\d+) pgw=[\d.]+ GHz P=([\d.]+) E=([\d.]+) Minst=(\d+) IPC=[\d.]+ mJ=(\d+)")
# the census's per-thread line: "-<wine tid>" or "m<mach tid>" (or a role letter
# before the wine tid), then P ms / E ms : P GHz / E GHz : M instructions
XPT_RE = re.compile(r"^\[xp-t\] (\d\d):(\d\d):([\d.]+) (.*)")
XPT_ENT = re.compile(r"^(m\d+|[A-Z]*-?[0-9a-f]{4,}):([\d.]+)/([\d.]+):[\d.]+/[\d.]+:([\d.]+)$")
# FEX's lookup-cache summary (every 16384 lookups): real_compiles counts guest
# blocks translated so far; DXMT's per-16-present line counts mach exceptions
CB_RE = re.compile(r"\[CB_SUMMARY\] total=\d+ real_compiles=(\d+)")
# the game layer's line every 16 drawables taken (HostIO.swift, dev builds; any backend)
FRAMES_RE = re.compile(r"^\[frames\] (\d\d):(\d\d):([\d.]+) n=(\d+)")
PRESENT_RE = re.compile(r"\[iOS DXMT\] Present #(\d+) t=([\d.]+) .*machexc_delta=(\d+)")
# patches/dxmt 0005: one line per shader conversion, library, function or
# pipeline-state creation, and per draw that waited for its pipeline
SHC_RE = re.compile(r"^\[shader-time\] (\d\d):(\d\d):([\d.]+) (\S+) ([\d.]+) ms")
PSOWAIT_RE = re.compile(r"\[pso-wait\] \S+ ([\d.]+) ms")
VPAD_RE = re.compile(r"^\[(\d\d):(\d\d):([\d.]+)\] vpad: (step .*)")
# madeira-unix 0037: once a second, the wineserver requests by kind (select, event,
# mutex, semaphore, handle, message queue, other) with the round-trip and blocked
# ms and the selects that blocked, of the whole process, then each thread's
# (Windows TID: the seven counts : round-trip ms / blocked ms / blocked selects)
SRV_KINDS = ("sel", "ev", "mtx", "sem", "hdl", "msg", "oth")
SRV_RE = re.compile(r"^\[srv\] (\d\d):(\d\d):([\d.]+) dt=([\d.]+) req=\d+ "
                    + " ".join(k + r"=(\d+)" for k in SRV_KINDS) + r" rt=([\d.]+) blk=([\d.]+) nblk=(\d+) \|(.*)")
SRVT_RE = re.compile(r"^\[srv-t\] (\d\d):(\d\d):([\d.]+)(.*)")
SRVT_ENT = re.compile(r"^-([0-9a-f]{4,}):([\d/]+):([\d.]+)/([\d.]+)/(\d+)$")
TNAME_RE = re.compile(r"\[thr-name\] ml810 tid=([0-9a-f]+) teb=\S+ name=\"([^\"]*)\"")
STAMP_RE = re.compile(r"^(\d\d):(\d\d):([\d.]+) (\{.*\})$")


def pmd(*args):
    return ["env", f"USBMUXD_SOCKET_ADDRESS={SOCK}", "pymobiledevice3", *args]


def stamped(args, path, secs):
    """A pymobiledevice3 JSON-lines monitor in the background, each line
    written to `path` behind the workstation's wall time (HH:MM:SS.mmm)."""
    import threading
    f = open(path, "w")
    p = subprocess.Popen(["timeout", str(secs), "env", "PYTHONUNBUFFERED=1", *pmd(*args)],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def pump():
        for line in p.stdout:
            t = time.time()
            f.write(time.strftime("%H:%M:%S", time.localtime(t)) + f".{int(t * 1000) % 1000:03d} {line}")
            f.flush()
        f.close()
    threading.Thread(target=pump, daemon=True).start()
    return p


def stamped_json(d, name):
    """(wall seconds, dict) from a stamped() file; [] when the run has none."""
    res = []
    path = os.path.join(d, name)
    if os.path.exists(path):
        with open(path, errors="replace") as f:
            for l in f:
                m = STAMP_RE.match(l.strip())
                if m:
                    try:
                        res.append((secs_of(m[1], m[2], m[3]), json.loads(m[4])))
                    except ValueError:
                        pass
    return res


def battery_power():
    """The phone's power figures from `diagnostics battery single`: POWER_KEYS
    that it has; {} when it could not be read."""
    r = subprocess.run(["timeout", "20", *pmd("diagnostics", "battery", "single")],
                       capture_output=True, text=True)
    try:
        j = json.loads(r.stdout)
    except ValueError:
        return {}
    j = {**j, **(j.get("PowerTelemetryData") or {})}
    return {k: j[k] for k in POWER_KEYS if k in j}


def power_sampler(path, stop, every=5.0):
    """battery_power() every `every` s into `path`, as stamped() lines."""
    def run():
        with open(path, "w") as f:
            while not stop.is_set():
                t0 = time.time()
                v = battery_power()
                if v:
                    t = time.time()
                    f.write(time.strftime("%H:%M:%S", time.localtime(t)) + f".{int(t * 1000) % 1000:03d} "
                            + json.dumps(v) + "\n")
                    f.flush()
                stop.wait(max(0.0, every - (time.time() - t0)))
    th = threading.Thread(target=run, daemon=True)
    th.start()
    return th


def follow_thermal():
    """After a run: thermalmonitord's syslog into FOLLOW for FOLLOW_S seconds, in a
    process of its own that outlives pp perf (the previous one is ended first)."""
    stop_follow()
    f = open(FOLLOW, "w")
    pr = subprocess.Popen(["timeout", str(FOLLOW_S), *pmd("syslog", "live", "-pn", "thermalmonitord")],
                          stdout=f, stderr=subprocess.DEVNULL, start_new_session=True)
    with open(FOLLOW_PID, "w") as g:
        g.write(str(pr.pid))


def stop_follow():
    try:
        pid = int(open(FOLLOW_PID).read())
        os.killpg(pid, 15)   # its own session: timeout and pymobiledevice3 under it
    except (OSError, ValueError):
        pass
    try:
        os.unlink(FOLLOW_PID)
    except OSError:
        pass


def pressure_levels(path):
    """[(HH:MM:SS as seconds, level)] of a thermalmonitord log's pressure lines."""
    out = []
    try:
        for l in open(path, errors="replace"):
            m = THERM_RE.match(l)
            if m and m[4].startswith("Thermal"):
                out.append((secs_of(m[1], m[2], m[3]), int(m[5])))
    except OSError:
        pass
    return out


def cool_state(last, ended=None):
    """The last thermal pressure level known since the previous run: the follower's
    newest, else that run's own last one; None when neither logged a level, or when
    the phone has rested longer than the follower ran (FOLLOW_S): thermalmonitord
    logs a level only when it changes, so the follower's last level is then stale
    (on 2026-09-30 a level 10 from 23:44 held a morning run for its whole
    --cool-max), and an hour's rest is cool enough."""
    if ended and time.time() - ended > FOLLOW_S:
        return None
    lv = pressure_levels(FOLLOW)
    if not lv and last.get("followed"):   # the follower ran from that run's end, so its last level holds
        lv = pressure_levels(os.path.join(last.get("out", ""), "thermal.txt"))
    return lv[-1][1] if lv else None


def secs_of(h, m, s):
    return int(h) * 3600 + int(m) * 60 + float(s)


def present_frames(pres):
    """HUD-shaped (wall time, frame counter, [], [], None) entries from DXMT's
    per-16-present lines, for a run without the Metal HUD. A Present line's t=
    is the host's monotonic seconds; its wall time is t plus the offset to the
    wall clock, taken from the last timed line before each Present line. That
    line can only be older than the Present, so the offset is the 95th
    percentile of (last wall time - t), not the median."""
    offs = sorted(w - t for (w, _, t) in pres if w is not None)
    if not offs:
        return []
    off = offs[min(len(offs) - 1, int(len(offs) * 0.95))]
    return [(t + off, n, [], [], None) for (_, n, t) in pres]


def analyze(d, bucket=5.0, frames_from="auto", echo=True):
    """Per-bucket table and a JSON summary from a run directory. Frames come
    from the Metal HUD's lines; when the run has no HUD lines (--no-hud) or
    frames_from says so, from the game layer's [frames] lines, else DXMT's
    Present lines (then the frame-time, GPU and memory columns and hitches.txt
    are empty)."""
    log = os.path.join(d, "run", "pull", "s1-host.log")
    this = os.path.join(d, "this-launch.log")
    if not os.path.exists(this):
        with open(os.path.join(d, "run", "events.jsonl")) as f:
            nonce = next(json.loads(l)["nonce"] for l in f if json.loads(l).get("event") == "launched")
        with open(log, "rb") as f:
            data = f.read()
        i = data.find(f"nonce={nonce}".encode())
        if i < 0:
            raise SystemExit(f"nonce {nonce} not in {log}")
        with open(this, "wb") as f:
            f.write(data[data.rfind(b"\n", 0, i) + 1:])
    with open(this, errors="replace") as f:
        lines = f.read().splitlines()
    hud, xp, budget, xpt, names, vpad, pres, srv, srvt, lay = [], [], [], [], {}, [], [], [], [], []
    # (t, kind, n): lines without a time of their own take the last time seen
    # in the log, which runs at least four times a second ([xp], [xp-t])
    ev, cur_t, last_cb = [], None, None
    for l in lines:
        m = CB_RE.search(l)
        if m:
            n = int(m[1])
            if last_cb is not None and cur_t is not None and n > last_cb:
                ev.append((cur_t, "jit", n - last_cb))
            last_cb = n
            continue
        m = SHC_RE.match(l)
        if m:
            ev.append((secs_of(m[1], m[2], m[3]), "shc_ms", float(m[5])))
            continue
        if cur_t is not None:
            m = PSOWAIT_RE.search(l)
            if m:
                ev.append((cur_t, "wait_ms", float(m[1])))
                continue
            if "err:virtual:mprotect_exec" in l:
                ev.append((cur_t, "mprot", 1))
                continue
        m = PRESENT_RE.search(l)
        if m:
            if int(m[1]) > 1:   # Present #1 carries the whole start-up
                pres.append((cur_t, int(m[1]), float(m[2])))
                if cur_t is not None:
                    ev.append((cur_t, "mexc", int(m[3])))
            continue
        m = VPAD_RE.match(l)
        if m:
            cur_t = secs_of(m[1], m[2], m[3])
            vpad.append((cur_t, m[4]))
            continue
        if l.startswith("[frames] "):
            m = FRAMES_RE.match(l)
            if m:
                cur_t = secs_of(m[1], m[2], m[3])
                lay.append((cur_t, int(m[4]), [], [], None))
            continue
        if l.startswith("[xp-t] "):
            m = XPT_RE.match(l)
            if m:
                cur_t = secs_of(m[1], m[2], m[3])
                ents = {}
                for e in m[4].split():
                    me = XPT_ENT.match(e)
                    if me:
                        k = me[1] if me[1].startswith("m") else me[1].lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZ-")
                        ents[k] = (float(me[2]), float(me[3]), float(me[4]))
                xpt.append((secs_of(m[1], m[2], m[3]), ents))
            continue
        if l.startswith("[srv"):
            m = SRV_RE.match(l)
            if m:
                cur_t = secs_of(m[1], m[2], m[3])
                types = {k: int(v) for k, _, v in (e.partition("=") for e in m[15].split()) if v.isdigit()}
                srv.append((cur_t, float(m[4]), tuple(int(x) for x in m.groups()[4:11]),
                            float(m[12]), float(m[13]), int(m[14]), types))
                continue
            m = SRVT_RE.match(l)
            if m:
                cur_t = secs_of(m[1], m[2], m[3])
                ents = {}
                for e in m[4].split():
                    me = SRVT_ENT.match(e)
                    if me and len(me[2].split("/")) == len(SRV_KINDS):
                        ents[me[1]] = (tuple(int(x) for x in me[2].split("/")), float(me[3]), float(me[4]),
                                       int(me[5]))
                srvt.append((cur_t, ents))
                continue
        if "[thr-name]" in l:
            m = TNAME_RE.search(l)
            if m:
                names[m[1]] = m[2]
            continue
        m = HUD_RE.search(l)
        if m:
            vals = [float(x) for x in m[7].split(",") if x]
            cur_t = secs_of(m[1], m[2], m[3])
            hud.append((cur_t, int(m[4]), vals[0::2], vals[1::2], float(m[6])))
            continue
        m = XP_RE.match(l)
        if m:
            g = m.groups()
            cur_t = secs_of(*g[:3])
            xp.append((secs_of(*g[:3]),) + tuple(float(x) for x in g[3:]))
    # (t, client, mW): the granted budget of a Budget Trace line (client
    # "trace"), or one CPMS client's thermal budget
    bp = os.path.join(d, "budget.txt")
    if os.path.exists(bp):
        with open(bp, errors="replace") as f:
            for l in f:
                m = BUDGET_RE.match(l)
                if m:
                    budget.append((secs_of(m[2], m[3], m[4]), "trace", int(m[6])))
                    continue
                m = CPMS_RE.match(l)
                if m:
                    budget.append((secs_of(m[1], m[2], m[3]), m[4], int(m[5])))
    power = stamped_json(d, "power.txt")
    gfx = stamped_json(d, "gpu.txt")
    # the energy gauge's first sample carries everything since the query began,
    # and it answers faster than it updates: every other sample is all zeros
    energy = [(t, v) for (t, j) in stamped_json(d, "energy.txt") for v in list(j.values())[:1]
              if isinstance(v, dict) and v.get("kIDEGaugeSecondsSinceInitialQueryKey") and v.get("energy.cost")]
    therm = []   # (t, "tpl"|"tll", value)
    tp = os.path.join(d, "thermal.txt")
    if os.path.exists(tp):
        with open(tp, errors="replace") as f:
            for l in f:
                m = THERM_RE.match(l)
                if m:
                    therm.append((secs_of(m[1], m[2], m[3]), "tpl" if m[4].startswith("Thermal") else "tll",
                                  int(m[5])))
    # the HUD's own frame counter resets are not expected; drop duplicate lines
    seen, uh = set(), []
    for h in hud:
        if h[1] not in seen:
            seen.add(h[1])
            uh.append(h)
    hud = uh
    if frames_from == "layer" or (frames_from == "auto" and len(hud) < 2 and len(lay) >= 2):
        hud = lay
        if len(hud) < 2:
            raise SystemExit(f"{d}: fewer than two [frames] lines (a build from before them?)")
    elif frames_from == "present" or (frames_from == "auto" and len(hud) < 2):
        hud = present_frames(pres)
        if len(hud) < 2:
            raise SystemExit(f"{d}: fewer than two DXMT Present lines")
    if len(hud) < 2:
        raise SystemExit(f"{d}: fewer than two metal-HUD lines (was MTL_HUD_LOG_ENABLED=1 set?)")
    t0 = hud[0][0]
    rows = []
    b = 0
    while True:
        lo, hi = t0 + b * bucket, t0 + (b + 1) * bucket
        # a bucket with no frame (a scene load that presents nothing for 5 s or
        # more) is a 0 fps row, not the end of the run
        if lo > hud[-1][0]:
            break
        seg = [h for h in hud if lo <= h[0] < hi]
        prev = [h for h in hud if h[0] < lo]
        span = ([prev[-1]] if prev else []) + seg
        # the rate over the time frames were presented: an interval between two
        # frame lines that its frames' own times leave more than LOAD_GAP_S
        # short of is a scene load, not play (a slow line's frames are long)
        live = [(a, z) for a, z in zip(span, span[1:]) if z[0] - a[0] - played_s(a, z) <= LOAD_GAP_S]
        live_s = sum(z[0] - a[0] for a, z in live)
        fps = sum(z[1] - a[1] for a, z in live) / live_s if live_s else 0.0
        ft = [v for h in seg for v in h[2]]
        gt = [v for h in seg for v in h[3]]
        x = [r for r in xp if lo <= r[0] < hi]
        wall = sum(r[1] for r in x) or 1.0
        # the kernel logs a client's budget only when it changes, so a client
        # holds its last value until the next line: the lowest client, counting
        # each one's value carried in from before the bucket
        bud = [r for r in budget if lo <= r[0] < hi]
        held = {}
        for (t, c, v) in budget:
            if t < lo:
                held[c] = v
        bud += [(lo, c, v) for c, v in held.items()]
        # thermalmonitord logs a level only when it changes: the last one before
        # the bucket ends; None (a `-`) until the run's first change, because the
        # level the run started at is not logged (it is 0 only after a full cool-down)
        level = lambda k: ([v for (t, kk, v) in therm if kk == k and t < hi] or [None])[-1]
        g = [j for (t, j) in gfx if lo <= t < hi]
        gavg = lambda k: round(sum(j.get(k, 0) for j in g) / len(g)) if g else None
        pw = [j for (t, j) in power if lo <= t < hi]
        pavg = lambda k: round(sum(j[k] for j in pw if k in j) / len(pw)) if pw and all(k in j for j in pw) else None
        en = [j for (t, j) in energy if lo <= t < hi]
        eavg = lambda k: round(sum(j.get(k, 0) for j in en) / len(en), 1) if en else None
        rows.append({
            "t": round(b * bucket),
            "fps": round(fps, 1),
            "live_s": round(live_s, 2),
            "ft_avg": round(sum(ft) / len(ft), 2) if ft else None,
            "ft_max": max(ft) if ft else None,
            "slow_frames": sum(1 for v in ft if v > 8.5),
            "gpu_avg": round(sum(gt) / len(gt), 2) if gt else None,
            "gpu_max": max(gt) if gt else None,
            "cpu_pct": round(100 * sum(r[2] for r in x) / wall) if x else None,
            "p_pct": round(100 * sum(r[3] for r in x) / wall) if x else None,
            "e_pct": round(100 * sum(r[4] for r in x) / wall) if x else None,
            "p_ghz": round(max(r[6] for r in x), 2) if x else None,
            "e_ghz": round(max(r[7] for r in x), 2) if x else None,
            "mw": round(sum(r[9] for r in x) / wall * 1000) if x else None,
            "budget_mw": min(r[2] for r in bud) if bud else None,
            "app_mib": seg[-1][4] if seg else None,
            "sys_mw": pavg("SystemLoad"),
            "batt_ma": pavg("InstantAmperage"),
            "tpl": level("tpl"),
            "tll": level("tll"),
            # dvt graphics: GPU busy % (device, renderer, tiler); dvt energy: the
            # Xcode gauge's CPU and GPU cost for the app, averaged over its samples
            "gpu_util": gavg("Device Utilization %"),
            "ren_util": gavg("Renderer Utilization %"),
            "til_util": gavg("Tiler Utilization %"),
            "cpu_energy": eavg("energy.cpu.cost"),
            "gpu_energy": eavg("energy.gpu.cost"),
            # wineserver requests per presented frame (madeira-unix 0037's [srv])
            "srv_pf": (round(sum(sum(s[2]) for s in srv if lo <= s[0] < hi) / (fps * live_s), 1)
                       if fps * live_s and any(lo <= s[0] < hi for s in srv) else None),
            # per second: guest blocks FEX translated, protection changes
            # (the runtime's mprotect_exec ERR line), mach exceptions
            **{k + "_ps": round(sum(n for (t, kk, n) in ev if kk == k and lo <= t < hi) / bucket)
               for k in EV_KINDS[:3]},
        })
        b += 1
    hdr = f"{'t':>4} {'fps':>6} {'ft':>6} {'ftmax':>6} {'slow':>5} {'gpu':>6} {'gpumx':>6} | {'cpu%':>5} {'P%':>4} {'E%':>4} {'PGHz':>5} {'EGHz':>5} {'mW':>5} | {'budget':>6} {'tpl':>3} {'tll':>3} {'MiB':>6} | {'jit/s':>6} {'mprot/s':>7} {'exc/s':>6} | {'gpu%':>4} {'ren%':>4} {'til%':>4} {'cpuE':>5} {'gpuE':>5} | {'sysmW':>5} {'batmA':>5} | {'srv/f':>6}"
    out = [hdr]
    fmt = lambda v, w, p=0: (f"{v:>{w}.{p}f}" if isinstance(v, (int, float)) else f"{'-':>{w}}")
    for r in rows:
        out.append(f"{r['t']:>4} {fmt(r['fps'],6,1)} {fmt(r['ft_avg'],6,2)} {fmt(r['ft_max'],6,2)} {r['slow_frames']:>5} "
                   f"{fmt(r['gpu_avg'],6,2)} {fmt(r['gpu_max'],6,2)} | {fmt(r['cpu_pct'],5)} {fmt(r['p_pct'],4)} "
                   f"{fmt(r['e_pct'],4)} {fmt(r['p_ghz'],5,2)} {fmt(r['e_ghz'],5,2)} {fmt(r['mw'],5)} | "
                   f"{fmt(r['budget_mw'],6)} {fmt(r['tpl'],3)} {fmt(r['tll'],3)} {fmt(r['app_mib'],6)} | "
                   f"{r['jit_ps']:>6} {r['mprot_ps']:>7} {r['mexc_ps']:>6} | {fmt(r['gpu_util'],4)} "
                   f"{fmt(r['ren_util'],4)} {fmt(r['til_util'],4)} {fmt(r['cpu_energy'],5,1)} {fmt(r['gpu_energy'],5,1)} | "
                   f"{fmt(r['sys_mw'],5)} {fmt(r['batt_ma'],5)} | {fmt(r['srv_pf'],6,1)}")
    # a bucket that presented nothing outside a load is not play
    steady = [r for r in rows[1:] if r["live_s"]]
    at120 = [r for r in steady if r["fps"] >= 115]
    # a lasting drop: this bucket and the next both played and below 110 fps
    # (a single slow bucket is a load hitch, counted in slow_frames and ftmax)
    first_drop = next((r["t"] for r, n in zip(rows[1:], rows[2:])
                       if r["live_s"] and n["live_s"] and r["fps"] < 110 and n["fps"] < 110), None)
    summ = {
        "buckets": len(rows), "bucket_s": bucket,
        **steady_means(steady),
        "fps_min": min((r["fps"] for r in steady), default=None),
        "fps_median": sorted(r["fps"] for r in steady)[len(steady) // 2] if steady else None,
        "share_at_120": round(len(at120) / len(steady), 2) if steady else None,
        "first_drop_s": first_drop,
        "budget_start_mw": budget[0][2] if budget else None,
        "budget_min_mw": min((r[2] for r in budget), default=None),
        "budget_first_s": round(budget[0][0] - t0) if budget else None,
        "budget_clients": {c: min(v for (_, cc, v) in budget if cc == c) for c in sorted({r[1] for r in budget})},
        # each client's last value: what the phone was held to when the run ended
        "budget_clients_end": {c: [v for (_, cc, v) in budget if cc == c][-1] for c in sorted({r[1] for r in budget})},
        # ProcessInfo.thermalState from the app's `title: thermal:` lines; a run
        # that did not start at nominal started hot
        "thermal_start": next((m[1] for m in (THERMAL_STATE_RE.search(l) for l in lines) if m and m[2]), None),
        "thermal_states": [m[1] for m in (THERMAL_STATE_RE.search(l) for l in lines) if m],
        "first_pressure_s": next((r["t"] for r in rows if (r["tpl"] or 0) > 0), None),
        # None: thermalmonitord logged no pressure change, so the level is unknown
        "max_pressure": max((r["tpl"] for r in rows if r["tpl"] is not None), default=None),
        # the battery gauge's charge (%) at the first and last power.txt sample, and
        # whether a charger was on: runs at different charge do not compare
        "battery_start_pct": next((j["CurrentCapacity"] for (_, j) in power if "CurrentCapacity" in j), None),
        "battery_end_pct": next((j["CurrentCapacity"] for (_, j) in reversed(power) if "CurrentCapacity" in j), None),
        "charger": any(j.get("ExternalConnected") for (_, j) in power) if power else None,
        "log_bytes": os.path.getsize(this),
    }
    hitches = hitch_table(d, hud, vpad, ev, t0)
    summ["hitches"] = {k: sum(1 for h in hitches if h["ms"] >= k) for k in HITCH_MS}
    summ["server"] = server_summary(steady, srv, srvt, xpt, names, t0, bucket)
    out.append("summary " + json.dumps(summ))
    with open(os.path.join(d, "summary.txt"), "w") as f:
        f.write("\n".join(out) + "\n")
    threads = thread_table(d, hud, xp, xpt, names, t0, bucket * 3)
    server = server_table(d, hud, srv, srvt, xpt, names, t0, bucket * 3)
    import sampleprof
    prof = sampleprof.report(lines)   # a launch with WINE_IOS_PROF=1
    if prof:
        with open(os.path.join(d, "profile.txt"), "w") as f:
            f.write(prof)
    import passprof
    passes = passprof.report(lines)   # a launch with DXMT_PASS_PROF=1
    if passes:
        with open(os.path.join(d, "passes.txt"), "w") as f:
            f.write(passes)
    with open(os.path.join(d, "summary.json"), "w") as f:
        json.dump({"summary": summ, "rows": rows, "threads": threads, "server": server, "hitches": hitches}, f, indent=1)
    if echo:
        print("\n".join(out))
    return summ


CAPTURE_RE = re.compile(r"A new capture will be saved to .*?/Documents/(.*\.gputrace)")


def pull_capture(phone, out, ev):
    """The .gputrace DXMT named in the run's log (--gpu-capture), pulled whole into
    the run directory with tools/gputrace.py's summary beside it; its path, or None."""
    with open(os.path.join(out, "run", "pull", "s1-host.log"), errors="replace") as f:
        m = [CAPTURE_RE.search(l) for l in f]
    paths = [x[1] for x in m if x]
    if not paths:
        ev("warning", message="--gpu-capture: the log names no capture (the frame was never reached?)")
        return None
    try:
        local = phone.pull_bundle("Documents/" + paths[-1], out)
    except phonelib.PhoneError as e:
        ev("error", message=f"pulling the capture: {e}")
        return None
    import gputrace
    try:
        with open(os.path.join(out, "capture.txt"), "w") as f:
            f.write(gputrace.report(gputrace.summarize(local)))
    except (OSError, ValueError, KeyError) as e:
        ev("warning", message=f"reading the capture: {e}")
    ev("gpu-capture", path=local)
    return local


def steady_means(steady):
    """Over the played buckets: the frame rate over their played time, the 10th
    percentile bucket, and the mean frame and GPU time (bucket means, by frames)."""
    live = sum(r["live_s"] for r in steady)
    fps = sorted(r["fps"] for r in steady)
    wavg = lambda k: (round(sum(r[k] * r["fps"] * r["live_s"] for r in steady if r.get(k) is not None)
                            / sum(r["fps"] * r["live_s"] for r in steady if r.get(k) is not None), 2)
                      if any(r.get(k) is not None and r["fps"] for r in steady) else None)
    return {"fps_mean": round(sum(r["fps"] * r["live_s"] for r in steady) / live, 1) if live else None,
            "fps_p10": fps[len(fps) // 10] if fps else None,
            "ft_avg_ms": wavg("ft_avg"), "gpu_avg_ms": wavg("gpu_avg")}


FIRST_FRAME_RE = re.compile(r"\+([0-9.]+) s first frame")


def run_info(d):
    """What made run DIR: run.json (pp perf writes it), else the title and settings the
    app was launched with (the play's `launched` event: UI_ACTIONS, UI_SETTINGS)."""
    info = {}
    with contextlib.suppress(OSError, ValueError):
        with open(os.path.join(d, "run.json")) as f:
            info = json.load(f)
    with contextlib.suppress(OSError):
        with open(os.path.join(d, "run", "events.jsonl")) as f:
            env = next((json.loads(l).get("env", []) for l in f if '"event": "launched"' in l), [])
        env = dict(e.partition("=")[::2] for e in env)
        play = [x[len("play:"):] for x in env.get("UI_ACTIONS", "").split(",") if x.startswith("play:")]
        info.setdefault("title", play[0] if play else None)
        if not info.get("settings") and env.get("UI_SETTINGS"):
            info["settings"] = env["UI_SETTINGS"]
    return info


def settings_of(info):
    """The run's launch settings, flattened: env.NAME for each environment entry."""
    try:
        j = json.loads(info.get("settings") or "{}")
    except ValueError:
        return {"settings": info.get("settings")}
    flat = {k: v for k, v in j.items() if k != "environment"}
    flat.update({"env." + e.get("name", "?"): e.get("value") for e in j.get("environment", [])})
    return flat


def run_row(d):
    """One run's comparable figures, from its summary.json, run.json and result line."""
    with open(os.path.join(d, "summary.json")) as f:
        j = json.load(f)
    summ, rows = j["summary"], j["rows"]
    steady = [r for r in rows[1:] if r["live_s"]]
    means = steady_means(steady)   # runs from before these were in the summary
    info = run_info(d)
    first = None
    with contextlib.suppress(OSError), open(os.path.join(d, "events.jsonl")) as f:
        for l in f:
            if '"event": "result"' in l:
                m = FIRST_FRAME_RE.search(" ".join(json.loads(l).get("timeline", [])))
                first = float(m[1]) if m else first
    return {"run": os.path.basename(os.path.normpath(d)), "dir": d, "title": info.get("title"),
            "settings": {**settings_of(info), **({"no_counters": True} if info.get("no_counters") else {})},
            "no_hud": info.get("no_hud"),
            **{k: summ.get(k, means.get(k)) for k in ("fps_mean", "fps_p10", "ft_avg_ms", "gpu_avg_ms")},
            "fps_median": summ.get("fps_median"), "first_frame_s": first,
            "thermal_start": summ.get("thermal_start"), "max_pressure": summ.get("max_pressure"),
            "battery_start_pct": summ.get("battery_start_pct"), "battery_end_pct": summ.get("battery_end_pct"),
            "charger": summ.get("charger"), "hitches": summ.get("hitches"),
            "rows": [(r["t"], r["fps"], r["live_s"]) for r in rows]}


def compare(dirs, window=30, as_json=False):
    """pp perf --compare: the runs side by side, the settings that differ, and each
    run's frame rate per WINDOW seconds of the table (its t, from the first frame line)."""
    runs = [run_row(d) for d in dirs]
    keys = sorted({k for r in runs for k in r["settings"]})
    differ = [k for k in keys if len({json.dumps(r["settings"].get(k)) for r in runs}) > 1]
    for r in runs:
        r["differs"] = {k: r["settings"].get(k) for k in differ}
    end = max((t for r in runs for (t, _, _) in r["rows"]), default=0)
    windows = []
    for lo in range(0, int(end) + 1, window):
        per = []
        for r in runs:
            seg = [(f, l) for (t, f, l) in r["rows"] if lo <= t < lo + window and l]
            live = sum(l for _, l in seg)
            per.append(round(sum(f * l for f, l in seg) / live, 1) if live else None)
        windows.append({"t": lo, "fps": per})
    if as_json:
        print(json.dumps({"runs": [{k: v for k, v in r.items() if k != "rows"} for r in runs], "windows": windows},
                         indent=1))
        return 0
    cols = [("fps_mean", "fps"), ("fps_p10", "p10"), ("fps_median", "median"), ("ft_avg_ms", "ft ms"),
            ("gpu_avg_ms", "gpu ms"), ("first_frame_s", "1st frame"), ("thermal_start", "thermal"),
            ("max_pressure", "press"), ("battery_start_pct", "bat%"), ("battery_end_pct", "end%"), ("charger", "chg")]
    show = lambda v: "-" if v is None else str(v)
    w = max(len(r["run"]) for r in runs)
    print(f"{'run':<{w}} {'title':<12} " + " ".join(f"{h:>9}" for _, h in cols))
    for r in runs:
        print(f"{r['run']:<{w}} {show(r['title']):<12} " + " ".join(f"{show(r[k]):>9}" for k, _ in cols))
    if differ:
        print("\nsettings that differ:")
        for r in runs:
            print(f"  {r['run']:<{w}} " + ", ".join(f"{k}={show(v)}" for k, v in r["differs"].items()))
    print(f"\nfps per {window} s of the table (t from the first frame line):")
    print(f"{'t':>5} " + " ".join(f"{r['run'][-12:]:>12}" for r in runs))
    for x in windows:
        print(f"{x['t']:>5} " + " ".join(f"{show(v):>12}" for v in x["fps"]))
    return 0


def pctl(xs, q):
    """The q-th percentile (0-100) of xs, nearest rank; None for none."""
    if not xs:
        return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, max(0, int(round(q / 100 * len(xs) + 0.5)) - 1))]


def window_row(d, lo, hi):
    """One run's figures over t = lo..hi s of its table (the plan's burst or
    sustained window): FPS over the played time, frame-interval percentiles and
    hitch counts from the HUD's per-frame intervals, GPU ms, the CPU and power
    columns as bucket means, the phone's mW a frame, all threads' Mi/f from the
    threads.txt windows that start in it, and the lowest power budget."""
    with open(os.path.join(d, "summary.json")) as f:
        j = json.load(f)
    rows = [r for r in j["rows"] if lo <= r["t"] < hi and r["live_s"]]
    live = sum(r["live_s"] for r in rows)
    mean = lambda k: (round(sum(r[k] for r in rows if r.get(k) is not None)
                            / len([r for r in rows if r.get(k) is not None]), 2)
                      if any(r.get(k) is not None for r in rows) else None)
    fps = round(sum(r["fps"] * r["live_s"] for r in rows) / live, 1) if live else None
    gpu = (round(sum(r["gpu_avg"] * r["fps"] * r["live_s"] for r in rows if r.get("gpu_avg") is not None)
                 / sum(r["fps"] * r["live_s"] for r in rows if r.get("gpu_avg") is not None), 2)
           if any(r.get("gpu_avg") is not None and r["fps"] for r in rows) else None)
    # every frame's interval from the HUD lines, at its line's time from the first line
    ft = []
    with contextlib.suppress(OSError):
        with open(os.path.join(d, "this-launch.log"), errors="replace") as f:
            t0 = None
            for l in f:
                m = HUD_RE.search(l)
                if not m:
                    continue
                t = secs_of(m[1], m[2], m[3])
                t0 = t if t0 is None else t0
                if lo <= t - t0 < hi:
                    ft += [float(x) for x in m[7].split(",")[0::2] if x]
    thr = [w["minst_per_frame"] for w in j.get("threads", []) if lo <= w["t"] < hi and w.get("minst_per_frame")]
    budgets = [r["budget_mw"] for r in rows if r.get("budget_mw")]
    sysmw = mean("sys_mw")
    return {"run": os.path.basename(os.path.normpath(d)), "fps": fps,
            "p50": pctl(ft, 50), "p99": pctl(ft, 99), "p999": pctl(ft, 99.9),
            "h25": sum(1 for x in ft if x >= 25), "h50": sum(1 for x in ft if x >= 50),
            "h100": sum(1 for x in ft if x >= 100), "gpu_ms": gpu,
            "gpu%": mean("gpu_util"), "ren%": mean("ren_util"), "til%": mean("til_util"),
            "mi_f": round(sum(thr) / len(thr), 1) if thr else None,
            "cpu%": mean("cpu_pct"), "P%": mean("p_pct"), "E%": mean("e_pct"), "PGHz": mean("p_ghz"),
            "cpu_mw": mean("mw"), "sys_mw": sysmw,
            "sys_mj_f": round(sysmw / fps, 1) if sysmw and fps else None,
            "budget_min": min(budgets) if budgets else None, "srv_f": mean("srv_pf"), "MiB": mean("app_mib")}


def compare_window(dirs, spec, as_json=False):
    """pp perf --compare DIR ... --window LO:HI: window_row for each run, as a table."""
    lo, _, hi = spec.partition(":")
    rows = [window_row(d, float(lo), float(hi)) for d in dirs]
    if as_json:
        print(json.dumps({"window": [float(lo), float(hi)], "runs": rows}, indent=1))
        return 0
    keys = [k for k in rows[0] if k != "run"]
    w = max(len(r["run"]) for r in rows)
    print(f"window t = {lo}..{hi} s")
    print(f"{'run':<{w}} " + " ".join(f"{k:>8}" for k in keys))
    for r in rows:
        print(f"{r['run']:<{w}} " + " ".join(f"{'-' if r[k] is None else r[k]:>8}" for k in keys))
    return 0


HITCH_MS = (25, 50, 100)
LOAD_GAP_S = 2.0


def played_s(a, z):
    """Seconds the frames between frame lines a and z took by z's frame times
    (the HUD writes a line a second or every 100 frames, whichever is first,
    with each frame's time; a stall adds wall time no frame time covers).
    DXMT Present lines carry no frame times: 0."""
    ft = z[2]
    return (z[1] - a[1]) * sum(ft) / len(ft) / 1000 if ft else 0.0


EV_KINDS = ("jit", "mprot", "mexc", "shc_ms", "wait_ms")


def hitch_table(d, hud, vpad, ev, t0, slack=0.3):
    """hitches.txt: every frame interval of at least HITCH_MS[0] ms, with its
    time after the first HUD line, the pad step then playing, and the events
    (EV_KINDS) logged from the frame's start to its end, each widened by
    `slack` s because untimed lines take the time of the last timed one. A HUD
    line closes the second its pairs cover, so a frame's end is the line's time
    less the intervals after it."""
    res = []
    for t, _, ft, _, _ in hud:
        end = t
        for i in range(len(ft) - 1, -1, -1):
            if ft[i] >= HITCH_MS[0]:
                lo, hi = end - ft[i] / 1000.0 - slack, end + slack
                step = ([s for (ts, s) in vpad if ts <= end] or [""])[-1]
                h = {"t": round(end - t0, 2), "ms": ft[i], "vpad": step}
                h.update({k: round(sum(n for (te, kk, n) in ev if kk == k and lo <= te < hi), 1) for k in EV_KINDS})
                res.append(h)
            end -= ft[i] / 1000.0
    res.sort(key=lambda h: h["t"])
    with open(os.path.join(d, "hitches.txt"), "w") as f:
        f.write(f"{'t':>8} {'ms':>7} {'jit':>6} {'mprot':>6} {'mexc':>6} {'shc_ms':>7} {'wait_ms':>7}  vpad step\n")
        for h in res:
            f.write(f"{h['t']:>8.2f} {h['ms']:>7.2f} {h['jit']:>6.0f} {h['mprot']:>6.0f} {h['mexc']:>6.0f} "
                    f"{h['shc_ms']:>7.1f} {h['wait_ms']:>7.1f}  {h['vpad']}\n")
    return res


def thread_table(d, hud, xp, xpt, names, t0, window, top=8):
    """threads.txt: per window, the busiest threads by instructions retired.
    cpu% is of one core; Mi/f (million instructions per presented frame) does
    not depend on the cluster or clock the scheduler gave the thread, so it is
    the measure of work to compare between runs and phases."""
    dts = {round(r[0], 3): r[1] for r in xp}   # [xp] and [xp-t] of one tick share the wall time
    out, res = [], []
    w = 0
    while True:
        lo, hi = t0 + w * window, t0 + (w + 1) * window
        if lo > (hud[-1][0] if hud else 0):
            break
        seg = [e for e in xpt if lo <= e[0] < hi]
        fr = [h for h in hud if lo <= h[0] < hi]
        w += 1
        if not seg or len(fr) < 2:
            continue
        frames = fr[-1][1] - fr[0][1]
        wall = sum(dts.get(round(t, 3), 250.0) for t, _ in seg)
        acc = {}
        for _, ents in seg:
            for k, (p, e, mi) in ents.items():
                a = acc.setdefault(k, [0.0, 0.0, 0.0])
                a[0] += p
                a[1] += e
                a[2] += mi
        tot = [sum(a[i] for a in acc.values()) for i in range(3)]
        rows = []
        for k, (p, e, mi) in sorted(acc.items(), key=lambda kv: -kv[1][2])[:top]:
            rows.append({"thread": k, "name": names.get(k, ""), "cpu_pct": round(100 * (p + e) / wall),
                         "p_share": round(p / (p + e), 2) if p + e else 0.0,
                         "minst_per_frame": round(mi / frames, 2) if frames else None})
        res.append({"t": round(lo - t0), "fps": round(frames / (fr[-1][0] - fr[0][0]), 1),
                    "cpu_pct": round(100 * (tot[0] + tot[1]) / wall),
                    "minst_per_frame": round(tot[2] / frames, 1) if frames else None, "top": rows})
        r = res[-1]
        out.append(f"t={r['t']:>4} fps={r['fps']:>6} cpu={r['cpu_pct']:>4}% all threads {r['minst_per_frame']} Mi/f")
        for x in rows:
            out.append(f"    {x['thread']:>9} {x['name'][:28]:28} cpu {x['cpu_pct']:>4}%  P {x['p_share']:>4.2f}  "
                       f"{x['minst_per_frame']:>6} Mi/f")
    with open(os.path.join(d, "threads.txt"), "w") as f:
        f.write("\n".join(out) + "\n")
    return res


def srv_in(srv, srvt, spans):
    """The [srv] and [srv-t] census summed over the (lo, hi) spans: wall ms, then
    for the process and for each thread the requests by kind, round-trip ms,
    blocked ms and blocked selects, and the process's requests by type."""
    inside = lambda t: any(lo <= t < hi for lo, hi in spans)
    zero = lambda: [[0] * len(SRV_KINDS), 0.0, 0.0, 0]
    wall, tot, types, per = 0.0, zero(), {}, {}
    add = lambda a, ks, r, b, nb: (a.__setitem__(0, [x + y for x, y in zip(a[0], ks)]),
                                   a.__setitem__(1, a[1] + r), a.__setitem__(2, a[2] + b),
                                   a.__setitem__(3, a[3] + nb))
    for t, dt, ks, r, b, nb, ty in srv:
        if inside(t):
            wall += dt
            add(tot, ks, r, b, nb)
            for k, v in ty.items():
                types[k] = types.get(k, 0) + v
    for t, ents in srvt:
        if inside(t):
            for k, v in ents.items():
                add(per.setdefault(k, zero()), *v)
    return wall, tot, types, per


def srv_figures(tid, name, census, frames, wall=None):
    """A census (kinds, rt ms, blk ms, blocked selects) per frame; with wall, the
    round-trip and blocked time as a share (%) of it (one thread's)."""
    ks, rt, blk, nblk = census
    pf = lambda v, p=2: round(v / frames, p)
    res = {"req_per_frame": pf(sum(ks)), "by_kind": {k: pf(v) for k, v in zip(SRV_KINDS, ks)},
           "rt_ms_per_frame": pf(rt, 3), "blk_ms_per_frame": pf(blk, 3), "blocked_per_frame": pf(nblk)}
    if wall is not None:
        res = {"thread": tid, "name": name, **res,
               "rt_pct": round(100 * rt / wall, 2) if wall else None,
               "blk_pct": round(100 * blk / wall, 2) if wall else None}
    return res


def server_summary(steady, srv, srvt, xpt, names, t0, bucket):
    """summary.json's server: over the played buckets, the wineserver requests per
    presented frame by kind and by type, the round-trip and blocked ms per frame,
    and the same for the busiest thread (the Windows thread that retired the most
    instructions there; the main thread in Hollow Knight), with its round-trip
    and blocked time as a share of its wall time. None when the run has no
    [srv] lines (a build before madeira-unix 0037)."""
    spans = [(t0 + r["t"], t0 + r["t"] + bucket) for r in steady]
    frames = sum(r["fps"] * r["live_s"] for r in steady)
    wall, tot, types, per = srv_in(srv, srvt, spans)
    if not wall or not frames:
        return None
    work = {}
    for t, ents in xpt:
        if any(lo <= t < hi for lo, hi in spans):
            for k, (_, _, mi) in ents.items():
                if not k.startswith("m"):
                    work[k] = work.get(k, 0.0) + mi
    top = sorted(types.items(), key=lambda kv: -kv[1])[:10]
    res = {"frames": round(frames), "secs": round(wall / 1000, 1), **srv_figures(None, None, tot, frames),
           "types_per_frame": {k: round(v / frames, 2) for k, v in top}}
    if work:
        busiest = max(work, key=work.get)
        res["busiest"] = srv_figures(busiest, names.get(busiest, ""),
                                     per.get(busiest, [[0] * len(SRV_KINDS), 0.0, 0.0, 0]), frames, wall)
    return res


def server_table(d, hud, srv, srvt, xpt, names, t0, window, top=6):
    """server.txt: per window, the wineserver requests per presented frame by
    kind, the round-trip and blocked ms and the blocked selects per frame, the
    busiest request types, and the threads with the most round-trip time, each
    with its round-trip and blocked time as a share of the window's wall time;
    then the busiest thread (instructions retired, marked *) when it is not
    among them. A select's blocked time is counted when it ends, so a thread
    woken after a long wait shows more than 100 %."""
    out, res = [], []
    w = 0
    while srv and hud:
        lo, hi = t0 + w * window, t0 + (w + 1) * window
        if lo > hud[-1][0]:
            break
        w += 1
        fr = [h for h in hud if lo <= h[0] < hi]
        wall, tot, types, per = srv_in(srv, srvt, [(lo, hi)])
        if not wall or len(fr) < 2 or fr[-1][1] == fr[0][1]:
            continue
        frames = fr[-1][1] - fr[0][1]
        r = {"t": round(lo - t0), "fps": round(frames / (fr[-1][0] - fr[0][0]), 1), **srv_figures(None, None, tot, frames),
             "types_per_frame": {k: round(v / frames, 2) for k, v in sorted(types.items(), key=lambda kv: -kv[1])[:6]},
             "top": [srv_figures(k, names.get(k, ""), v, frames, wall)
                     for k, v in sorted(per.items(), key=lambda kv: -kv[1][1])[:top]]}
        work = {}
        for t, ents in xpt:
            if lo <= t < hi:
                for k, (_, _, mi) in ents.items():
                    if not k.startswith("m"):
                        work[k] = work.get(k, 0.0) + mi
        r["busiest"] = max(work, key=work.get) if work else None
        if r["busiest"] and all(x["thread"] != r["busiest"] for x in r["top"]):
            r["top"].append(srv_figures(r["busiest"], names.get(r["busiest"], ""),
                                        per.get(r["busiest"], [[0] * len(SRV_KINDS), 0.0, 0.0, 0]), frames, wall))
        res.append(r)
        kinds_s = lambda x: " ".join(f"{k} {v:g}" for k, v in x["by_kind"].items())
        out.append(f"t={r['t']:>4} fps={r['fps']:>6} all threads {r['req_per_frame']:g} req/f [{kinds_s(r)}] "
                   f"rt {r['rt_ms_per_frame']:g} ms/f blk {r['blk_ms_per_frame']:g} ms/f "
                   f"({r['blocked_per_frame']:g} blocked/f)")
        out.append("    types/f: " + " ".join(f"{k} {v:g}" for k, v in r["types_per_frame"].items()))
        for x in r["top"]:
            mark = "*" if x["thread"] == r["busiest"] else " "
            out.append(f"   {mark}{x['thread']:>9} {x['name'][:28]:28} {x['req_per_frame']:>7g} req/f [{kinds_s(x)}] "
                       f"rt {x['rt_ms_per_frame']:g} ms/f ({x['rt_pct']:g}%) blk {x['blk_ms_per_frame']:g} ms/f "
                       f"({x['blk_pct']:g}%, {x['blocked_per_frame']:g}/f)")
    if srv:
        with open(os.path.join(d, "server.txt"), "w") as f:
            f.write("\n".join(out) + "\n")
    return res


class Terminated(Exception):
    """SIGTERM or SIGHUP before the play started."""


def when_of(text):
    """`SECS` or `first-frame+SECS` as (from_first_frame, secs); None when neither."""
    ff = text.startswith("first-frame+")
    secs = text[len("first-frame+"):] if ff else text
    return (ff, int(secs)) if secs.isdigit() else None


def main(argv):
    """The whole run holds the device lock; the UI driver it starts uses it."""
    if {"--analyze", "--compare", "--dry-run", "-h", "--help"} & set(argv):
        return run_main(argv)
    secs = next((int(v) for k, v in zip(argv, argv[1:]) if k == "--secs" and v.isdigit()), 120)
    try:
        # about: the HUD launch, the play to its first frame, --secs, the pulls (--cool waits come first)
        with phonelib.device_lock("pp perf", events=phonelib.Events(), expect_s=secs + 120):
            return run_main(argv)
    except phonelib.PhoneError as e:
        return phonelib.fail(phonelib.Events(), str(e))
    except Terminated as e:
        return phonelib.Events().result(False, 143, why="terminated", signal=str(e))


def run_main(argv):
    p = argparse.ArgumentParser(prog="pp perf", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out")
    p.add_argument("--title", default="app-367520", help="the catalogue title to Play (default: Hollow Knight)")
    p.add_argument("--secs", type=int, default=120, help="seconds after the first frame; the app is killed then")
    p.add_argument("--shot", action="append", default=[], metavar="[first-frame+]SECS",
                   help="screenshot this many seconds after launch (first-frame+SECS: after the first frame)")
    p.add_argument("--cool", type=float, metavar="MIN",
                   help="first wait until MIN minutes have passed since the last pp perf run ended and "
                        "thermalmonitord's last pressure level since then is 0")
    p.add_argument("--cool-max", type=float, default=45, metavar="MIN",
                   help="with --cool: start anyway after this many minutes of waiting (default 45)")
    p.add_argument("--settings", metavar="JSON", help="save these launch settings for the title first (for this run; --keep-settings keeps them)")
    p.add_argument("--pad", action="append", default=[], metavar="[first-frame+]SECS:SCRIPT",
                   help="launch with the scripted pad and push SCRIPT (a file or a tools/pad/ name) this many "
                        "seconds after launch, or after the first frame (repeatable)")
    p.add_argument("--analyze", metavar="DIR", help="only analyse an existing run directory")
    p.add_argument("--compare", nargs="+", metavar="DIR",
                   help="only compare finished runs: their figures side by side, the launch settings that differ, "
                        "and the frame rate per 30 s (--json: the same as JSON)")
    p.add_argument("--json", action="store_true", help="with --compare: JSON instead of tables")
    p.add_argument("--window", metavar="LO:HI",
                   help="with --compare: each run's figures over t = LO..HI s instead (FPS, frame-interval "
                        "p50/p99/p99.9 and hitches, GPU ms and utilisation, all threads' Mi/f, CPU and phone "
                        "power, the phone's mJ a frame, the lowest budget, srv/f)")
    p.add_argument("--profile", metavar="DIR",
                   help="only print the run's sampling profile, symbolised (a run with --cpu-prof; "
                        "tools/sampleprof.py)")
    p.add_argument("--keep-log", action="store_true", help="do not rotate s1-host.log before the launch")
    p.add_argument("--syslog-all", action="store_true", help="also keep the whole device syslog (syslog-all.txt)")
    p.add_argument("--no-hud", action="store_true",
                   help="turn Settings' Metal HUD off first (its per-frame logging costs CPU); frames then come from "
                        "the game layer's [frames] lines (any backend) and the frame-time, GPU and memory columns "
                        "stay empty")
    p.add_argument("--pass-prof", action="store_true",
                   help="turn on Settings' Diagnostics, GPU time per pass, for this run: winemetal times every "
                        "encoder of two frames in every 1200 presents; passes.txt tables them (tools/passprof.py)")
    p.add_argument("--gpu-capture", type=int, metavar="FRAME",
                   help="turn on Settings' Diagnostics, GPU capture, for this run: DXMT writes frame FRAME (presents "
                        "from the game's first) as a .gputrace; it is pulled into the run directory and "
                        "capture.txt summarizes it (tools/gputrace.py). Capturing costs every frame: no figures")
    p.add_argument("--cpu-prof", action="store_true",
                   help="turn on Settings' Diagnostics, CPU sampling, for this run: the busiest threads sampled "
                        "at about 1 kHz, 3 s in every 15 s; profile.txt (tools/sampleprof.py)")
    p.add_argument("--no-counters", action="store_true",
                   help="turn off Settings' Diagnostics, Runtime counters, for this run (from the play's start: "
                        "the HUD launch before it sets it): the runtime's hot-path census as in a release build, "
                        "the samplers kept; the [xp-api], [sync-census] and [srv] figures then read zero")
    p.add_argument("--energy", action="store_true",
                   help="also sample Xcode's energy gauge for the app (energy.txt); it perturbs the title")
    p.add_argument("--frames", choices=("auto", "hud", "layer", "present"), default="auto",
                   help="with --analyze: count frames from the HUD's lines, the game layer's [frames] lines or "
                        "DXMT's Present lines (auto: the HUD's when the run has them, then the layer's)")
    p.add_argument("--expect-ipa", metavar="IPA|SHA256", help="refuse unless the phone has this IPA (pp ui)")
    p.add_argument("--any-build", action="store_true", help="measure whatever the phone has installed (pp ui)")
    p.add_argument("--keep-settings", action="store_true", help="keep the HUD switch and --settings after the run")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    if a.analyze:
        analyze(a.analyze, frames_from=a.frames)
        return 0
    if a.compare:
        if a.window:
            return compare_window(a.compare, a.window, as_json=a.json)
        return compare(a.compare, as_json=a.json)
    if a.profile:
        import sampleprof as prof
        return prof.main([a.profile])
    out = phonelib.run_dir("perf-runs", a.out)
    ev = phonelib.Events(out)
    with open(os.path.join(out, "run.json"), "w") as f:   # what --compare sets side by side
        json.dump({"title": a.title, "secs": a.secs, "settings": a.settings, "no_hud": a.no_hud,
                   "pass_prof": a.pass_prof, "cpu_prof": a.cpu_prof, "gpu_capture": a.gpu_capture,
                   "no_counters": a.no_counters,
                   "pad": a.pad, "cool": a.cool, "energy": a.energy}, f)
    vpads = []
    for v in a.pad:
        when, _, name = v.partition(":")
        try:
            text = pad.script(name)
        except phonelib.PhoneError as e:
            p.error(f"--pad {v}: {e}")
        if when_of(when) is None:
            p.error(f"--pad {v}: want [first-frame+]SECS:SCRIPT")
        vpads.append((when_of(when), name, text))
    for sh in a.shot:
        if when_of(sh) is None:
            p.error(f"--shot {sh}: want [first-frame+]SECS")
    a.shot = [when_of(sh) for sh in a.shot]
    # SIGTERM or SIGHUP: before the play, stop here; during it, pp ui ends the app and
    # writes its result, and the monitors stop below as after any run.
    term = {"run": None, "sig": None, "monitors": False}

    def on_term(signum, _frame):
        term["sig"] = signal.Signals(signum).name
        if term["run"] is None:
            if not term["monitors"]:
                raise Terminated(term["sig"])
        elif term["run"].poll() is None:
            term["run"].send_signal(signal.SIGTERM)
    if not a.dry_run:
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, on_term)
        pw = battery_power()
        b = phonelib.battery_of(pw)
        ev("battery", **b)
        if b.get("warning"):
            ev("warning", message=b["warning"] + "; this run's figures will not compare with a charged one's")
    # Settings' Metal HUD, in a launch of its own: Metal reads its switches as the process starts.
    hud = ["python3", "-u", UI_RUN, "--out", os.path.join(out, "hud"), "--action", "hud:" + ("off" if a.no_hud else "on")]
    # Diagnostics' switches: each launch reads them (Diagnostics.swift), so they ride along
    # in the same session, and are undone after it as the HUD's is.
    for on, key in ((a.pass_prof, "passProfile"), (a.cpu_prof, "cpuProfile"), (a.no_counters, "runtimeCountersOff")):
        hud += ["--action", f"set:{key}=" + ("true" if on else "false")]
    hud += ["--action", f"set:gpuCaptureFrame={a.gpu_capture or 0}"]
    hud += ["--keep-log"] if a.keep_log else []
    both = (["--expect-ipa", a.expect_ipa] if a.expect_ipa else []) + ["--any-build"] * a.any_build \
        + ["--keep-settings"] * a.keep_settings
    hud += both
    if subprocess.call(hud + (["--dry-run"] if a.dry_run else []), stdout=subprocess.DEVNULL):
        return phonelib.fail(ev, f"pp perf: setting the Metal HUD failed ({os.path.join(out, 'hud')})")
    phone = phonelib.Phone(out, dry=a.dry_run, events=ev)
    if vpads and not a.dry_run:   # a script left from an earlier run would play from the launch
        pad.push(phone, pad.REST)
    if a.cool and not a.dry_run:
        try:
            ended = json.load(open(LAST)).get("ended", 0)
        except (OSError, ValueError):
            ended = 0
        # A play through pp ui (a check, a person's session) heats the phone as a run
        # does: the rest counts from whichever ended last.
        try:
            ended = max(ended, json.load(open(LAST_PLAY)).get("ended", 0))
        except (OSError, ValueError):
            pass
        try:
            last = json.load(open(LAST))
        except (OSError, ValueError):
            last = {}
        wait = max(0.0, ended + a.cool * 60 - time.time())
        ev("cooling", rested_min=round((time.time() - ended) / 60, 1) if ended else None,
           want_min=a.cool, wait_s=round(wait), pressure=cool_state(last, ended), power=battery_power())
        time.sleep(wait)
        # then until the pressure level is back at 0 (a level of None: none was
        # logged since the last run, which a run that never raised it leaves)
        give_up = time.time() + a.cool_max * 60
        while (lvl := cool_state(last, ended)) not in (None, 0) and time.time() < give_up:
            ev("cooling", pressure=lvl, rested_min=round((time.time() - ended) / 60, 1))
            time.sleep(60)
        ev("cooled", pressure=lvl, rested_min=round((time.time() - ended) / 60, 1) if ended else None,
           ok=lvl in (None, 0))
    stop_follow()
    cmd = ["python3", "-u", UI_RUN, "--out", os.path.join(out, "run"), "--play", a.title,
           "--until", f"first-frame+{a.secs}", "--quiet", "--wait", str(a.secs + 300)]
    cmd += ["--settings", f"{a.title}:{a.settings}"] if a.settings else []
    cmd += ["--pad"] if vpads else []
    cmd += ["--keep-log"] if a.keep_log else []
    cmd += both
    cmd += ["--dry-run"] if a.dry_run else []
    if a.dry_run:
        ev("dry-run", cmd=cmd)
        return subprocess.call(cmd)
    bud = open(os.path.join(out, "budget.txt"), "w")
    term["monitors"] = True
    syslog = subprocess.Popen(["timeout", str(a.secs + 400), *pmd("syslog", "live", "-e", "Budget Trace",
                                                                  "-e", "setDetailedThermalPowerBudget")],
                              stdout=bud, stderr=subprocess.DEVNULL)
    power_stop = threading.Event()
    power_th = power_sampler(os.path.join(out, "power.txt"), power_stop)
    therm_f = open(os.path.join(out, "thermal.txt"), "w")
    thermal = subprocess.Popen(["timeout", str(a.secs + 400), *pmd("syslog", "live", "-pn", "thermalmonitord")],
                               stdout=therm_f, stderr=subprocess.DEVNULL)
    gpu_mon = stamped(["developer", "dvt", "graphics"], os.path.join(out, "gpu.txt"), a.secs + 400)
    energy_mon = None
    full = None
    if a.syslog_all:
        full = subprocess.Popen(["timeout", str(a.secs + 400), *pmd("syslog", "live", "-o", os.path.join(out, "syslog-all.txt"))],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shots = []
    t_launch = time.monotonic()
    first_frame = threading.Event()
    t_first = [None]

    def wait_for(when):
        """Sleep until `when` ((from_first_frame, secs)); False if the run ended first."""
        ff, s = when
        if ff:
            while not first_frame.wait(1):
                if run.poll() is not None:
                    return False
            base = t_first[0]
        else:
            base = t_launch
        time.sleep(max(0, base + s - time.monotonic()))
        return True
    run = term["run"] = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if term["sig"]:   # it came between the monitors starting and the play
        run.send_signal(signal.SIGTERM)
    pid = None
    ui_result = {}
    transcript = open(os.path.join(out, "ui-run.txt"), "w")
    timeline = []

    def shooter(when):
        if not wait_for(when):
            return
        ff, s = when
        path = phone.screenshot(os.path.join(out, f"shot-{'ff' if ff else ''}{s:03d}.png"))
        ev("screenshot", path=path, when=f"{'first-frame+' if ff else ''}{s}")
        if path:
            shots.append(path)

    def pusher(when, name, text):
        if not wait_for(when):
            return
        try:
            pad.push(phone, text)
            ok = True
        except phonelib.PhoneError as e:
            ok = str(e)
        ev("pad", script=name, after_s=round(time.monotonic() - t_launch, 1), ok=ok)

    for when in a.shot:
        threading.Thread(target=shooter, args=(when,), daemon=True).start()
    for v in vpads:
        threading.Thread(target=pusher, args=v, daemon=True).start()
    for line in run.stdout:
        transcript.write(line)
        transcript.flush()
        if '"event": "result"' in line:   # its timeline, why and hint go on this run's own result line
            ui_result = json.loads(line)
            timeline = ui_result.get("timeline", [])
        else:
            print(line, end="", flush=True)
        if not first_frame.is_set() and '"app:mark"' in line and '"first frame"' in line:
            t_first[0] = time.monotonic()
            first_frame.set()
        m = re.search(r'"event": "launched", "pid": (\d+)', line)
        if m:
            pid = m[1]
            if a.energy and pid != "0" and energy_mon is None:
                energy_mon = stamped(["developer", "dvt", "energy", pid], os.path.join(out, "energy.txt"), a.secs + 400)
    rc = run.wait()
    # pp ui ends the app itself; this is for a driver that died first (by bundle ID, never pid alone).
    if pid and pid != "0":
        try:
            phone.kill()
        except phonelib.PhoneError as e:
            ev("error", message=f"ending the app: {e}")
    time.sleep(5)
    power_stop.set()
    with open(LAST, "w") as f:
        json.dump({"ended": time.time(), "out": out, "followed": True}, f)
    follow_thermal()
    syslog.terminate()
    thermal.terminate()
    for mon in (gpu_mon, energy_mon):
        if mon:
            mon.terminate()
            try:
                mon.wait(15)
            except subprocess.TimeoutExpired:
                mon.kill()
    power_th.join(25)
    time.sleep(1)   # the pump threads close their files
    therm_f.close()
    if full:
        full.terminate()
    bud.close()
    summ, end = None, {}
    try:
        summ = analyze(out, echo=False) if os.path.exists(os.path.join(out, "run", "pull", "s1-host.log")) else None
    except (SystemExit, StopIteration, OSError) as e:   # nothing to analyse: the run's why says what happened
        end["analysis"] = str(e) or type(e).__name__
    if a.gpu_capture and os.path.exists(os.path.join(out, "run", "pull", "s1-host.log")):
        end["gpu_capture"] = pull_capture(phone, out, ev)
    if term["sig"]:
        rc, end["why"], end["signal"] = 143, "terminated", term["sig"]
    elif rc:
        end.update({k: ui_result[k] for k in ("why", "hint", "done") if ui_result.get(k)})
        end.setdefault("why", "the pp ui run failed (run/events.jsonl)")
    elif summ is None:
        rc, end["why"] = 1, "no summary: " + end.get("analysis", "the run pulled no s1-host.log")
    if ui_result.get("selfcheck"):
        end["selfcheck"] = ui_result["selfcheck"]
    if ui_result.get("pool"):
        end["pool"] = ui_result["pool"]
    if ui_result.get("limits"):
        end["limits"] = ui_result["limits"]
    if ui_result.get("band"):
        end["band"] = ui_result["band"]
    return ev.result(rc == 0, rc, out=out, timeline=timeline, shots=sorted(shots), summary=summ, **end,
                     **({"summary_txt": os.path.join(out, "summary.txt")} if summ else {}))

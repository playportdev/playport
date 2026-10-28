#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""pp gpu: GPU debugging on the phone from this workstation (docs/GPU-DEBUGGING.md).

  pp gpu capture --frame N [--title ID] [--secs S] [--pad [first-frame+]SECS:SCRIPT ...]
                 [--settings JSON] [--pass-prof] [--expect-gb G] [--out DIR]
      one frame of a play as a Metal .gputrace: sets Settings' Diagnostics (GPU capture
      at frame N, and the switches asked for) in one launch, plays in the next (Metal
      allows a capture only in a process that started with it), pulls the bundle into
      the run directory and writes capture.txt (pp gpu read), and passes.txt with
      --pass-prof. Not with validation: a capture with Metal validation on was never
      written (2026-09-29) --secs: seconds after the first frame to keep
      playing (default: N/50 + 20, about frame N at 60 FPS with room).
      --settings '{"graphics":"vulkan"}' captures on the Vulkan backend, where
      KosmicKrisp writes the frame (patches/mesa 0017). The capture is written into
      the game's folder on the phone: before the play the phone must have room for
      --expect-gb (default 1) above a 3.5 GB reserve, and after a pull whose files,
      bytes and links match the phone's the bundle is deleted there (afc.py rm-bundle)
  pp gpu validate [--title ID] [--secs S] [--pad ...] [--shaders | --stop] [--out DIR]
      a play with Metal's API validation (--shaders: and shader validation) on;
      validation.txt groups what it found: the API layer's messages, shader
      validation's findings with the function each came from, command buffer
      errors. --stop ends the process at the first API error and quotes the crash
      report's message
  pp gpu read BUNDLE [--calls | --json]
      what a capture asks of the GPU: passes, targets, pipelines, draws, and each
      shader's compiler statistics (tools/gputrace.py; no timings)
  pp gpu passes RUN_DIR | LOG
      the GPU time per pass of a run with GPU time per pass on (tools/passprof.py)
  pp gpu names [--fetch | DSC_DIR]
      the call-name table gputrace.py reads calls by, from the phone's shared cache:
      --fetch downloads it into $PLAYPORT_BUILD/cache/dsc-<phone>-<iOS> (7.5 GB for
      iOS 27.0) first; needed once per iOS version

On a Mac (decision 0165, tools/apple.py; docs/GPU-DEBUGGING.md#on-a-mac):

  pp gpu live --capture [first-frame+]SECS [--boundary layer|queue|device|ID] [--count N]
              [--profile [--gpu-state S]] [--trace TEMPLATE [--trace-at WHEN] [--trace-secs S]]
              [--title ID] [--secs S] [--pad ...] [--settings JSON] [--any-build] [--out DIR]
      a play started with Metal's capture layer (pp ui --capture-layer); at --capture,
      gpucapture takes N iterations of the boundary (layer: one presented frame) of the
      running game into the run directory as live-*.gputrace, with no frame number to
      guess; --profile then replays it on the phone and profiles it (pp gpu profile).
      --trace records the whole phone with an Instruments template (xctrace
      --all-processes, e.g. 'Metal System Trace', 'Time Profiler') at --trace-at,
      without the capture layer when no --capture is asked for
  pp gpu profile TRACE [--exec serial|overlapping] [--gpu-state S] [--read] [--out DIR]
      gpudebug replays TRACE on the phone and profiles it with every counter (the profile
      is embedded in the trace), then reads it back without the phone: profile.txt ranks
      the frame's encoders by GPU time, each with its counters' means over its interval
      (occupancy, ALU, F32, instruction, texture, cache, shader launch limiters,
      bandwidth); profile.json and profile/*.json hold the rows and the raw series.
      --read only reads a trace's embedded profile. Starts Xcode hidden for its GPU tools
      agent when the phone is not yet a replay device; no Xcode window is used

Every play goes through the app's UI (pp ui), under one hold of the device lock.
The Diagnostics switches last for that session and are undone at the app's next
launch outside it, as any driven setting is. A capture or validation run costs
every frame: its frame figures are not a measurement (pp perf is).
"""

import argparse
import contextlib
import glob
import json
import os
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import phonelib  # noqa: E402

UI = os.path.join(HERE, "ui.py")
CAPTURE_RE = re.compile(r"A new capture will be saved to .*?/Documents/(.*\.gputrace)")
# DXMT's report of a command buffer's error and its logs, where shader validation's findings arrive
CMDBUF_RE = re.compile(r"err:\s+(Device error at frame \d+: .*|Frame (\d+): (.*))$")
METAL_LOG_RE = re.compile(r"\{(Metal|MetalTools)\}\[\d+\] <(ERROR|FAULT|NOTICE|DEFAULT)>")
# The phone's free space a capture must leave (the device runs' stop rule)
RESERVE_GB = 3.5


def free_gb(phone):
    """The phone's free space in GB (lockdown's AmountDataAvailable, as pp phone status), or None."""
    text = phone.pmd("disk", "lockdown", "get", "com.apple.disk_usage", check=False)
    try:
        return json.loads(text[text.index("{"):text.rindex("}") + 1])["AmountDataAvailable"] / 1e9
    except (ValueError, KeyError):
        return None


def space_refusal(free, expect_gb):
    """Why a capture of about EXPECT_GB may not be written with FREE GB free, or None."""
    if free is None:
        return "the phone's free space could not be read (pp phone status)"
    if free - RESERVE_GB < expect_gb:
        return (f"the phone has {free:.1f} GB free: a capture of {expect_gb:g} GB would leave less than "
                f"the {RESERVE_GB:g} GB reserve")
    return None


def local_counts(path):
    """(files, bytes, links) of a pulled bundle, as afc.py's counts() of the phone's: links
    counted, never followed."""
    files = size = links = 0
    for root, dirs, names in os.walk(path):
        for n in names + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
            p = os.path.join(root, n)
            if os.path.islink(p):
                links += 1
            else:
                files += 1
                size += os.path.getsize(p)
    return files, size, links


def ui(out, *args, on_line=None):
    """One pp ui run in this session, its lines to on_line as they come; its result event
    (a dict, with at least "exit")."""
    cmd = [sys.executable, "-u", UI, "--out", out, *args]
    run = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    res, error = {}, None
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "ui-run.txt"), "w") as transcript:
        for line in run.stdout:
            transcript.write(line)
            if '"event": "result"' in line:
                try:
                    res = json.loads(line)
                except ValueError:
                    pass
            elif '"event": "error"' in line:
                try:
                    error = json.loads(line).get("message")
                except ValueError:
                    pass
            if on_line and '"event": "result"' not in line:
                on_line(line)
    res["exit"] = run.wait()
    if error and not res.get("why"):
        res["why"] = error
    return res


def device_log(out, secs):
    """The app's lines of the device log, into device-log.txt, while a play runs (the
    process Popen). Metal's validation logs there, with its text redacted."""
    f = open(os.path.join(out, "device-log.txt"), "w")
    return subprocess.Popen(["timeout", str(secs), "pymobiledevice3", "syslog", "live", "-pn", phonelib.EXECUTABLES[0]],
                            stdout=f, stderr=subprocess.DEVNULL, env=phonelib.pmd_env())


def crash_messages(out):
    """What a crash report of the play says ended it: the application-specific
    information Metal's validation fills with its assertion when it stops the process."""
    msgs = []
    for path in sorted(glob.glob(os.path.join(out, "run", "crashes", "*.ips"))):
        with open(path, errors="replace") as f:
            text = f.read()
        body = text.split("\n", 1)[-1]
        try:
            doc = json.loads(body)
        except ValueError:
            doc = {}
        asi = doc.get("asi") or {}
        for lines in asi.values():
            msgs += [l for l in (lines if isinstance(lines, list) else [lines]) if l]
        if not asi:
            msgs += re.findall(r"(-\[MTLDebug[^\"]*|failed assertion[^\"]*)", text)
    return msgs


NSLOG_RE = re.compile(r"^\d{4}-\d\d-\d\d [\d:.]+ \S+\[\d+:\d+\] (.+ Validation)$")
LOG_PREFIX_RE = re.compile(r"^(\d{4}-|err:|warn:|info:|fixme:|trace:|\[|[0-9a-f]{4}:|[EDIW] |title:|jit:|hostio:|ui:|vpad:|ml\d)")
FUNCTION_RE = re.compile(r"err:\s+(vertex|fragment|kernel|object|mesh) function: \"([^\"]+)\"")


def validation_findings(log):
    """Metal's validation output in a play's log, grouped:
    api     {(check, message): n}: the API layer's NSLog lines ("<Check> Validation",
            then the message), which reach stderr
    shader  {(message, function): n}: shader validation's findings, which arrive as
            command buffer logs DXMT writes out (err: Frame N: ..., then the function)
    errors  {message: n}: command buffer errors (err: Device error at frame N: ...)
    frames  the frames with shader findings"""
    api, shader, errors, frames = {}, {}, {}, set()
    check, pending = None, None
    hexaddr = re.compile(r"0x[0-9a-f]+")
    with open(log, errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = NSLOG_RE.match(line)
            if m:
                check = m[1]
                continue
            if check is not None:
                if line and not LOG_PREFIX_RE.match(line):
                    key = (check, hexaddr.sub("0x…", line.strip()))
                    api[key] = api.get(key, 0) + 1
                    check = None if not line.endswith(".") or "previous" in line else check
                    continue
                check = None
            m = CMDBUF_RE.search(line)
            if m:
                if m[2]:
                    frames.add(int(m[2]))
                    pending = m[3]
                else:
                    key = re.sub(r"frame \d+", "frame N", m[1])
                    errors[key] = errors.get(key, 0) + 1
                continue
            m = FUNCTION_RE.search(line)
            if m and pending is not None:
                key = (pending, f"{m[1]} {m[2]}")
                shader[key] = shader.get(key, 0) + 1
                pending = None
    if pending is not None:
        shader[(pending, "?")] = shader.get((pending, "?"), 0) + 1
    return api, shader, errors, frames


def validation_report(out, log, level):
    """validation.txt: what the log says was armed, the API layer's and shader
    validation's findings grouped, the device log's Metal error count, and a
    stopping error's message."""
    with open(log, errors="replace") as f:
        armed = [l.strip() for l in f if "diagnostics: Metal validation (" in l]
    counts = {}
    dl = os.path.join(out, "device-log.txt")
    if os.path.exists(dl):
        with open(dl, errors="replace") as f:
            for l in f:
                m = METAL_LOG_RE.search(l)
                if m and "Validation Enabled" not in l and "Compiling Shader" not in l:
                    counts[f"{m[1]} {m[2]}"] = counts.get(f"{m[1]} {m[2]}", 0) + 1
    crashes = crash_messages(out)
    api, shader, errors, frames = validation_findings(log)
    lines = armed or ["the log does not show Metal validation on"]
    if errors:
        lines += ["", "command buffer errors:"] + [f"  {n:>8}  {k}" for k, n in sorted(errors.items(), key=lambda kv: -kv[1])]
    if shader:
        lines += ["", f"shader validation, in {len(frames)} frames (finding, the function it came from):"]
        lines += [f"  {n:>8}  {msg}  [{fn}]" for (msg, fn), n in sorted(shader.items(), key=lambda kv: -kv[1])]
    if api:
        lines += ["", "API validation (check: message):"]
        lines += [f"  {n:>8}  {c}: {msg}" for (c, msg), n in sorted(api.items(), key=lambda kv: -kv[1])[:60]]
    lines += [""] + [f"device log: {n} {k} lines (text redacted by the phone)" for k, n in sorted(counts.items())]
    if level == "stop":
        lines += (["stopped at:"] + [f"  {m}" for m in crashes]) if crashes else \
                 ["no crash report: no API error before the play ended"]
    with open(os.path.join(out, "validation.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return {"armed": bool(armed), "shader_findings": sum(shader.values()), "api_findings": sum(api.values()),
            "cmdbuf_errors": sum(errors.values()), "stopped_at": crashes[:3]}


def when_of(v):
    """`SECS` or `first-frame+SECS` as (from_first_frame, secs); None when neither."""
    m = re.fullmatch(r"(first-frame\+)?(\d+(?:\.\d+)?)", v)
    return (bool(m[1]), float(m[2])) if m else None


def play(a, ev, out, settings, hooks=(), ui_args=()):
    """The settings launch, then the play, with pad scripts pushed at their times (as
    pp perf's --pad) and each hook (when, name, fn) called at its time on its own thread
    with the app's pid; the play's result."""
    import pad
    acts = []
    for k, v in settings.items():
        acts += ["--action", f"set:{k}={v}"]
    anyb = ["--any-build"] if getattr(a, "any_build", False) else []
    if acts:
        r = ui(os.path.join(out, "set"), *acts, "--action", "wait:5", *anyb)   # wait: the value reaches disk
        if not r.get("ok"):
            raise phonelib.PhoneError(f"setting Diagnostics failed: {r.get('why') or r} ({out}/set)")
        ev("diagnostics", **settings)
    timed = []
    for v in a.pad:
        when, _, name = v.partition(":")
        if when_of(when) is None:
            raise phonelib.PhoneError(f"--pad {v}: want [first-frame+]SECS:SCRIPT")
        text = pad.script(name)
        timed.append((when_of(when), "pad:" + name, lambda pid, text=text: pad.push(phone, text)))
    phone = phonelib.Phone(out, events=ev)
    if timed:   # a script left from an earlier run would play from the launch
        pad.push(phone, pad.REST)
    timed += list(hooks)
    t_launch, t_first, first = time.monotonic(), [None], threading.Event()
    done, pid = threading.Event(), [None]

    def runner(when, name, fn):
        ff, secs = when
        if ff:
            while not first.wait(1):
                if done.is_set():
                    return
        base = t_first[0] if ff else t_launch
        if done.wait(max(0, base + secs - time.monotonic())):
            return
        try:
            said = fn(pid[0])
            ok = True
        except phonelib.PhoneError as e:
            said, ok = None, str(e)
        ev("hook" if not name.startswith("pad:") else "pad", what=name.removeprefix("pad:"),
           after_s=round(time.monotonic() - t_launch, 1), ok=ok, **({"said": said} if said else {}))

    def on_line(line):
        if pid[0] is None and '"event": "launched"' in line:
            with contextlib.suppress(ValueError):
                pid[0] = json.loads(line).get("pid")
        if not first.is_set() and '"app:mark"' in line and '"first frame"' in line:
            t_first[0] = time.monotonic()
            first.set()
    threads = [threading.Thread(target=runner, args=t, daemon=True) for t in timed]
    for t in threads:
        t.start()
    args = ["--play", a.title, "--until", f"first-frame+{a.secs}", "--quiet", "--wait", str(a.secs + 300), *ui_args, *anyb]
    args += ["--pad"] if any(n.startswith("pad:") for _, n, _ in timed) else []
    args += ["--settings", f"{a.title}:{a.settings}"] if a.settings else []
    follow = device_log(out, a.secs + 400) if settings.get("metalValidation") else None
    r = ui(os.path.join(out, "run"), *args, on_line=on_line)
    done.set()
    for t in threads:   # a hook still running (a capture, a trace) finishes before the result
        t.join(timeout=900)
    if follow:
        time.sleep(3)
        follow.terminate()
    ev("played", ok=r.get("ok"), why=r.get("why"), timeline=r.get("timeline"))
    return r


def cmd_capture(a):
    ev = phonelib.Events(a.out)
    a.secs = a.secs or int(a.frame / 50) + 20
    settings = {"gpuCaptureFrame": a.frame, "passProfile": "true" if a.pass_prof else "false",
                "metalValidation": "off"}
    with phonelib.device_lock("pp gpu capture", events=ev, expect_s=a.secs + 150):
        free = free_gb(phonelib.Phone(a.out, events=ev).ensure())
        why = space_refusal(free, a.expect_gb)
        ev("space", free_gb=free and round(free, 1), expect_gb=a.expect_gb, reserve_gb=RESERVE_GB, ok=not why)
        if why:
            return ev.result(False, 1, why=why, out=a.out)
        r = play(a, ev, a.out, settings)
        log = os.path.join(a.out, "run", "pull", "s1-host.log")
        if not os.path.exists(log):
            return ev.result(False, 1, why="the play pulled no s1-host.log", out=a.out)
        with open(log, errors="replace") as f:
            found = [m[1] for m in map(CAPTURE_RE.search, f) if m]
        extra = finish(a.out, log, None, a.pass_prof)
        if not found:
            return ev.result(False, 1, why=f"no capture in the log: did the play reach frame {a.frame}? "
                                          "(a longer --secs, or a smaller --frame)", out=a.out, **extra)
        phone = phonelib.Phone(a.out, events=ev).ensure()
        remote = "Documents/" + found[-1]
        local = phone.pull_bundle(remote, a.out)
        pulled = local_counts(local)
        try:
            said = phone.afc("rm-bundle", "rm-bundle", remote, *map(str, pulled), secs=900).strip()
            removed = True
        except phonelib.PhoneError as e:
            said, removed = str(e), False
        free = free_gb(phone)
        ev("bundle", remote=remote, files=pulled[0], bytes=pulled[1], links=pulled[2], removed=removed,
           said=said, free_gb=free and round(free, 1))
    import gputrace
    with open(os.path.join(a.out, "capture.txt"), "w") as f:
        f.write(gputrace.report(gputrace.summarize(local)))
    if not removed:
        return ev.result(False, 1, why=f"the bundle stayed on the phone: {said}", out=a.out, capture=local,
                         report=os.path.join(a.out, "capture.txt"), **extra)
    return ev.result(bool(r.get("ok")), 0, out=a.out, capture=local, report=os.path.join(a.out, "capture.txt"),
                     bundle_gb=round(pulled[1] / 1e9, 2), **extra)


NEVER_FRAME = 999999


def cmd_live(a):
    """A play with Metal's capture layer from launch; at --capture, gpucapture takes the frame
    (or the command buffers) from the running game into this Mac's run directory; at
    --trace, xctrace records the phone. Then pp gpu profile of the capture with --profile."""
    import apple
    why = apple.require()
    if why:
        return phonelib.fail(phonelib.Events(a.out), "pp gpu live: " + why)
    ev = phonelib.Events(a.out)
    log = os.path.join(a.out, "apple-tools.txt")
    hooks, made = [], {}
    with phonelib.device_lock("pp gpu live", events=ev, expect_s=a.secs + 300):
        device = None
        if a.capture:
            device, name = apple.ensure_agent(ev)

            def take(_pid):
                pid = None
                for _ in range(20):
                    pid = apple.capturable(device)
                    if pid:
                        break
                    time.sleep(3)
                if not pid:
                    raise phonelib.PhoneError("Playport is not capturable (gpucapture list): did it start with "
                                              "the capture layer?")
                rows = apple.boundaries(pid, device, log)
                b = apple.pick_boundary(rows, a.boundary)
                ev("boundary", pid=pid, **b, of=[(r["id"], r["type"], r["label"]) for r in rows])
                path = os.path.join(a.out, f"live-{b['type'].lower()}{b['id']}-x{a.count}.gputrace")
                t = time.monotonic()
                made["capture"] = apple.capture(pid, device, b["id"], a.count, path, log, unused=a.unused)
                return {"capture": path, "secs": round(time.monotonic() - t, 1)}
            hooks.append((when_of(a.capture), "capture", take))
        if a.trace:
            def trace(_pid):
                slug = re.sub(r"[^a-z0-9]+", "-", a.trace.lower()).strip("-")
                path = os.path.join(a.out, f"{slug}.trace")
                made["trace"] = apple.xctrace_record(a.trace, a.trace_secs, path, log)
                return {"trace": path}
            hooks.append((when_of(a.trace_at), "trace", trace))
        # Metal's capture layer refuses a device with a Metal 4 counter heap; KosmicKrisp makes
        # none while its own capture is armed (patches/mesa 0044), so arm it at a frame no play
        # reaches. DXMT then waits for that frame too.
        settings = {"gpuCaptureFrame": NEVER_FRAME, "passProfile": "false", "metalValidation": "off"} \
            if a.capture else {}
        r = play(a, ev, a.out, settings, hooks=hooks, ui_args=["--capture-layer"] if a.capture else [])
    extra = {}
    if a.trace and made.get("trace"):
        extra["trace_toc"] = trace_toc(made["trace"], a.out, log)
    if a.capture and made.get("capture") and a.profile:
        with phonelib.device_lock("pp gpu live: profile", events=ev, expect_s=1800):
            extra.update(profile(made["capture"], device, a.out, ev, a.gpu_state, execution=a.execution))
    missing = [k for k in ("capture", "trace") if getattr(a, k) and not made.get(k)]
    ok = bool(r.get("ok")) and not missing
    return ev.result(ok, 0 if ok else 1, out=a.out, **made, **extra,
                     **({"why": f"no {' or '.join(missing)} was made ({log})"} if missing else {}))


def trace_toc(path, out, log):
    """The trace's table of contents (xctrace export --toc), beside it."""
    toc = os.path.join(out, os.path.basename(path)[:-6] + "-toc.xml")
    import apple
    with open(toc, "w") as f:
        f.write(apple.run(["xcrun", "xctrace", "export", "--input", path, "--toc"], 600, check=False, log=None))
    return toc


def profile(trace, device, out, ev, gpu_state="default", wait=1800, execution="serial"):
    """gpudebug replays TRACE on the phone and profiles it, embedding the profile in the trace;
    then reads it back without the phone: profile.txt (the frame's encoders by GPU time, each
    with its counters' means: occupancy, ALU, limiters, bandwidth), profile.json and the raw
    series under profile/."""
    import apple
    log = os.path.join(out, "apple-tools.txt")
    t0 = time.monotonic()
    with apple.Session(trace, device, os.path.join(out, "fetched"), log) as s:
        st = {}
        while time.monotonic() - t0 < wait:
            st = s.status()
            if (st.get("replayer") or {}).get("state") not in ("loading", "preparing", None):
                break
            time.sleep(10)
        ev("replayer", session=s.id, status=st, after_s=round(time.monotonic() - t0))
        opts = (f" --gpu-state {gpu_state}" if gpu_state != "default" else "") \
            + f" --exec {execution}"
        said = apple.json_lines(s.cmd(f"profile run{opts} --embed", secs=wait))
        ev("profiled", said=said[-1:], after_s=round(time.monotonic() - t0))
    return read(trace, out, ev)


def read(trace, out, ev):
    """profile.txt and profile.json from TRACE's embedded profile (no phone)."""
    import apple
    log = os.path.join(out, "apple-tools.txt")
    encoders, series = apple.read_profile(trace, out, log)
    if not encoders:
        raise phonelib.PhoneError(f"{trace} has no embedded profile with an encoder timeline ({log})")
    text, rows = apple.profile_report(trace, encoders, series)
    with open(os.path.join(out, "profile.txt"), "w") as f:
        f.write(text)
    with open(os.path.join(out, "profile.json"), "w") as f:
        json.dump(rows, f, indent=1)
    ev("profile", encoders=len(rows), counters=len(series))
    return {"profile": os.path.join(out, "profile.txt"), "encoders": len(rows), "counters": len(series)}


def cmd_profile(argv):
    p = argparse.ArgumentParser(prog="pp gpu profile",
                                description="replay a .gputrace on the phone and profile it (a Mac: gpudebug)")
    p.add_argument("trace")
    p.add_argument("--gpu-state", default="default", choices=("default", "low", "medium", "high"))
    p.add_argument("--exec", dest="execution", default="serial", choices=("serial", "overlapping"),
                   help="replay the encoders one at a time (default: an overlapping replay of The Witcher 3's "
                        "frame left its 161-encoder command buffer untimed) or overlapping")
    p.add_argument("--read", action="store_true",
                   help="only read the profile already embedded in TRACE (no phone, no replay)")
    p.add_argument("--out", help="the run directory (default $PLAYPORT_BUILD/gpu-runs/<time>)")
    a = p.parse_args(argv)
    import apple
    a.out = phonelib.run_dir("gpu-runs", a.out)
    ev = phonelib.Events(a.out)
    why = apple.require()
    if why:
        return phonelib.fail(ev, "pp gpu profile: " + why)
    try:
        if a.read:
            return ev.result(True, 0, out=a.out, **read(os.path.abspath(a.trace), a.out, ev))
        with phonelib.device_lock("pp gpu profile", events=ev, expect_s=1800):
            device, _ = apple.ensure_agent(ev)
            extra = profile(os.path.abspath(a.trace), device, a.out, ev, a.gpu_state, execution=a.execution)
    except phonelib.PhoneError as e:
        return phonelib.fail(ev, str(e))
    return ev.result(True, 0, out=a.out, **extra)


def finish(out, log, validation, pass_prof):
    """validation.txt and passes.txt from the play's log; what was written."""
    extra = {}
    if validation:
        extra.update(validation_report(out, log, validation))
    if pass_prof:
        import passprof
        with open(log, errors="replace") as f:
            text = passprof.report(f.readlines())
        if text:
            with open(os.path.join(out, "passes.txt"), "w") as f:
                f.write(text)
            extra["passes"] = os.path.join(out, "passes.txt")
    return extra


def cmd_validate(a):
    ev = phonelib.Events(a.out)
    level = "stop" if a.stop else "shaders" if a.shaders else "api"
    settings = {"gpuCaptureFrame": 0, "passProfile": "false", "metalValidation": level}
    with phonelib.device_lock("pp gpu validate", events=ev, expect_s=a.secs + 150):
        r = play(a, ev, a.out, settings)
    log = os.path.join(a.out, "run", "pull", "s1-host.log")
    if not os.path.exists(log):
        return ev.result(False, 1, why="the play pulled no s1-host.log", out=a.out)
    extra = finish(a.out, log, level, False)
    ok = extra.get("armed") and (r.get("ok") or level == "stop")
    return ev.result(bool(ok), 0 if extra.get("armed") else 1, out=a.out, report=os.path.join(a.out, "validation.txt"),
                     **({} if extra.get("armed") else {"why": "the log does not show validation on (run/pull/s1-host.log)"}),
                     **extra)


def cmd_names(argv):
    import gputrace
    if argv == ["--fetch"]:
        st = json.loads(subprocess.run([sys.executable, os.path.join(HERE, "..", "pp"), "phone", "status"],
                                       capture_output=True, text=True).stdout or "{}")
        ph = st.get("phone") or {}
        if not ph:
            sys.exit("pp gpu names --fetch: the phone is not reachable (pp phone status)")
        dest = os.path.join(phonelib.BUILD, "cache", f"dsc-{ph.get('ProductType')}-{ph.get('ProductVersion')}")
        if not glob.glob(os.path.join(dest, "**", "dyld_shared_cache_*"), recursive=True):
            with phonelib.device_lock("pp gpu names --fetch", events=phonelib.Events()):
                rc = subprocess.call(["pymobiledevice3", "developer", "fetch-symbols", "download", dest],
                                     env=phonelib.pmd_env())
            if rc:
                sys.exit(f"pp gpu names --fetch: the download failed (exit {rc})")
        argv = [dest]
    if len(argv) != 1:
        sys.exit("pp gpu names --fetch | DSC_DIR")
    return gputrace.build_names(argv[0])


def common(p):
    p.add_argument("--title", default="app-367520", help="the catalogue title to Play (default: Hollow Knight)")
    p.add_argument("--secs", type=int, help="seconds after the first frame to keep playing")
    p.add_argument("--pad", action="append", default=[], metavar="[first-frame+]SECS:SCRIPT",
                   help="push SCRIPT (a tools/pad/ name or file) this long after launch or the first frame")
    p.add_argument("--out", help="the run directory (default $PLAYPORT_BUILD/gpu-runs/<time>)")
    p.add_argument("--any-build", action="store_true", help="drive whatever the phone has installed (pp ui)")
    p.add_argument("--settings", metavar="JSON",
                   help="the title's launch settings for this play, as pp ui --settings: "
                        "'{\"graphics\":\"vulkan\"}' captures KosmicKrisp's frame (patches/mesa 0017)")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    sub, rest = argv[0], argv[1:]
    if sub == "read":
        import gputrace
        return gputrace.main(rest)
    if sub == "passes":
        import passprof
        if len(rest) == 1 and os.path.isdir(rest[0]):
            logs = [os.path.join(rest[0], *p) for p in (("run", "pull", "s1-host.log"), ("pull", "s1-host.log"))]
            rest = [next((l for l in logs if os.path.exists(l)), logs[0])]
        return passprof.main(rest)
    if sub == "names":
        return cmd_names(rest)
    if sub == "profile":
        return cmd_profile(rest)
    if sub not in ("capture", "validate", "live"):
        print(f"pp gpu: no subcommand {sub} (pp gpu --help)", file=sys.stderr)
        return 2
    p = argparse.ArgumentParser(prog=f"pp gpu {sub}")
    common(p)
    if sub == "capture":
        p.add_argument("--frame", type=int, required=True, help="the frame to capture, counted from the game's first present")
        p.add_argument("--pass-prof", action="store_true", help="GPU time per pass during the same play")
        p.add_argument("--expect-gb", type=float, default=1.0,
                       help=f"the bundle's expected size: the phone must have this much free above {RESERVE_GB:g} GB")
    elif sub == "live":
        p.add_argument("--capture", metavar="[first-frame+]SECS", help="when gpucapture takes the capture")
        p.add_argument("--boundary", default="layer",
                       help="what one capture iteration is: layer (a present to the next: one frame; "
                            "default), queue (one command buffer of the busiest queue), device, or a "
                            "boundary id gpucapture boundaries lists")
        p.add_argument("--count", type=int, default=1, help="iterations of the boundary (default 1)")
        p.add_argument("--unused", action="store_true",
                       help="record every resource, not only those the frame uses (large; may end the game)")
        p.add_argument("--profile", action="store_true", help="then replay and profile it on the phone")
        p.add_argument("--gpu-state", default="default", choices=("default", "low", "medium", "high"),
                       help="the GPU performance state the profile holds (default: the tool's)")
        p.add_argument("--exec", dest="execution", default="serial", choices=("serial", "overlapping"),
                       help="the profile's replay: encoders one at a time (default) or overlapping")
        p.add_argument("--trace", metavar="TEMPLATE", help="an Instruments template to record (xctrace)")
        p.add_argument("--trace-at", default="first-frame+30", metavar="[first-frame+]SECS")
        p.add_argument("--trace-secs", type=int, default=20)
    else:
        p.add_argument("--shaders", action="store_true", help="shader validation too")
        p.add_argument("--stop", action="store_true",
                       help="end the process at the first API error; the crash report gives its message")
    a = p.parse_args(rest)
    if sub == "capture" and a.frame <= 0:
        p.error("--frame must be positive")
    if sub == "live":
        if not (a.capture or a.trace):
            p.error("--capture WHEN, --trace TEMPLATE or both")
        for w in (a.capture, a.trace_at if a.trace else None):
            if w and when_of(w) is None:
                p.error(f"{w!r}: want [first-frame+]SECS")
    a.secs = a.secs if a.secs is not None else (0 if sub == "capture" else 60)
    a.out = phonelib.run_dir("gpu-runs", a.out)
    try:
        return {"capture": cmd_capture, "validate": cmd_validate, "live": cmd_live}[sub](a)
    except phonelib.PhoneError as e:
        return phonelib.fail(phonelib.Events(a.out), str(e))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

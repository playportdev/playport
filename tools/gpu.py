#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""pp gpu: GPU debugging on the phone from this workstation (docs/GPU-DEBUGGING.md).

  pp gpu capture --frame N [--title ID] [--secs S] [--pad [first-frame+]SECS:SCRIPT ...]
                 [--pass-prof] [--out DIR]
      one frame of a play as a Metal .gputrace: sets Settings' Diagnostics (GPU capture
      at frame N, and the switches asked for) in one launch, plays in the next (Metal
      allows a capture only in a process that started with it), pulls the bundle into
      the run directory and writes capture.txt (pp gpu read), and passes.txt with
      --pass-prof. Not with validation: a capture with Metal validation on was never
      written (2026-09-29) --secs: seconds after the first frame to keep
      playing (default: N/50 + 20, about frame N at 60 FPS with room)
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

Every play goes through the app's UI (pp ui), under one hold of the device lock.
The Diagnostics switches last for that session and are undone at the app's next
launch outside it, as any driven setting is. A capture or validation run costs
every frame: its frame figures are not a measurement (pp perf is).
"""

import argparse
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


def play(a, ev, out, settings):
    """The settings launch, then the play, with pad scripts pushed at their times (as
    pp perf's --pad); the play's result."""
    import pad
    acts = []
    for k, v in settings.items():
        acts += ["--action", f"set:{k}={v}"]
    r = ui(os.path.join(out, "set"), *acts)
    if not r.get("ok"):
        raise phonelib.PhoneError(f"setting Diagnostics failed: {r.get('why') or r} ({out}/set)")
    ev("diagnostics", **settings)
    pads = []
    for v in a.pad:
        when, _, name = v.partition(":")
        if when_of(when) is None:
            raise phonelib.PhoneError(f"--pad {v}: want [first-frame+]SECS:SCRIPT")
        pads.append((when_of(when), name, pad.script(name)))
    phone = phonelib.Phone(out, events=ev)
    if pads:   # a script left from an earlier run would play from the launch
        pad.push(phone, pad.REST)
    t_launch, t_first, first = time.monotonic(), [None], threading.Event()
    done = threading.Event()

    def pusher(when, name, text):
        ff, secs = when
        if ff:
            while not first.wait(1):
                if done.is_set():
                    return
        base = t_first[0] if ff else t_launch
        if done.wait(max(0, base + secs - time.monotonic())):
            return
        try:
            pad.push(phone, text)
            ok = True
        except phonelib.PhoneError as e:
            ok = str(e)
        ev("pad", script=name, after_s=round(time.monotonic() - t_launch, 1), ok=ok)

    def on_line(line):
        if not first.is_set() and '"app:mark"' in line and '"first frame"' in line:
            t_first[0] = time.monotonic()
            first.set()
    for p in pads:
        threading.Thread(target=pusher, args=p, daemon=True).start()
    args = ["--play", a.title, "--until", f"first-frame+{a.secs}", "--quiet", "--wait", str(a.secs + 300)]
    args += ["--pad"] if pads else []
    follow = device_log(out, a.secs + 400) if settings.get("metalValidation") else None
    r = ui(os.path.join(out, "run"), *args, on_line=on_line)
    done.set()
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
        local = phone.pull_bundle("Documents/" + found[-1], a.out)
    import gputrace
    with open(os.path.join(a.out, "capture.txt"), "w") as f:
        f.write(gputrace.report(gputrace.summarize(local)))
    return ev.result(bool(r.get("ok")), 0, out=a.out, capture=local, report=os.path.join(a.out, "capture.txt"),
                     **extra)


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
    if sub not in ("capture", "validate"):
        print(f"pp gpu: no subcommand {sub} (pp gpu --help)", file=sys.stderr)
        return 2
    p = argparse.ArgumentParser(prog=f"pp gpu {sub}")
    common(p)
    if sub == "capture":
        p.add_argument("--frame", type=int, required=True, help="the frame to capture, counted from the game's first present")
        p.add_argument("--pass-prof", action="store_true", help="GPU time per pass during the same play")
    else:
        p.add_argument("--shaders", action="store_true", help="shader validation too")
        p.add_argument("--stop", action="store_true",
                       help="end the process at the first API error; the crash report gives its message")
    a = p.parse_args(rest)
    if sub == "capture" and a.frame <= 0:
        p.error("--frame must be positive")
    a.secs = a.secs if a.secs is not None else (0 if sub == "capture" else 60)
    a.out = phonelib.run_dir("gpu-runs", a.out)
    try:
        return cmd_capture(a) if sub == "capture" else cmd_validate(a)
    except phonelib.PhoneError as e:
        return phonelib.fail(phonelib.Events(a.out), str(e))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

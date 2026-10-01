# SPDX-License-Identifier: GPL-3.0-or-later
"""pp pad: drive a running title with the app's scripted pad.

  pp pad send STEP ... [--wait] [--shot FILE]   play these steps now ("150 A" "2000 -")
  pp pad push SCRIPT [--wait] [--shot FILE]     play a script: a file, or a name in tools/pad/ (hk-walk)
  pp pad rest                                   the pad at rest
  pp pad wait-still [--timeout S] [--threshold T] [--shot FILE]
                                                wait until the screen stops changing

The app plays a script only when it was launched with the pad (`pp ui --pad`,
`pp perf --pad`); app/HostIOKit/Sources/HostIOKit/VirtualPad.swift has the format.
It checks Documents/vpad.txt every 200 ms and starts a changed script from its
first step, so a push takes effect about 0.2 s after the write. Each step is
logged in s1-host.log (`vpad: step i/n (script k)`). --wait returns once the
script has played; --shot FILE waits too, then takes a screenshot: one call for
"press, then look". Takes the device lock like every device command.

A script's fixed waits race the title's loads. wait-still screenshots the
phone (about one every 5 s) until two in a row differ by less than T (the mean
absolute difference of their 64x36 greyscale thumbnails, 0-255; default 1.5),
then leaves the last one in FILE: push the next steps once a menu has settled.
A screen that animates (particles, a video) never settles: each `still-check`
event has the difference, to pick a T above its noise. It gives up after S
seconds (default 60) with ok false.
"""

import argparse
import os
import re
import time

import phonelib

REMOTE = "Documents/vpad.txt"
SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pad")
STEP_RE = re.compile(r"^\s*(\d+)")
REST = "0 -\n"


def length_ms(text):
    """The script's length (the app parses it; this only sums durations)."""
    return sum(int(m[1]) for m in (STEP_RE.match(ln.split("#")[0]) for ln in text.splitlines()) if m)


def script(name):
    """A script file's text; a bare name is looked up in tools/pad/."""
    for path in (name, os.path.join(SCRIPTS, name), os.path.join(SCRIPTS, name + ".txt")):
        if os.path.isfile(path):
            return open(path).read()
    raise phonelib.PhoneError(f"no pad script {name!r} (a file, or one of {sorted(os.listdir(SCRIPTS))})")


def push(phone, text):
    phone.put(REMOTE, text.encode())


THUMB = (64, 36)


def difference(a, b):
    """The mean absolute difference (0-255) of two images' greyscale thumbnails."""
    from PIL import Image, ImageChops, ImageStat
    with Image.open(a) as ia, Image.open(b) as ib:
        ta, tb = (im.convert("L").resize(THUMB) for im in (ia, ib))
    return round(ImageStat.Stat(ImageChops.difference(ta, tb)).mean[0], 2)


def wait_still(phone, ev, path, timeout=60, threshold=1.5, shoot=None):
    """Screenshots into PATH (and PATH.prev) until two in a row differ by less than
    THRESHOLD; True then, False after TIMEOUT seconds. shoot: a test's stand-in."""
    shoot = shoot or phone.screenshot
    prev, end = None, time.monotonic() + timeout
    while True:
        shot = shoot(path)
        if not shot:
            raise phonelib.PhoneError("wait-still: no screenshot")
        if prev:
            diff = difference(prev, shot)
            ev("still-check", difference=diff)
            if diff < threshold:
                return True
        if time.monotonic() >= end:
            return False
        prev = path + ".prev.png"
        os.replace(shot, prev)


def main(argv):
    p = argparse.ArgumentParser(prog="pp pad", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["send", "push", "rest", "wait-still"])
    p.add_argument("args", nargs="*")
    p.add_argument("--wait", action="store_true", help="return once the script has played")
    p.add_argument("--shot", metavar="FILE", help="once the script has played, a screenshot to FILE")
    p.add_argument("--timeout", type=float, default=60, help="wait-still: give up after this many seconds (60)")
    p.add_argument("--threshold", type=float, default=1.5, help="wait-still: still below this difference (1.5)")
    a = p.parse_args(argv)
    if (a.cmd == "push" and len(a.args) != 1) or (a.cmd == "send" and not a.args) or \
            (a.cmd in ("rest", "wait-still") and a.args):
        p.error("wrong arguments for " + a.cmd)
    ev = phonelib.Events()
    try:
        if a.cmd == "wait-still":
            out = phonelib.run_dir("phone")
            path = os.path.abspath(a.shot or os.path.join(out, "still.png"))
            with phonelib.device_lock("pp pad wait-still", events=ev):
                phone = phonelib.Phone(out, events=ev)
                t0 = time.monotonic()
                still = wait_still(phone, ev, path, a.timeout, a.threshold)
                return ev.result(still, 0 if still else 1, shot=path, waited_s=round(time.monotonic() - t0, 1),
                                 **({} if still else {"why": f"the screen kept changing for {a.timeout:g} s"}))
        text = {"send": lambda: "\n".join(a.args) + "\n", "push": lambda: script(a.args[0]), "rest": lambda: REST}[a.cmd]()
        with phonelib.device_lock("pp pad " + a.cmd, events=ev):
            phone = phonelib.Phone(phonelib.run_dir("phone"), events=ev)
            push(phone, text)
            ms = length_ms(text)
            if a.wait or a.shot:
                time.sleep(ms / 1000 + 0.3)
            shot = phone.screenshot(os.path.abspath(a.shot)) if a.shot else None
            return ev.result(True, 0, script_ms=ms, **({"shot": shot} if a.shot else {}))
    except phonelib.PhoneError as e:
        return phonelib.fail(ev, str(e))

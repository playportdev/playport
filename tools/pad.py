# SPDX-License-Identifier: GPL-3.0-or-later
"""pp pad: drive a running title with the app's scripted pad.

  pp pad send STEP ... [--wait] [--shot FILE]   play these steps now ("150 A" "2000 -")
  pp pad push SCRIPT [--wait] [--shot FILE]     play a script: a file, or a name in tools/pad/ (hk-walk)
  pp pad rest                                   the pad at rest
  pp pad wait-still [--timeout S] [--threshold T] [--shot FILE]
                                                wait until the screen stops changing
  pp pad wait-text TEXT ... [--need N] [--press STEP ...] [--timeout S] [--shot FILE]
                    [--crop L,T,R,B] [--highlight-above TEXT]
                                                wait until the screen shows TEXT (OCR)

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

wait-text screenshots the phone and reads it with tesseract (the image and its
inverse: light menu text on a dark game) until at least N of the TEXTs (all by
default) are on it, case and spacing aside, then leaves that screenshot in FILE.
--press STEP plays those pad steps after each check that found none of them (to
skip a title's intro with --press "150 B" --press "300 -"), and stops pressing for good once any
TEXT was seen, so a press never lands on the screen being waited for. Each
`text-check` event has what was found; a check whose screenshot failed presses
nothing and looks again. It gives up after S seconds (default 60)
with ok false; the caller then presses nothing.

--crop L,T,R,B reads only that part of the screen (fractions of its width and
height), enlarged three times and read as one block of text: a menu column
apart from the rest of the screen. --highlight-above TEXT also needs a light
bar just above TEXT's line in that part: the highlighted menu item. Tesseract
misreads or drops a highlighted item (Kingdom Come's Continue: dark text on a
light banner), so this is how a script sees that the item above is the one
highlighted before it presses A on it. --timeout 0 checks once.
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


def grey(path, crop=None):
    """The image in greys; CROP (left, top, right, bottom fractions): that part, enlarged three times."""
    from PIL import Image
    with Image.open(path) as im:
        g = im.convert("L")
    if crop:
        w, h = g.size
        box = (round(crop[0] * w), round(crop[1] * h), round(crop[2] * w), round(crop[3] * h))
        g = g.crop(box).resize(((box[2] - box[0]) * 3, (box[3] - box[1]) * 3))
    return g


def ocr(path, crop=None):
    """The text tesseract reads in the image and in its inverse (a game's light-on-dark menu),
    the two readings apart by a form feed. CROP (left, top, right, bottom fractions): only
    that part, enlarged three times and read as one block."""
    import shutil
    import subprocess
    from PIL import ImageOps
    if not shutil.which("tesseract"):
        raise phonelib.PhoneError("wait-text: no tesseract on this machine")
    plain, inverse = path + ".crop.png", path + ".inverse.png"
    g = grey(path, crop)
    if crop:
        g.save(plain)
    ImageOps.invert(g).save(inverse)
    args = ["--psm", "6"] if crop else []
    try:
        return "\n\f\n".join(subprocess.run(["tesseract", p, "-", *args], capture_output=True, text=True,
                                             timeout=60).stdout for p in ((plain if crop else path), inverse))
    finally:
        for p in (plain, inverse):
            if os.path.exists(p):
                os.remove(p)


def normal(text):
    return " ".join(text.lower().split())


def found_texts(read, texts):
    """The TEXTs that occur in the OCR output READ, case and spacing aside."""
    have = normal(read)
    return [t for t in texts if normal(t) in have]


def text_lines(g, path):
    """Tesseract's lines in the grey image G (saved to PATH), one block: (text, top, height) each."""
    import subprocess
    g.save(path)
    try:
        tsv = subprocess.run(["tesseract", path, "-", "--psm", "6", "tsv"], capture_output=True, text=True,
                             timeout=60).stdout
    finally:
        os.remove(path)
    lines = {}
    for row in tsv.splitlines()[1:]:
        f = row.split("\t")
        if len(f) == 12 and f[0] == "5" and f[11].strip():
            words = lines.setdefault((f[2], f[3], f[4]), [])
            words.append((f[11], int(f[7]), int(f[9])))
    return [(" ".join(w[0] for w in ws), min(w[1] for w in ws), max(w[2] for w in ws)) for ws in lines.values()]


def highlight_above(path, text, crop=None, light=200):
    """Whether the screenshot PATH (its CROP part) has a light bar just above the line with TEXT:
    in the band from 2.5 to 0.2 of that line's height above it, at least 40% of the rows have
    30% or more of their pixels at LIGHT or above. None when TEXT is not read."""
    from PIL import ImageOps
    g = grey(path, crop)
    want = normal(text)
    for img in (g, ImageOps.invert(g)):
        line = next((ln for ln in text_lines(img, path + ".lines.png") if want in normal(ln[0])), None)
        if line:
            break
    else:
        return None
    _, top, height = line
    w = g.size[0]
    rows = range(max(0, top - round(2.5 * height)), max(0, top - round(0.2 * height)))
    px = g.load()
    lit = sum(sum(px[x, y] >= light for x in range(w)) >= 0.3 * w for y in rows)
    return bool(rows) and lit >= 0.4 * len(rows)


def wait_text(phone, ev, path, texts, need=None, press=None, timeout=60, interval=2, shoot=None, read=None,
              sleep=time.sleep, crop=None, above=None, highlight=None):
    """Screenshots into PATH until at least NEED (all) of TEXTS are read on it (and, with ABOVE,
    a light bar above that text); True then, False after TIMEOUT seconds. PRESS (a pad script's
    text) is pushed after each check that found none of them, and never again once one was
    seen. CROP: ocr's. shoot/read/highlight/sleep: a test's stand-ins."""
    shoot, read = shoot or phone.screenshot, read or (lambda p: ocr(p, crop))
    highlight = highlight or (lambda p, t: highlight_above(p, t, crop))
    need = len(texts) if need is None else need
    end, pressing = time.monotonic() + timeout, bool(press)
    while True:
        shot = shoot(path)
        if not shot:   # another job's screenshot at the same moment, say: look again, press nothing
            ev("text-check", error="no screenshot")
        else:
            found = found_texts(read(shot), texts)
            lit = bool(highlight(shot, above)) if above else None
            ev("text-check", found=found, pressed=pressing and not found,
               **({} if above is None else {"highlight_above": lit}))
            if len(found) >= need and lit is not False:
                return True
            if found:
                pressing = False
        if time.monotonic() >= end:
            return False
        if shot and pressing:
            push(phone, press)
        sleep(interval)


def main(argv):
    p = argparse.ArgumentParser(prog="pp pad", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["send", "push", "rest", "wait-still", "wait-text"])
    p.add_argument("args", nargs="*")
    p.add_argument("--wait", action="store_true", help="return once the script has played")
    p.add_argument("--shot", metavar="FILE", help="once the script has played, a screenshot to FILE")
    p.add_argument("--timeout", type=float, default=60, help="wait-still: give up after this many seconds (60)")
    p.add_argument("--threshold", type=float, default=1.5, help="wait-still: still below this difference (1.5)")
    p.add_argument("--need", type=int, help="wait-text: how many of the TEXTs must be read (all)")
    p.add_argument("--press", action="append", metavar="STEP",
                   help="wait-text: pad steps to play after a check that read none of the TEXTs (\"150 B\")")
    p.add_argument("--crop", metavar="L,T,R,B", help="wait-text: read only this part of the screen (fractions)")
    p.add_argument("--highlight-above", metavar="TEXT", help="wait-text: also need a light bar just above TEXT's line")
    a = p.parse_args(argv)
    crop = None
    if a.crop:
        try:
            crop = tuple(float(x) for x in a.crop.split(","))
        except ValueError:
            crop = ()
        if len(crop) != 4 or not (0 <= crop[0] < crop[2] <= 1 and 0 <= crop[1] < crop[3] <= 1):
            p.error("--crop is L,T,R,B: fractions with L < R and T < B")
    if (a.cmd == "push" and len(a.args) != 1) or (a.cmd in ("send", "wait-text") and not a.args) or \
            (a.cmd in ("rest", "wait-still") and a.args):
        p.error("wrong arguments for " + a.cmd)
    if a.cmd == "wait-text" and a.need is not None and not 1 <= a.need <= len(a.args):
        p.error(f"--need must be 1 to {len(a.args)}")
    ev = phonelib.Events()
    try:
        if a.cmd == "wait-text":
            out = phonelib.run_dir("phone")
            path = os.path.abspath(a.shot or os.path.join(out, "text.png"))
            press = "\n".join(a.press) + "\n" if a.press else None
            with phonelib.device_lock("pp pad wait-text", events=ev):
                phone = phonelib.Phone(out, events=ev)
                t0 = time.monotonic()
                seen = wait_text(phone, ev, path, a.args, a.need, press, a.timeout, crop=crop, above=a.highlight_above)
                return ev.result(seen, 0 if seen else 1, shot=path, waited_s=round(time.monotonic() - t0, 1),
                                 **({} if seen else {"why": f"the text was not read in {a.timeout:g} s"}))
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

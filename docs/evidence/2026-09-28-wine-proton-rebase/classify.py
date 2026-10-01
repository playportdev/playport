#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Step 0 of the wine-on-proton plan: sort Valve's proton_11.0 commits into classes.

  classify.py WINE_REPO OUT.json

WINE_REPO is a Wine clone with the refs wine-11.0, wine-11.18 and
valve/proton_11.0. Prints the per-class counts; OUT.json has every commit
with its tags, lines, and the lines it changes in the files Madeira's
*_ios.c replacements override."""
import re, subprocess, sys, json, collections

W = sys.argv[1]
BASE, VALVE, OURS = "wine-11.0", "valve/proton_11.0", "wine-11.18"

def git(*a):
    return subprocess.run(["git", "-C", W, *a], capture_output=True, text=True, check=True).stdout

# Files Madeira's *_ios.c replacements (and stubs) take the place of.
REPLACED = {
    "dlls/ntdll/unix/loader.c", "dlls/ntdll/unix/process.c", "dlls/ntdll/unix/server.c",
    "dlls/ntdll/unix/env.c", "dlls/ntdll/unix/cdrom.c", "dlls/ntdll/unix/virtual.c",
    "dlls/ntdll/unix/signal_arm64.c", "dlls/ntdll/unix/thread.c",
    "dlls/win32u/class.c", "dlls/win32u/winstation.c", "dlls/win32u/sysparams.c",
    "dlls/win32u/defwnd.c", "dlls/win32u/driver.c", "dlls/win32u/message.c", "dlls/win32u/freetype.c",
    "server/request.c", "server/main.c", "server/mach.c", "server/unicode.c", "server/fd.c",
    "server/window.c", "server/mapping.c", "server/queue.c",
    "dlls/dwrite/freetype.c", "dlls/crypt32/unixlib.c",
}

# patch-ids of upstream 11.0..11.18
up_ids = {}
out = subprocess.run(f"git -C {W} log -p --no-merges {BASE}..{OURS} | git patch-id --stable",
                     shell=True, capture_output=True, text=True).stdout
for line in out.splitlines():
    pid, c = line.split()
    up_ids[pid] = c
up_subjects = {}
for line in git("log", "--no-merges", "--format=%H%x09%s", f"{BASE}..{OURS}").splitlines():
    h, s = line.split("\t", 1)
    up_subjects.setdefault(s, h)
up_all = set(git("rev-list", f"{BASE}..{OURS}").split())

v_ids = {}
out = subprocess.run(f"git -C {W} log -p --no-merges {BASE}..{VALVE} | git patch-id --stable",
                     shell=True, capture_output=True, text=True).stdout
for line in out.splitlines():
    pid, c = line.split()
    v_ids[c] = pid

commits = []
raw = git("log", "--reverse", "--no-merges", "--format=@@@%H%x09%s", "--numstat", f"{BASE}..{VALVE}")
cur = None
for line in raw.splitlines():
    if line.startswith("@@@"):
        h, s = line[3:].split("\t", 1)
        cur = {"h": h, "s": s, "files": []}
        commits.append(cur)
    elif line.strip():
        a, d, f = line.split("\t", 2)
        if "=>" in f:
            f = re.sub(r"\{(.*) => (.*)\}", r"\2", f).replace("//", "/")
            if " => " in f:
                f = f.split(" => ")[1]
        cur["files"].append((0 if a == "-" else int(a), 0 if d == "-" else int(d), f))

bodies = {}
for c in commits:
    bodies[c["h"]] = git("log", "-1", "--format=%B", c["h"])

ARM = re.compile(r"arm64|aarch64|\bfex\b|wow64|xtajit|\bsve\b|\bavx\b.*arm|\bBTCpu|cooperative suspend|TSO", re.I)
SYNC = re.compile(r"fsync|ntsync|esync|futex|inproc_sync|in-process sync", re.I)
UNUSED_DIRS = ("dlls/winex11.drv/", "dlls/winewayland.drv/", "dlls/winebus.sys/", "dlls/hidclass.sys/",
               "dlls/winepulse.drv/", "dlls/winealsa.drv/", "dlls/wineoss.drv/", "dlls/winegstreamer/media-converter/",
               "dlls/winexinput.sys/")
UNUSED_WORDS = re.compile(r"evdev|hidraw|winex11|winewayland|\bx11\b|wayland|\budev\b|\bsdl\b|steam deck|xrandr|vulkan.*x11", re.I)
GST = ("dlls/winegstreamer/",)

def cls(c):
    files = [f for _, _, f in c["files"]]
    body = bodies[c["h"]]
    tags = []
    pid = v_ids.get(c["h"])
    cp = re.findall(r"cherry picked from commit ([0-9a-f]{7,40})", body)
    if pid in up_ids or any(any(u.startswith(x) for u in up_all) for x in cp) or c["s"] in up_subjects:
        tags.append("upstream")
    if SYNC.search(c["s"]) or any(re.search(r"fsync|esync|ntsync", f) for f in files):
        tags.append("sync")
    if files and (all(f.startswith(UNUSED_DIRS) for f in files) or UNUSED_WORDS.search(c["s"])):
        tags.append("unused")
    if ARM.search(c["s"]) or ARM.search(body.split("\n", 1)[-1][:400]) or any("arm64" in f or "aarch64" in f for f in files):
        tags.append("arm64ec-fex")
    if any(f in REPLACED for f in files):
        tags.append("replaced")
    if any(f.startswith(GST) for f in files):
        tags.append("winegstreamer")
    unix = [f for f in files if "/unix/" in f or f.startswith("server/") or f.endswith(("unixlib.c",)) or "_unix" in f]
    if not tags:
        tags.append("pe" if not unix else "unix-other")
    return tags

res = []
for c in commits:
    t = cls(c)
    lines = sum(a + d for a, d, _ in c["files"])
    rl = sum(a + d for a, d, f in c["files"] if f in REPLACED)
    res.append({"h": c["h"][:11], "s": c["s"], "tags": t, "lines": lines, "replaced_lines": rl,
                "replaced_files": sorted({f for _, _, f in c["files"] if f in REPLACED}),
                "hack": c["s"].startswith("HACK") or "HACK" in c["s"].split(":")[0]})
json.dump(res, open(sys.argv[2], "w"), indent=1)

# Primary class, in the plan's order of precedence
ORDER = ["upstream", "sync", "unused", "arm64ec-fex", "replaced", "winegstreamer", "unix-other", "pe"]
prim = collections.Counter(); plines = collections.Counter()
for r in res:
    p = next(o for o in ORDER if o in r["tags"])
    r["primary"] = p
    prim[p] += 1; plines[p] += r["lines"]
json.dump(res, open(sys.argv[2], "w"), indent=1)
print("total", len(res))
for o in ORDER:
    print(f"{o:14} {prim[o]:5} commits {plines[o]:8} lines")
anyc = collections.Counter(t for r in res for t in r["tags"])
print("any-tag:", dict(anyc))

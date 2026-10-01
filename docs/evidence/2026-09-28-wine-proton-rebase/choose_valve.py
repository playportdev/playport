#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Option B: choose the Valve commits for patches/wine-valve from classify.py's output.

  choose_valve.py WINE_REPO CLASSES.json OUT

Prints the chosen commits (oldest first) to OUT and a per-reason count of
the rest to stdout; writes every commit's verdict to OUT.verdicts.tsv.
"""
import json, re, subprocess, sys, collections

W, CLASSES, OUT = sys.argv[1:4]
res = json.load(open(CLASSES))

def git(*a):
    return subprocess.run(["git", "-C", W, *a], capture_output=True, text=True, check=True).stdout

files = {}
for r in res:
    files[r["h"]] = [l for l in git("show", "--format=", "--name-only", r["h"]).splitlines() if l]

MEDIA_DIRS = ("dlls/winegstreamer/", "dlls/mf", "dlls/qasf/", "dlls/quartz/", "dlls/wmvcore/", "dlls/wmvdecod/",
              "dlls/msauddecmft/", "dlls/winedmo/", "dlls/strmbase/", "dlls/qcap/", "dlls/iyuv_32/", "dlls/evr/",
              "dlls/msmpeg2vdec/", "dlls/mp3dmod/", "dlls/rtworkq/", "dlls/qedit/", "dlls/devenum/", "dlls/dsound/",
              "dlls/msvproc/", "dlls/ir50_32/", "libs/ffmpeg/", "include/wine/winedmo", "dlls/mfmediaengine/",
              "dlls/mfsrcsnk/", "dlls/mfreadwrite/", "dlls/mfplat/", "dlls/mf/")
STEAM_DIRS = ("dlls/amd_ags_x64/", "dlls/atiadlxx/", "dlls/amdxc64/", "dlls/nvcuda/", "dlls/windows.media.speech/",
              "dlls/protontts/", "programs/belauncher/", "programs/tabtip/", "tools/", "programs/winemenubuilder/",
              "programs/getminidump/", "dlls/vrclient", "dlls/openxr", "programs/winebrowser/", "dlls/lsteamclient",
              "dlls/windows.perception.stub/", "dlls/icu/", "programs/dotnetfx35/", "dlls/audioses/",
              "dlls/nsiproxy.sys/", "dlls/opencl/", "dlls/winevulkan/", "include/wine/vulkan",
              "dlls/windows.ui/")
BUILD_FILES = re.compile(r"^(configure(\.ac)?|aclocal\.m4|include/config\.h\.in|autogen\.sh|Makefile\.in|"
                         r"tools/|dlls/ntdll/ntsyscalls\.h|dlls/win32u/win32syscalls\.h|dlls/wow64win/)")
UNUSED_DIRS = ("dlls/winex11.drv/", "dlls/winewayland.drv/", "dlls/winebus.sys/", "dlls/hidclass.sys/",
               "dlls/winepulse.drv/", "dlls/winealsa.drv/", "dlls/wineoss.drv/", "dlls/winexinput.sys/",
               "dlls/opengl32/", "dlls/wineandroid.drv/")
STEAM_WORDS = re.compile(r"steam|proton|gamescope|overlay|vrclient|openvr|openxr|\bVR_|\bEAC\b|easyanticheat|"
                         r"battleye|belauncher|\bEOS\b|\bgdb|flatpak|pressure-vessel|LD_PRELOAD|LD_LIBRARY_PATH|"
                         r"/run/host|\bDeck\b|protontts|tabtip|xalia|ftrace|gpuvis|fshack|\begl\b|framebuffer|"
                         r"\bFBO\b|opengl|\bwgl|nvapi|dxvk|amdgpu|\bNGX\b|piper|vosk|mutter|kwin|xwayland|"
                         r"\bx11\b|wayland|evdev|hidraw|udev|\bsdl\b|\bOSK\b|msedge|webview", re.I)
WOW64 = re.compile(r"wow64|\bWOW\b", re.I)
UNIX = re.compile(r"(/unix/|^server/|unixlib|_unix\.|/unix_|\.so\b|^dlls/win32u/|^dlls/winevulkan/)")

by_subject = {r["s"]: r for r in res}
reverts = {}
for r in res:
    m = re.match(r'Revert "(.*)"\.?$', r["s"])
    if m and m.group(1) in by_subject:
        reverts[by_subject[m.group(1)]["h"]] = r["h"]
reverted = set(reverts) | set(reverts.values())

verdict = {}
def reason(r):
    h, s, fs = r["h"], r["s"], files[r["h"]]
    t = r["tags"]
    if "upstream" in t: return "upstream: already in wine-11.18"
    if h in reverted: return "reverted: Valve reverted it (the pair is left out)"
    m = re.match(r"(fixup|amend)! (.*)", s)
    if m:
        tgt = by_subject.get(m.group(2))
        if tgt and verdict.get(tgt["h"], "take") != "take":
            return "fixup: its target is left out"
    if "sync" in t: return "sync: fsync/ntsync, Linux kernel only"
    if "replaced" in t: return "replaced: touches a file an *_ios.c replacement overrides"
    if any(f.startswith(MEDIA_DIRS) for f in fs) or "winegstreamer" in t:
        return "media: Media Foundation/GStreamer stack (Playport keeps its own video work)"
    if all(f.startswith(UNUSED_DIRS) for f in fs) or "unused" in t:
        return "unused: winex11/winewayland/winebus/hidraw/pulse/opengl32, not in the iOS build"
    if any(f.startswith(STEAM_DIRS) for f in fs) or STEAM_WORDS.search(s):
        return "proton: Steam client, Proton, Linux desktop, VR, GL/fshack, AMD/NVIDIA spoofing or winevulkan"
    if any(BUILD_FILES.match(f) for f in fs):
        return "build: configure, makedep, generated files or tools"
    if all("/tests/" in f for f in fs):
        return "tests: tests only"
    if all(f.startswith(("loader/wine.inf", "loader/Makefile")) for f in fs):
        return "inert: wine.inf only; the app never runs wine.inf"
    if any(f.startswith(("programs/wineboot/", "programs/services/")) for f in fs) and \
            all(f.startswith(("programs/wineboot/", "programs/services/", "loader/wine.inf")) for f in fs):
        return "inert: wineboot or services.exe; the app runs neither"
    if re.search(r"soundfont|sapi\.rgs|BE launcher|BEService", s):
        return "proton: Proton tag files, protontts or BattlEye launcher"
    if WOW64.search(s) and not re.search(r"arm64ec", s, re.I):
        return "wow64: 32-bit guests only (i386 is not built)"
    if any(UNIX.search(f) for f in fs):
        return "unix-side: unix code outside the replacements (not a PE-only game fix)"
    return "take"

for r in res:
    verdict[r["h"]] = reason(r)

# ARM64EC/FEX decisions taken by reading each commit (evidence record, step 0)
ARM_TAKE = {"469a9fea3d1"}
ARM_NOT = {
    "a98b4d5e8e7": "fex-names: renames xtajit64.dll to libarm64ecfex.dll; Playport ships FEX as xtajit64.dll",
    "0bea7fadfad": "fex-names: fixup of the rename",
    "626cd7ace63": "fex-avx: inert on iOS (FEX reports no AVX there, fex-port 0009) and changes the EC dispatcher frame",
    "579584c8cf7": "fex-avx: SVE xstate headers; Apple CPUs have no SVE",
    "b130f25d66f": "build: configure.ac",
    "8d813e09b87": "fex-tsc: wineboot is never run by the app",
    "1b8936d2834": "inert: services.exe passes FEX_* variables to services; the app runs no services.exe",
    "b24ecb4824a": "winecrt0: moved to libs/winecrt0 in 11.18, taken as a port below if needed",
}
for h in ARM_TAKE: verdict[h] = "take"
for h, why in ARM_NOT.items(): verdict[h] = why

MANUAL = {}
def manual(why, *hs):
    for h in hs: MANUAL[h] = why
manual("d3dx: upstream's own d3dx9/10/11 texture work (48 commits in 11.0..11.18) overlaps Valve's backport of it; most of its commits conflict",
       *[r["h"] for r in res if re.match(r"d3dx", r["s"])])
manual("inert: mshtml and jscript run only with Wine Gecko, which the app does not ship",
       *[r["h"] for r in res if re.match(r"(HACK: )?(mshtml|jscript|ieframe)", r["s"]) or r["h"] == "258d6527c40"])
manual("inert: mscoree runs only with Wine Mono, which the app does not ship",
       *[r["h"] for r in res if re.search(r"mscoree", r["s"]) and r["h"] != "469a9fea3d1"])
manual("unused: dinput's HID joystick mapping; the phone has no HID devices (winebus is not built)",
       "11eeff416bf", "637679801c8", "85ffc3a79a3")
manual("unused: setupapi's winebus device presence; winebus is not built", "764bff28f1b", "1c95e6c0b50", "13a018bc07b")
manual("inert: upstream has PackageFullNameFromId; the other two read the package repository wine.inf makes, and the app never runs wine.inf",
       "7b4037421ea", "c18ebc392d1", "8089c27dae7")
manual("gone: wine-11.18's bcrypt has no GnuTLS backend (SymCrypt on the PE side)", "fcf8e23d727", "4cf6d8b6f09", "49a26f3bd8e")
manual("madeira: Madeira's host-pad xinput (wine-port 0055) rewrote these functions", "64ca68c68d6", "db523be38ee")
manual("madeira: Madeira's TLS slot and JIT-pool TLS work (wine-port 0015/0042, wine-pe 0003) owns this allocation", "3dcea332471")
manual("tests: tests only", "9af748e9df5")
for h, why in MANUAL.items():
    if verdict[h] == "take": verdict[h] = why
take = [r for r in res if verdict[r["h"]] == "take"]
with open(OUT, "w") as f:
    for r in take:
        f.write(f"{r['h']} {r['s']}\n")
with open(OUT + ".verdicts.tsv", "w") as f:
    for r in res:
        f.write(f"{r['h']}\t{verdict[r['h']]}\t{r['s']}\n")
c = collections.Counter(v.split(":")[0] for v in verdict.values())
l = collections.Counter()
for r in res: l[verdict[r["h"]].split(":")[0]] += r["lines"]
for k, n in c.most_common():
    print(f"{k:12} {n:5} {l[k]:8}")

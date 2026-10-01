# SPDX-License-Identifier: GPL-3.0-or-later
"""The runtime's sampling profile ([wprof] lines, madeira-unix 0028 with
WINE_IOS_PROF=1), summed over its bursts and symbolised against the staged
PE DLLs, which keep their symbol tables (app/Sources/S1Probe/Runtime).

Each 3 s burst samples the busiest threads at about 1 kHz while they run and
prints percentage tables; a table here weights each burst by its sample count:

  class         x64-JIT (FEX-compiled guest code), PE-other (an ARM64EC or
                ARM64 DLL: d3d11, ntdll, FEX's own xtajit64 ...), Madeira-dylib
                (Wine's unix side, the in-process wineserver, winemetal's unix
                side), system-lib (libsystem, Metal ...)
  leaf          where the pc was: a DLL function, a dylib symbol, or for x64
                code the guest module+rva of the block (x64:<module>+<rva>)
  thread        which thread
  pe-inclusive  the first PE frame on the frame-pointer chain: the DLL
                function the time is spent under (a memcpy inside d3d11 counts
                for d3d11)
  unix-inclusive the first Madeira-dylib frame on the chain

  pp perf --profile DIR   (pp perf writes profile.txt itself for such a run)
"""

import functools
import os
import re
import subprocess
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phonelib  # noqa: E402

REPO = phonelib.REPO
RUNTIME = os.path.join(REPO, "app", "Sources", "S1Probe", "Runtime")
# a module's name in the guest's loader list -> its staged file
ALIAS = {"libarm64ecfex.dll": "xtajit64.dll"}
BURST_RE = re.compile(r"\[wprof\] ml1129 burst: (\d+) running samples")
TABLE_RE = re.compile(r"\[wprof\] ml1129 ([a-z0-9-]+)(?: \(cont\))?:(.*)")
ENTRY_RE = re.compile(r" (.+?)=([\d.]+)%(?= |$)")
PE_KEY_RE = re.compile(r"^(x64:)?([^`+ ]+\.(?:dll|exe|drv|sys))\+([0-9a-f]+)$", re.I)


def llvm(tool):
    """An llvm tool from the llvm-mingw that `pp setup` recorded."""
    try:
        for l in open(os.path.join(phonelib.BUILD, "inputs.local")):
            if l.startswith("LLVM_MINGW="):
                return os.path.join(l.split("=", 1)[1].strip(), "bin", tool)
    except OSError:
        pass
    return tool


def staged(module):
    name = ALIAS.get(module.lower(), module.lower())
    for arch in ("arm64ec-windows", "aarch64-windows"):
        d = os.path.join(RUNTIME, arch)
        try:
            for f in os.listdir(d):
                if f.lower() == name:
                    return os.path.join(d, f)
        except OSError:
            pass
    return None


@functools.lru_cache(maxsize=None)
def symbols(module):
    """(image base, sorted [(va, name)]) of a staged DLL; None without one."""
    path = staged(module)
    if not path:
        return None
    base = None
    hdr = subprocess.run([llvm("llvm-objdump"), "-p", path], capture_output=True, text=True).stdout
    m = re.search(r"^ImageBase\s+([0-9a-fA-F]+)", hdr, re.M)
    if m:
        base = int(m[1], 16)
    out = subprocess.run([llvm("llvm-nm"), "-n", "--demangle", "--defined-only", path],
                         capture_output=True, text=True).stdout
    syms = []
    for l in out.splitlines():
        p = l.split(None, 2)
        if len(p) == 3 and p[1] in "TtWw" and not p[2].endswith("$exit_thunk"):
            syms.append((int(p[0], 16), p[2]))
    return (base, syms) if base is not None and syms else None


def name(key):
    """A table key with a PE module+rva symbolised: module!function (+rva when
    the DLL has no symbols, e.g. the game's own executable)."""
    m = PE_KEY_RE.match(key)
    if not m:
        return key
    x64, mod, rva = m[1] or "", m[2], int(m[3], 16)
    s = symbols(mod)
    if not s:
        return key
    base, syms = s
    va = base + rva
    lo, hi = 0, len(syms)
    while lo < hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= va:
            lo = mid + 1
        else:
            hi = mid
    if not lo:
        return key
    return f"{x64}{mod}!{short(syms[lo - 1][1])}"


def short(sym, width=110):
    """A demangled C++ name without its template and parameter lists."""
    out, depth = [], 0
    for ch in sym:
        if ch in "<(":
            if depth == 0:
                out.append("<>" if ch == "<" else "()")
            depth += 1
        elif ch in ">)":
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    s = "".join(out).replace("void ", "", 1) if sym.startswith("void ") else "".join(out)
    return s if len(s) <= width else s[:width - 3] + "..."


def parse(lines):
    """{table: {key: samples}} and the total samples, over every burst."""
    tables, total, burst = defaultdict(lambda: defaultdict(float)), 0, 0
    for l in lines:
        m = BURST_RE.search(l)
        if m:
            burst = int(m[1])
            total += burst
            continue
        m = TABLE_RE.search(l)
        if m and m[1] != "burst" and burst:
            for k, pct in ENTRY_RE.findall(m[2]):
                tables[m[1]][k] += float(pct) * burst / 100
    return tables, total


def report(lines, top=40):
    tables, total = parse(lines)
    if not total:
        return None
    out = [f"{total} running samples; each row: % of all samples, then the key"]
    for t in ("class", "thread", "leaf", "pe-inclusive", "unix-inclusive", "d3d12-inclusive"):
        if t not in tables:
            continue
        merged = defaultdict(float)
        for k, n in tables[t].items():
            merged[name(k)] += n
        out.append(f"\n== {t}")
        for k, n in sorted(merged.items(), key=lambda kv: -kv[1])[:top]:
            out.append(f"{100 * n / total:6.1f}  {k}")
        if t == "leaf":
            mods = defaultdict(float)
            for k, n in merged.items():
                mm = re.match(r"^(x64:)?([^!`+]+)", k)
                mods[(mm[1] or "") + mm[2] if mm else k] += n
            out.append("\n== leaf by module")
            for k, n in sorted(mods.items(), key=lambda kv: -kv[1])[:top]:
                out.append(f"{100 * n / total:6.1f}  {k}")
    return "\n".join(out) + "\n"


def run_log(d):
    for p in (os.path.join(d, "this-launch.log"), os.path.join(d, "run", "pull", "s1-host.log"), d):
        if os.path.isfile(p):
            return p
    raise SystemExit(f"{d}: no this-launch.log or run/pull/s1-host.log")


def main(argv):
    import argparse
    p = argparse.ArgumentParser(prog="pp perf --profile", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("dir")
    p.add_argument("--top", type=int, default=40)
    a = p.parse_args(argv)
    text = report(open(run_log(a.dir), errors="replace").read().splitlines(), a.top)
    if not text:
        raise SystemExit(f"{a.dir}: no [wprof] burst (was CPU sampling on in Settings' Diagnostics: pp perf --cpu-prof?)")
    if os.path.isdir(a.dir):
        with open(os.path.join(a.dir, "profile.txt"), "w") as f:
            f.write(text)
    print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

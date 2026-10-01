#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check a Mach-O dylib built for iOS without running it (build/stages/mesa.sh).

    check-macho-imports.py --sdk SDK [--platform ios] [--minos 26.0]
                           [--exports SYM,SYM] DYLIB

- LC_BUILD_VERSION names PLATFORM and MINOS, and the file is arm64 only;
- every non-weak undefined symbol is exported, for arm64 on PLATFORM, by the
  SDK .tbd stub of a library the dylib links (following re-exports). Libraries
  linked through @rpath are not in the SDK and are reported, not resolved;
- each of EXPORTS is an exported symbol of the dylib;
- the file names neither the repository nor $HOME.

A driver linked with -undefined dynamic_lookup builds against any symbol; this
is what finds, on the workstation, the ones dyld would refuse on the phone.
Exit status 1 on any failure, with one line per problem.
"""
import argparse
import os
import re
import subprocess
import sys

PLATFORM_ID = {"macos": 1, "ios": 2}


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def tbd_path(sdk, install_name):
    base = os.path.join(sdk, install_name.lstrip("/"))
    for cand in (base + ".tbd", re.sub(r"\.dylib$", ".tbd", base)):
        if os.path.isfile(cand):
            return cand
    return None


def tbd_exports(sdk, path, platform, seen):
    """Symbols a .tbd exports for arm64 on PLATFORM, with its re-exported libraries'."""
    syms, reexports = set(), []
    text = open(path, encoding="utf-8", errors="replace").read()
    for block in re.finditer(r"- targets:\s*\[([^\]]*)\]\s*\n((?:[ \t]{4,}.*\n?)*)", text):
        targets = [t.strip() for t in block.group(1).split(",")]
        if not any(t in (f"arm64-{platform}", f"arm64e-{platform}") for t in targets):
            continue
        for kind, items in re.findall(
                r"(symbols|objc-classes|objc-eh-types|objc-ivars|weak-symbols|thread-local-symbols|libraries):\s*\[([^\]]*)\]",
                block.group(2), re.S):
            names = [x.strip().strip("'\"") for x in items.split(",") if x.strip()]
            if kind == "libraries":
                reexports += names
            elif kind == "objc-classes":
                for c in names:
                    syms |= {"_OBJC_CLASS_$_" + c, "_OBJC_METACLASS_$_" + c}
            elif kind == "objc-eh-types":
                syms |= {"_OBJC_EHTYPE_$_" + c for c in names}
            elif kind == "objc-ivars":
                syms |= {"_OBJC_IVAR_$_" + c for c in names}
            else:
                syms |= set(names)
    for lib in reexports:
        if lib not in seen:
            seen.add(lib)
            t = tbd_path(sdk, lib)
            if t:
                syms |= tbd_exports(sdk, t, platform, seen)
    return syms


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sdk", required=True)
    ap.add_argument("--platform", default="ios", choices=sorted(PLATFORM_ID))
    ap.add_argument("--minos")
    ap.add_argument("--exports", default="")
    ap.add_argument("dylib")
    a = ap.parse_args()
    bad = []

    archs = run("llvm-objdump", "--macho", "--archive-headers", "--universal-headers", a.dylib)
    heads = run("llvm-objdump", "--macho", "--private-headers", a.dylib)
    if "ARM64" not in heads or "fat_magic" in archs.lower():
        bad.append("not a thin arm64 Mach-O")
    bv = re.search(r"cmd LC_BUILD_VERSION.*?platform (\S+).*?minos (\S+)", heads, re.S)
    if not bv:
        bad.append("no LC_BUILD_VERSION")
    else:
        plat, minos = bv.group(1), bv.group(2)
        if plat not in (str(PLATFORM_ID[a.platform]), a.platform, a.platform.upper(), "IOS" if a.platform == "ios" else "MACOS"):
            bad.append(f"LC_BUILD_VERSION platform {plat}, want {a.platform}")
        if a.minos and minos != a.minos:
            bad.append(f"LC_BUILD_VERSION minos {minos}, want {a.minos}")

    libs = [l.strip().split(" (")[0] for l in run("llvm-objdump", "--macho", "--dylibs-used", a.dylib).splitlines()[1:]]
    self_id = libs.pop(0) if libs and libs[0].startswith("@rpath/") and os.path.basename(a.dylib) in libs[0] else None
    exported = set()
    for lib in libs:
        if lib.startswith("@"):
            bad.append(f"links {lib}, which is not in the SDK")
            continue
        t = tbd_path(a.sdk, lib)
        if not t:
            bad.append(f"links {lib}, which the SDK does not have")
            continue
        exported |= tbd_exports(a.sdk, t, a.platform, {lib})

    unresolved = []
    for line in run("llvm-nm", "-u", "-m", a.dylib).splitlines():
        toks = line.split()
        if "external" not in toks or "weak" in toks:
            continue
        name = toks[toks.index("external") + 1]
        if name not in exported:
            unresolved.append(name)
    bad += [f"imports {n}, which no linked library exports for {a.platform}" for n in unresolved]

    defined = set(run("llvm-nm", "-g", "--defined-only", "-j", a.dylib).split())
    for sym in filter(None, a.exports.split(",")):
        if "_" + sym not in defined:
            bad.append(f"does not export {sym}")

    blob = open(a.dylib, "rb").read()
    repo = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
    for p in {repo, os.path.expanduser("~")}:
        if p and p != "/" and p.encode() in blob:
            bad.append(f"names the path {p}")

    for b in bad:
        print(f"{a.dylib}: {b}", file=sys.stderr)
    if bad:
        return 1
    print(f"{os.path.basename(a.dylib)}: {a.platform} arm64, {len(libs)} libraries, "
          f"every import resolved{', exports ' + a.exports if a.exports else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

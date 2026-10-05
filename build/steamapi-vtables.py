#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that a MinGW build lays out every Steam interface's vtable as MSVC does.

Games are built with MSVC, and the emulator's MinGW build implements their
interfaces (and calls their callback objects) through the same vtables. MSVC
groups overloaded virtuals and reverses them, and gives a virtual destructor
one slot; gbe 0004 and 0005 declare those in MSVC's order for a MinGW build.
This compiles a probe of every interface class in the SDK for each
architecture with the MinGW and the MSVC ABI and compares the method order.

    build/steamapi-vtables.py CLANGXX SDK_DIR SCRATCH_DIR
"""
import re
import subprocess
import sys
from pathlib import Path

TARGETS = (("x86_64-w64-mingw32", "x86_64-pc-windows-msvc"),
           ("i686-w64-mingw32", "i686-pc-windows-msvc"))
# Freestanding stand-ins for the C library the SDK headers include.
STUB = """typedef __SIZE_TYPE__ size_t;
#define NULL 0
#ifdef __cplusplus
extern "C" {
#endif
void *memset(void *, int, size_t); void *memcpy(void *, const void *, size_t);
int memcmp(const void *, const void *, size_t); char *strncpy(char *, const char *, size_t);
int snprintf(char *, size_t, const char *, ...); size_t strlen(const char *);
int strcmp(const char *, const char *);
#ifdef __cplusplus
}
#endif
"""


def interface_classes(sdk):
    classes = set()
    for header in sorted((sdk / "steam").glob("*.h")):
        text = header.read_text(encoding="latin-1")
        for m in re.finditer(r"^\s*class\s+(\w+)\s*(?::[^{;]*)?\{", text, re.M):
            if "virtual" in text[m.end():].split("};")[0]:
                classes.add(m.group(1))
    return sorted(classes)


def compile_probes(clang, sdk, scratch, probes, target, dump):
    source = scratch / "probes.cpp"
    source.write_text('#include "steam/steam_api.h"\n#include "steam/steam_gameserver.h"\n' +
                      "".join(probes.values()))
    return subprocess.run([clang, "-target", target, "-ffreestanding", "-nostdlibinc",
                           "-I", str(scratch / "stub"), "-I", str(sdk), "-S", "-o", "/dev/null",
                           "-w", "-ferror-limit=0"] + (["-Xclang", "-fdump-vtable-layouts"] if dump else []) +
                          [str(source)], capture_output=True, text=True)


def layouts(output, header, probes):
    """Each probed class's own vtable: method signatures in slot order."""
    result, current = {}, None
    for line in output.splitlines():
        m = re.match(header + r" for '(\w+)' \(", line)
        if m:
            current = m.group(1) if m.group(1) in probes and m.group(1) not in result else None
            if current:
                result[current] = []
            continue
        entry = re.match(r"\s+\d+ \| (.*)", line)
        if entry and current:
            if "RTTI" in line or "offset_to_top" in line:
                continue
            sig = entry.group(1).replace(" [pure]", "")
            # gbe 0003's MinGW struct returns: CSteamID &F(CSteamID &, ...) is MSVC's CSteamID F(...)
            sig = re.sub(r"^(\w+) &(\S+)\(\1 &(?:, )?", r"\1 \2(", sig)
            # the one-slot destructor stand-in
            sig = re.sub(r"^void (\w+)::MSVCDestructorSlot\(unsigned int\)$", r"\1::~\1() [vector deleting]", sig)
            result[current].append(sig)
        elif not line.startswith(" "):
            current = None
    return result


def main():
    clang, sdk, scratch = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    (scratch / "stub").mkdir(parents=True, exist_ok=True)
    for name in ("string.h", "stdio.h", "stdlib.h"):
        (scratch / "stub" / name).write_text(STUB)
    probes = {c: f"struct P_{c} : {c} {{ P_{c}(); }}; P_{c}::P_{c}() {{}}\n" for c in interface_classes(sdk)}
    # Drop the classes the public headers do not declare (or declare for another platform).
    while True:
        out = compile_probes(clang, sdk, scratch, probes, TARGETS[0][0], False)
        lines = {int(n) for n in re.findall(r"^\S*probes\.cpp:(\d+):\d+: error", out.stderr, re.M)}
        if not lines:
            if out.returncode:
                sys.exit(out.stderr[:4000])
            break
        names = list(probes)
        for n in lines:
            if 3 <= n < 3 + len(names):
                probes.pop(names[n - 3], None)
    bad = 0
    for mingw, msvc in TARGETS:
        gnu = compile_probes(clang, sdk, scratch, probes, mingw, True)
        ms = compile_probes(clang, sdk, scratch, probes, msvc, True)
        if gnu.returncode or ms.returncode:
            sys.exit((gnu.stderr + ms.stderr)[:4000])
        gnu, ms = layouts(gnu.stdout, "Vtable", probes), layouts(ms.stdout, "VFTable", probes)
        for c in probes:
            if c not in gnu or c not in ms or gnu[c] != ms[c]:
                bad += 1
                print(f"steamapi vtables: {c} differs from MSVC's layout on {mingw}", file=sys.stderr)
    if bad:
        sys.exit(1)
    print(f"steamapi vtables: {len(probes)} interfaces match MSVC's layout on {len(TARGETS)} architectures")


if __name__ == "__main__":
    main()

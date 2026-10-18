#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the slot table of Playport's steamclient64.dll shim (decision 0115).

A game's genuine steam_api calls the client's interfaces through MSVC's x64 vtables. This
compiles a probe of each interface version the shim serves from the public Steamworks SDK
headers pinned as gbe's `sdk/` (the bridge plan's D3), dumps clang's MSVC layout, and writes a C
header of slot numbers, method names and which methods return a class through MSVC's hidden
return pointer. Only that generated header is committed, not Valve's headers.

    build/steamclient-vtables.py CLANG SDK_DIR SCRATCH_DIR OUT_HEADER [--check]

--check compares with OUT_HEADER instead of writing it (the build stage's check that the
committed table is the pinned headers').
"""
import re
import subprocess
import sys
from pathlib import Path

TARGET = "x86_64-pc-windows-msvc"
# (C prefix, class names): every version the shim answers for.
INTERFACES = (
    [f"ISteamClient{v:03d}" for v in range(17, 23)] + ["ISteamClient"] +
    [f"ISteamUser{v:03d}" for v in range(17, 23)] + ["ISteamUser"] +
    [f"ISteamUtils{v:03d}" for v in range(7, 11)] + ["ISteamUtils"] +
    [f"ISteamApps{v:03d}" for v in range(7, 9)] + ["ISteamApps"] +
    [f"ISteamFriends{v:03d}" for v in range(15, 18)]
)
# The version string each unversioned class (the newest) answers to, from its header.
NEWEST = {"ISteamClient": ("isteamclient.h", "STEAMCLIENT_INTERFACE_VERSION"),
          "ISteamUser": ("isteamuser.h", "STEAMUSER_INTERFACE_VERSION"),
          "ISteamUtils": ("isteamutils.h", "STEAMUTILS_INTERFACE_VERSION"),
          "ISteamApps": ("isteamapps.h", "STEAMAPPS_INTERFACE_VERSION")}
# The version string of a numbered class.
VERSION = {"ISteamClient": "SteamClient{}", "ISteamUser": "SteamUser{}", "ISteamUtils": "SteamUtils{}",
           "ISteamApps": "STEAMAPPS_INTERFACE_VERSION{}", "ISteamFriends": "SteamFriends{}"}
STUB = """typedef __SIZE_TYPE__ size_t;
#define NULL 0
extern "C" {
void *memset(void *, int, size_t); void *memcpy(void *, const void *, size_t);
int memcmp(const void *, const void *, size_t); char *strncpy(char *, const char *, size_t);
int snprintf(char *, size_t, const char *, ...); size_t strlen(const char *);
int strcmp(const char *, const char *);
}
"""


def run(clang, sdk, scratch, source, extra):
    path = scratch / "probe.cpp"
    path.write_text('#include "steam/steam_api.h"\n' + source)
    out = subprocess.run([clang, "-target", TARGET, "-ffreestanding", "-nostdlibinc", "-I", str(scratch / "stub"),
                          "-I", str(sdk), "-w", "-S", "-o", "-"] + extra + [str(path)], capture_output=True, text=True)
    if out.returncode:
        sys.exit(out.stderr[:4000])
    return out.stdout


def layouts(clang, sdk, scratch):
    probes = "".join(f"struct P_{c} : {c} {{ P_{c}(); }}; P_{c}::P_{c}() {{}}\n" for c in INTERFACES)
    out = run(clang, sdk, scratch, probes, ["-Xclang", "-fdump-vtable-layouts", "-emit-llvm"])
    result, base, current = {}, {}, None
    for line in out.splitlines():
        m = re.match(r"VFTable for '(\w+)' \(", line)
        if m:
            current = m.group(1) if m.group(1) in INTERFACES and m.group(1) not in result else None
            if current:
                result[current] = []
            continue
        entry = re.match(r"\s+(\d+) \| (.*)", line)
        if entry and current:
            if "RTTI" in line:
                continue
            sig = entry.group(2).replace(" [pure]", "")
            # MSVC's dump numbers the RTTI entry 0 when the class has one: slots count after it.
            base.setdefault(current, int(entry.group(1)))
            assert int(entry.group(1)) == base[current] + len(result[current]), (current, line)
            result[current].append(sig)
        elif not line.startswith(" "):
            current = None
    missing = [c for c in INTERFACES if c not in result]
    if missing:
        sys.exit(f"steamclient vtables: no layout for {missing}")
    return result


def split(sig, cls):
    """(return type, method name) of a dumped signature."""
    m = re.match(r"(.*?)\s*\b" + cls + r"::(~?\w+)\(", sig)
    if not m:
        sys.exit(f"steamclient vtables: cannot read {sig!r}")
    return m.group(1).strip(), m.group(2)


def class_returns(clang, sdk, scratch, types):
    """Which return types MSVC returns from a member function through a hidden pointer: every class,
    struct or union (x64: member functions never return a user-defined type in RAX)."""
    types = sorted(types)
    source = "".join(f"char probe_{i}[(__is_class({t}) || __is_union({t})) ? 2 : 1];\n" for i, t in enumerate(types))
    ir = run(clang, sdk, scratch, source, ["-emit-llvm"])
    sizes = {int(i): int(n) for i, n in re.findall(r"@\"?\??probe_(\d+)\S*\"? = .*\[(\d) x i8\]", ir)}
    if len(sizes) != len(types):
        sys.exit(f"steamclient vtables: classified {len(sizes)} of {len(types)} return types")
    return {t for i, t in enumerate(types) if sizes[i] == 2}


def version_of(sdk, cls):
    base = re.sub(r"\d+$", "", cls)
    if cls in NEWEST:
        header, macro = NEWEST[cls]
        text = (sdk / "steam" / header).read_text(encoding="latin-1")
        return re.search(r"#define\s+" + macro + r"\s+\"([^\"]+)\"", text).group(1)
    return VERSION[base].format(cls[len(base):])


def generate(clang, sdk, scratch):
    lay = layouts(clang, sdk, scratch)
    rets = set()
    for c, sigs in lay.items():
        for s in sigs:
            r, _ = split(s, c)
            if r and r != "void" and not r.endswith("*") and not r.endswith("&"):
                rets.add(r.replace("const ", ""))
    hidden = class_returns(clang, sdk, scratch, rets)
    out = ["/* SPDX-License-Identifier: GPL-3.0-or-later */",
           "/* Generated by build/steamclient-vtables.py from the public Steamworks SDK headers pinned",
           " * as gbe's sdk/ (decision 0115, D3): each interface version's MSVC x64 slot order. Do not edit. */",
           "", "#ifndef STEAMCLIENT_SLOTS_H", "#define STEAMCLIENT_SLOTS_H", ""]
    table = []
    for c in INTERFACES:
        sigs = lay[c]
        name = c if c not in NEWEST else c + version_of(sdk, c)[-3:]
        names, seen = [], {}
        for i, s in enumerate(sigs):
            r, m = split(s, c)
            seen[m] = seen.get(m, 0) + 1
            names.append((m if seen[m] == 1 else f"{m}_{seen[m]}", r.replace("const ", "") in hidden))
        out.append(f"/* {c}: \"{version_of(sdk, c)}\" */")
        out.append(f"#define PP_SLOTS_{name} {len(sigs)}")
        for i, (m, _) in enumerate(names):
            out.append(f"#define PP_SLOT_{name}_{m} {i}")
        out.append(f"static const char *const pp_names_{name}[{len(sigs)}] = {{")
        out += [f"    \"{m}\"," for m, _ in names]
        out.append("};")
        flags = "".join("1" if h else "0" for _, h in names)
        out.append(f"/* 1: returns a class through MSVC's hidden pointer (after this). */")
        out.append(f"static const char pp_hidden_{name}[] = \"{flags}\";")
        out.append("")
        table.append((version_of(sdk, c), name))
    out.append("#define PP_SLOT_INTERFACES(X) \\")
    out += [f"    X({n}, \"{v}\") \\" for v, n in table]
    out[-1] = out[-1][:-2]
    out += ["", "#endif /* STEAMCLIENT_SLOTS_H */", ""]
    return "\n".join(out)


def main():
    clang, sdk, scratch, header = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
    check = "--check" in sys.argv[5:]
    (scratch / "stub").mkdir(parents=True, exist_ok=True)
    for name in ("string.h", "stdio.h", "stdlib.h"):
        (scratch / "stub" / name).write_text(STUB)
    text = generate(clang, sdk, scratch)
    if check:
        if not header.exists() or header.read_text() != text:
            (scratch / header.name).write_text(text)
            sys.exit(f"steamclient vtables: {header} is not the pinned SDK's; regenerated: {scratch / header.name}")
        print(f"steamclient vtables: {header.name} matches the pinned SDK ({len(INTERFACES)} interfaces)")
    else:
        header.write_text(text)
        print(f"steamclient vtables: wrote {header} ({len(INTERFACES)} interfaces)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the slot table of Playport's Steam client (steamclient64.dll and steamclient.dll,
decision 0115).

A game's genuine steam_api calls the client's interfaces through MSVC vtables. This compiles a
probe of every interface version a Steam client answers for from the public Steamworks SDK
headers pinned as gbe's `sdk/` (the bridge plan's D3), dumps clang's MSVC layout, and writes a C
header of each version's slots: method names, which return a class through MSVC's hidden return
pointer, and for i386 how many 4-byte stack words each method's arguments take (a thiscall
callee pops them, so a slot must know) and which return a float on the x87 stack. Which
version string names which class comes from the same pinned tree's getters (gbe's
`dll/steam_client_interface_getter.cpp` and `dll/dll.cpp`). Only that generated header is
committed, not Valve's headers.

    build/steamclient-vtables.py CLANG SDK_DIR SCRATCH_DIR OUT_HEADER [--check]

--check compares with OUT_HEADER instead of writing it (the build stage's check that the
committed table is the pinned headers').
"""
import re
import subprocess
import sys
from pathlib import Path

X64 = "x86_64-pc-windows-msvc"
I386 = "i686-pc-windows-msvc"
# The getters that name a class per version string, relative to the SDK's parent (gbe's tree).
GETTERS = ("dll/steam_client_interface_getter.cpp", "dll/dll.cpp")
STUB = """typedef __SIZE_TYPE__ size_t;
#define NULL 0
extern "C" {
void *memset(void *, int, size_t); void *memcpy(void *, const void *, size_t);
int memcmp(const void *, const void *, size_t); char *strncpy(char *, const char *, size_t);
int snprintf(char *, size_t, const char *, ...); size_t strlen(const char *);
int strcmp(const char *, const char *);
}
"""


def run(clang, sdk, scratch, source, target, extra):
    path = scratch / "probe.cpp"
    path.write_text('#include "steam/steam_api.h"\n' + source)
    out = subprocess.run([clang, "-target", target, "-ffreestanding", "-nostdlibinc", "-I", str(scratch / "stub"),
                          "-I", str(sdk), "-w", "-S", "-o", "-"] + extra + [str(path)], capture_output=True, text=True)
    if out.returncode:
        sys.exit(out.stderr[:4000])
    return out.stdout


def versions(sdk):
    """{version string: class} from gbe's getters: each `strcmp(v, "X") == 0` (or a version
    macro) and the one class its branch returns. A branch that returns none (Steam's client
    answers NULL) or picks between an `_old` and a current class (SteamUser002/004, by the
    client version) takes the current one."""
    text = "".join((sdk.parent / g).read_text(encoding="latin-1") for g in GETTERS)
    macros = {}
    for h in (sdk / "steam").glob("*.h"):
        for name, value in re.findall(r'#define\s+(\w+_INTERFACE_VERSION\w*)\s+"([^"]+)"', h.read_text(encoding="latin-1")):
            macros.setdefault(name, value)
    result = {}
    for chunk in re.split(r"strcmp\(\s*\w+\s*,\s*", text)[1:]:
        m = re.match(r'(?:"([^"]+)"|(\w+))\s*\)\s*==\s*0', chunk)
        if not m:
            continue
        version = m.group(1) or macros.get(m.group(2))
        if not version:
            sys.exit(f"steamclient vtables: no version string for {m.group(2)}")
        branch = re.split(r"strcmp\(|report_missing_impl", chunk)[0]
        classes = {c for c in re.findall(r"static_cast<\s*(ISteam\w+)\s*\*\s*>", branch) if not c.endswith("_old")}
        if len(classes) > 1:
            sys.exit(f"steamclient vtables: {version} names {sorted(classes)}")
        if classes and version not in result:
            result[version] = classes.pop()
    return result


def layouts(clang, sdk, scratch, classes, target):
    # steam_api.h includes most interfaces; a few (ISteamAppTicket) only their own header.
    probes = "".join(f'#include "steam/{c.lower()}.h"\n' for c in classes if (sdk / "steam" / f"{c.lower()}.h").exists())
    probes += "".join(f"struct P_{c} : {c} {{ P_{c}(); }}; P_{c}::P_{c}() {{}}\n" for c in classes)
    out = run(clang, sdk, scratch, probes, target, ["-Xclang", "-fdump-vtable-layouts", "-emit-llvm"])
    result, base, current = {}, {}, None
    for line in out.splitlines():
        m = re.match(r"VFTable for '(\w+)' \(", line)
        if m:
            current = m.group(1) if m.group(1) in classes and m.group(1) not in result else None
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
    missing = [c for c in classes if c not in result]
    if missing:
        sys.exit(f"steamclient vtables: no {target} layout for {missing}")
    return result


def split(sig, cls):
    """(return type, method name, parameter list text) of a dumped signature."""
    m = re.match(r"(.*?)\s*\b" + cls + r"::(~?\w+)\(", sig)
    if not m:
        sys.exit(f"steamclient vtables: cannot read {sig!r}")
    rest, depth = sig[m.end():], 1
    for i, ch in enumerate(rest):
        depth += {"(": 1, ")": -1}.get(ch, 0)
        if depth == 0:
            return m.group(1).strip(), m.group(2), rest[:i].strip()
    sys.exit(f"steamclient vtables: unbalanced {sig!r}")


def class_returns(clang, sdk, scratch, types):
    """Which return types MSVC returns from a member function through a hidden pointer: every class,
    struct or union (x64 and i386 alike: member functions never return a user-defined type in
    registers)."""
    types = sorted(types)
    source = "".join(f"char probe_{i}[(__is_class({t}) || __is_union({t})) ? 2 : 1];\n" for i, t in enumerate(types))
    ir = run(clang, sdk, scratch, source, X64, ["-emit-llvm"])
    sizes = {int(i): int(n) for i, n in re.findall(r"@\"?\??probe_(\d+)\S*\"? = .*\[(\d) x i8\]", ir)}
    if len(sizes) != len(types):
        sys.exit(f"steamclient vtables: classified {len(sizes)} of {len(types)} return types")
    return {t for i, t in enumerate(types) if sizes[i] == 2}


def stack_words(clang, sdk, scratch, params):
    """How many bytes each parameter list takes on MSVC i386's stack, as clang decorates an
    `extern "C" __stdcall` function with them (`_f@N`): the same push rules thiscall uses
    after `this`."""
    params = sorted(params)
    source = "".join(f'extern "C" void __stdcall pp_w{i}({p}); void *pp_r{i} = (void *)pp_w{i};\n'
                     for i, p in enumerate(params))
    asm = run(clang, sdk, scratch, source, I386, [])
    got = {int(i): int(n) for i, n in re.findall(r"_pp_w(\d+)@(\d+)", asm)}
    if len(got) != len(params):
        sys.exit(f"steamclient vtables: sized {len(got)} of {len(params)} parameter lists")
    return {p: got[i] for i, p in enumerate(params)}


def generate(clang, sdk, scratch):
    names = versions(sdk)
    classes = sorted(set(names.values()))
    lay = layouts(clang, sdk, scratch, classes, X64)
    lay32 = layouts(clang, sdk, scratch, classes, I386)
    rets, params = set(), set()
    parsed = {}
    for c in classes:
        if [split(s, c)[1] for s in lay[c]] != [split(s, c)[1] for s in lay32[c]]:
            sys.exit(f"steamclient vtables: {c}'s i386 slots are not its x64 slots")
        parsed[c] = [split(s, c) for s in lay[c]]
        for r, _, p in parsed[c]:
            params.add("" if p == "void" else p)
            if r and r != "void" and not r.endswith("*") and not r.endswith("&"):
                rets.add(r.replace("const ", ""))
    hidden = class_returns(clang, sdk, scratch, rets)
    sized = stack_words(clang, sdk, scratch, params)
    out = ["/* SPDX-License-Identifier: GPL-3.0-or-later */",
           "/* Generated by build/steamclient-vtables.py from the public Steamworks SDK headers pinned",
           " * as gbe's sdk/ and its getters' version strings (decision 0115, D3): each interface",
           " * version's MSVC slot order (the same for x86-64 and i386). Do not edit. */",
           "", "#ifndef STEAMCLIENT_SLOTS_H", "#define STEAMCLIENT_SLOTS_H", ""]
    most = 0
    for c in classes:
        sigs = parsed[c]
        most = max(most, len(sigs))
        method_names, seen = [], {}
        for r, m, _ in sigs:
            seen[m] = seen.get(m, 0) + 1
            method_names.append(m if seen[m] == 1 else f"{m}_{seen[m]}")
        flags = "".join("1" if r.replace("const ", "") in hidden else "0" for r, _, _ in sigs)
        words = []
        for (r, m, p), h in zip(sigs, flags):
            n = sized["" if p == "void" else p]
            assert n % 4 == 0, (c, p, n)
            # A virtual destructor's slot is MSVC's deleting destructor: it takes its flags.
            words.append(n // 4 + (h == "1") + m.startswith("~"))
        floats = "".join("1" if r in ("float", "double") else "0" for r, _, _ in sigs)
        out.append(f"/* {c} */")
        out.append(f"#define PP_SLOTS_{c} {len(sigs)}")
        out.append(f"static const char *const pp_names_{c}[{len(sigs)}] = {{")
        out += [f"    \"{m}\"," for m in method_names]
        out.append("};")
        out.append("/* 1: returns a class through MSVC's hidden pointer (after this). */")
        out.append(f"static const char pp_hidden_{c}[] = \"{flags}\";")
        out.append("/* i386: the 4-byte stack words of the arguments after this (the hidden pointer's included). */")
        out.append(f"static const unsigned char pp_words_{c}[{len(sigs)}] = {{ {', '.join(map(str, words))} }};")
        out.append("/* i386: 1 returns a float or double (in st0). */")
        out.append(f"static const char pp_float_{c}[] = \"{floats}\";")
        out.append("")
    out.append(f"#define PP_MAX_SLOTS {most}")
    out.append("")
    out.append("/* Every interface class, then every version string a Steam client answers for and its class. */")
    out.append("#define PP_SLOT_CLASSES(X) \\")
    out += [f"    X({c}) \\" for c in classes]
    out[-1] = out[-1][:-2]
    out.append("")
    out.append("#define PP_SLOT_INTERFACES(X) \\")
    out += [f"    X({names[v]}, \"{v}\") \\" for v in sorted(names, key=lambda v: (names[v], v))]
    out[-1] = out[-1][:-2]
    out += ["", "#endif /* STEAMCLIENT_SLOTS_H */", ""]
    return "\n".join(out), len(names), len(classes)


def main():
    clang, sdk, scratch, header = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
    check = "--check" in sys.argv[5:]
    (scratch / "stub").mkdir(parents=True, exist_ok=True)
    for name in ("string.h", "stdio.h", "stdlib.h"):
        (scratch / "stub" / name).write_text(STUB)
    text, nversions, nclasses = generate(clang, sdk, scratch)
    what = f"{nversions} versions, {nclasses} interfaces"
    if check:
        if not header.exists() or header.read_text() != text:
            (scratch / header.name).write_text(text)
            sys.exit(f"steamclient vtables: {header} is not the pinned SDK's; regenerated: {scratch / header.name}")
        print(f"steamclient vtables: {header.name} matches the pinned SDK ({what})")
    else:
        header.write_text(text)
        print(f"steamclient vtables: wrote {header} ({what})")


if __name__ == "__main__":
    main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""pp slots [DXMT_TREE]: check winemetal's unix call slots in a patched DXMT tree.

    pp slots [DXMT_TREE]      default: $PLAYPORT_BUILD/run/dxmt-patched/dxmt

A PE thunk reaches its unix function by slot number: UNIX_CALL(N) in
winemetal_thunks.c, or UNIX_CALL(name) through airconv_thunks.h's enum, is
entry N of __wine_unix_call_funcs, and of __wine_unix_call_wow64_funcs, in
unix/winemetal_unix.c. A rebase can shift a table without touching the calls,
and no compiler notices. This matches every call's thunk name to the entry at
its slot, and every native entry to its wow64 twin, by name. Run it after a
DXMT rebase (AGENTS.md, Pins). Exit 1 when any slot does not match.
"""
import os
import re
import sys

import phonelib

# Words a name may carry on one side only: the unix side's prefixes and
# suffixes, and the airconv enum's shorter tessellation names.
NOISE = {"thunk", "thunk32", "rmg", "wow64", "pipeline"}


def words(name):
    """_rmg_MTLDevice_newX_wow64 -> ['mtl', 'device', 'new', 'x'], WMT read as MTL."""
    w = [x.lower() for part in name.split("_")
         for x in re.findall(r"[A-Z]+[0-9]*(?![a-z])|[A-Z]?[a-z0-9]+", part)]
    return ["mtl" if x == "wmt" else x for x in w if x not in NOISE]


def same(a, b):
    return a == b or words(a) == words(b)


def table(src, name):
    m = re.search(r"const void \*%s\[\] = \{(.*?)\n\};" % name, src, re.S)
    if not m:
        raise SystemExit(f"pp slots: no {name} table")
    return [e.lstrip("&") for e in re.findall(r"^\s*(&?[A-Za-z0-9_]+|NULL)\s*,", m.group(1), re.M)]


def airconv_enum(src):
    """airconv_thunks.h's enum airconv_unixcalls: {name: slot}, counting implicit values."""
    body = re.search(r"enum airconv_unixcalls \{(.*?)\};", src, re.S).group(1)
    slots, n = {}, -1
    for name, value in re.findall(r"unix_([a-z0-9_]+)\s*(?:=\s*(\d+))?\s*,", body):
        n = int(value) if value else n + 1
        slots[name] = n
    return slots


def calls(src, pattern):
    """(function, code) for each UNIX_CALL(code, ...), with the function defined before it."""
    defs = [(m.start(), m.group(1)) for m in
            re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{}()]*\)\s*\{", src)
            if m.group(1) not in ("if", "for", "while", "switch")]
    for m in re.finditer(pattern, src):
        if src[src.rfind("\n", 0, m.start()) + 1:].lstrip().startswith("#"):
            continue  # the UNIX_CALL macro itself
        fn = [name for at, name in defs if at < m.start()]
        yield (fn[-1] if fn else "?"), m.group(1)


def check(tree):
    wm = os.path.join(tree, "src", "winemetal")
    def read(path):
        with open(os.path.join(wm, path)) as f:
            return f.read()
    unix = read("unix/winemetal_unix.c")
    nat, wow = table(unix, "__wine_unix_call_funcs"), table(unix, "__wine_unix_call_wow64_funcs")
    bad = []
    if len(nat) != len(wow):
        bad.append(f"table lengths differ: native {len(nat)}, wow64 {len(wow)}")
    for n, (a, b) in enumerate(zip(nat, wow)):
        if not same(a, b):
            bad.append(f"slot {n:3}: native {a}, wow64 {b}")
    used = [(fn, int(c)) for fn, c in calls(read("winemetal_thunks.c"), r"UNIX_CALL\((\d+),")]
    enum = airconv_enum(read("airconv_thunks.h"))
    for fn, name in calls(read("airconv_thunks.c"), r"\bUNIX_CALL\(([a-z0-9_]+),"):
        if name not in enum:
            bad.append(f"airconv thunk {fn}: unix_{name} is not in enum airconv_unixcalls")
            continue
        used.append((fn, enum[name]))
    for fn, n in used:
        entry = nat[n] if n < len(nat) else None
        if entry is None:
            bad.append(f"slot {n:3}: thunk {fn} calls past the end of the table ({len(nat)})")
        elif not same(fn, entry):
            bad.append(f"slot {n:3}: thunk {fn}, native {entry}")
    return len(nat), len(used), bad


def main(args):
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    tree = args[0] if args else os.path.join(phonelib.BUILD, "run", "dxmt-patched", "dxmt")
    if not os.path.isfile(os.path.join(tree, "src", "winemetal", "unix", "winemetal_unix.c")):
        print(f"pp slots: {tree} is not a DXMT tree (pp build makes run/dxmt-patched/dxmt)", file=sys.stderr)
        return 2
    slots, used, bad = check(tree)
    for b in bad:
        print(b)
    print(f"pp slots: {slots} slots, {used} calls: " + (f"{len(bad)} mismatch(es)" if bad else "every call matches its slot"))
    return 1 if bad else 0

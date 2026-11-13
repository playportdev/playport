#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reconcile a dev build's [dxvk-mem] lines with KosmicKrisp's [kk-mem] lines (PLA-808).

    python3 tools/memreconcile.py LOG [LOG ...]

A Vulkan play's graphics memory is reconciled when DXVK's memory (allocated=, the Vulkan
device memory its allocator holds) plus KosmicKrisp's own allocations ([kk-mem]'s internal,
descriptor, query, command and command-pooled MiB) comes within 10 % of [kk-mem]'s Metal size
(metal=). Each [dxvk-mem] line is paired with the [kk-mem] line next to it in the log, before or
after, whose metal= is nearest to the DXVK line's own metal= (the driver's heap usage, read when
the DXVK line was made). Both lines come every 10 s, and within a second while memory grows fast.

Prints one line per pair and the gap of any pair outside 10 %. Exit 0: every pair within 10 %;
1: a gap; 2: no pair. Reads logs only; launches nothing.
"""

import sys

TOLERANCE = 0.10
# What KosmicKrisp allocates for itself, beside the application's device memory (memory=)
KK_OWN = ("internal", "descriptor", "query", "command", "command-pooled")


def fields(line, tag):
    """The key=value fields after TAG in LINE, or None when LINE has no TAG."""
    at = line.find(tag)
    if at < 0:
        return None
    out = {}
    for token in line[at + len(tag):].split():
        key, sep, value = token.partition("=")
        if sep and key not in out:
            out[key] = value
    return out


def mib(value):
    """A size in MiB: the part after the slash of count/MiB, or the number itself; None if not one."""
    try:
        return float(value.rsplit("/", 1)[-1])
    except (AttributeError, ValueError):
        return None


def kk_own(kk):
    """KosmicKrisp's own allocations in a [kk-mem] line, MiB."""
    return sum(mib(kk[k]) or 0.0 for k in KK_OWN if k in kk)


def reconcile(dxvk_mib, kk_own_mib, metal_mib, tolerance=TOLERANCE):
    """(gap MiB, gap as a share of Metal's size, within tolerance): the gap is what Metal holds
    beyond DXVK's memory and KosmicKrisp's own, negative when they add up to more."""
    gap = metal_mib - (dxvk_mib + kk_own_mib)
    if metal_mib <= 0:
        return gap, 0.0 if gap == 0 else float("inf"), gap == 0
    share = abs(gap) / metal_mib
    return gap, share, share <= tolerance


def pairs(lines):
    """(dxvk fields, kk fields, dxvk line number, logged early) for each [dxvk-mem] line with a
    [kk-mem] line beside it; early: the line came within a second because memory grew fast."""
    parsed = []
    for number, line in enumerate(lines, 1):
        kk = fields(line, "[kk-mem]")
        if kk is not None and mib(kk.get("metal")) is not None:
            parsed.append(("kk", number, kk, False))
            continue
        dxvk = fields(line, "[dxvk-mem]")
        if dxvk is not None and mib(dxvk.get("allocated")) is not None:
            parsed.append(("dxvk", number, dxvk, "| growing" in line))
    out = []
    for i, (kind, number, dxvk, early) in enumerate(parsed):
        if kind != "dxvk":
            continue
        before = next((p[2] for p in reversed(parsed[:i]) if p[0] == "kk"), None)
        after = next((p[2] for p in parsed[i + 1:] if p[0] == "kk"), None)
        near = [kk for kk in (before, after) if kk is not None]
        if not near:
            continue
        metal = mib(dxvk.get("metal"))
        if metal is not None:
            near.sort(key=lambda kk: abs(mib(kk["metal"]) - metal))
        out.append((dxvk, near[0], number, early))
    return out


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    lines = []
    for path in argv:
        with open(path, errors="replace") as f:
            lines.extend(f.read().splitlines())
    found = pairs(lines)
    if not found:
        print("no [dxvk-mem] line with a [kk-mem] line beside it")
        return 2
    gaps = 0
    for dxvk, kk, number, early in found:
        dxvk_mib, own, metal = mib(dxvk["allocated"]), kk_own(kk), mib(kk["metal"])
        gap, share, ok = reconcile(dxvk_mib, own, metal)
        gaps += not ok
        print(f"line {number}{' (early: growing)' if early else ''}: DXVK {dxvk_mib:.0f} + KosmicKrisp's own {own:.0f} = "
              f"{dxvk_mib + own:.0f} MiB, Metal {metal:.0f} MiB (kk memory={mib(kk.get('memory')) or 0:.0f}): "
              f"gap {gap:+.0f} MiB ({share * 100:.1f} %) {'ok' if ok else 'GAP'}")
    print(f"{len(found)} pairs, {gaps} outside {TOLERANCE * 100:.0f} %")
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

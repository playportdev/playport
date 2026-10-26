#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Make Xcode 27's SDK stubs readable by the container's LLVM 22 (build/docker/README.md).

Xcode 27's .tbd files list an `arm64e.x1` architecture next to arm64e, which
lld 22 and ld64-956 reject as unknown. Nothing here links for it: the app,
its frameworks and the unix side are arm64. This drops every `arm64e.x1-*`
target from the target lists of each .tbd under DIR, in place, and fails if a
list would end up empty.

    build/docker/sdk-tbd.py DIR      DIR: the darwin SDK bundle (DARWIN_SDK)
"""

import re
import sys
from pathlib import Path

TARGET = re.compile(r"arm64e\.x1-[a-z]+")


def clean_list(m: re.Match) -> str:
    items = [i.strip() for i in m.group(1).split(",")]
    kept = [i for i in items if i and not TARGET.fullmatch(i)]
    if not kept:
        raise ValueError("a target list holds only arm64e.x1")
    return "[ " + ", ".join(kept) + " ]"


def main() -> None:
    root = Path(sys.argv[1])
    changed = 0
    for tbd in root.rglob("*.tbd"):
        text = tbd.read_text()
        if "arm64e.x1" not in text:
            continue
        # YAML flow lists (tbd v4): `targets: [ a, b,\n c ]`, which may span lines.
        new = re.sub(r"\[([^\[\]]*arm64e\.x1[^\[\]]*)\]", clean_list, text)
        if "arm64e.x1" in new:
            raise SystemExit(f"{tbd}: arm64e.x1 outside a target list")
        tbd.write_text(new)
        changed += 1
    print(f"sdk-tbd: {changed} .tbd files without arm64e.x1")


if __name__ == "__main__":
    main()

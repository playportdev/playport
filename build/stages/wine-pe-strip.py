#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The Wine PE sets as the app stages them: each PE image without its DWARF.

usage: wine-pe-strip.py <wine-tree> <out> <llvm-strip>
  e.g. wine-pe-strip.py $PLAYPORT_BUILD/run/pe/wine $PLAYPORT_BUILD/run/pe/staged $LLVM_MINGW/bin/llvm-strip

stages/wine-pe.sh builds with -g, and every image the runtime maps is copied
whole into the JIT pool (the virtual size, which the .debug_* sections are part
of): 64.5 MiB of the 125 MiB Hollow Knight's 56 runtime images take
(docs/evidence/2026-09-29-pe-debug-strip.md; decision 0019 named it). This
mirrors every file under the two trees' */<arch>-windows/ directories that
wine-pe-manifest.py lists into OUT at the same relative path, a PE image through
`llvm-strip --strip-debug` and anything else as it is. The strip drops only the
.debug_* sections, which lie after every other section, so no section moves; it
keeps the COFF symbol table (tools/sampleprof.py symbolises from it), the DOS
stub with Wine's builtin stamp, the exports and the load config. The full
images stay in the build tree for a debugger. Its output is a function of its
input: an unchanged file (size, mtime) is left as it is, and a file the build
tree no longer has goes.
"""
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys

TREES = {"build-macos": {"i386-windows", "aarch64-windows"},
         "build-arm64ec": {"arm64ec-windows"}}
SKIP_EXT = {".o", ".a", ".res", ".c"}   # as wine-pe-manifest.py


def is_pe(path):
    with open(path, "rb") as f:
        head = f.read(0x40)
        if head[:2] != b"MZ" or len(head) < 0x40:
            return False
        f.seek(int.from_bytes(head[0x3C:0x40], "little"))
        return f.read(4) == b"PE\0\0"


def sources(wine):
    for tree, arch_dirs in TREES.items():
        root = os.path.join(wine, tree)
        for d, _, files in os.walk(root):
            if os.path.basename(d) not in arch_dirs:
                continue
            for name in files:
                p = os.path.join(d, name)
                if os.path.splitext(name)[1] not in SKIP_EXT and not os.path.islink(p):
                    yield os.path.relpath(p, wine)


def main():
    wine, out, strip = sys.argv[1:4]
    index_path = os.path.join(out, ".strip-index.json")
    try:
        index = json.load(open(index_path))
    except (OSError, ValueError):
        index = {}
    want = sorted(sources(wine))
    todo = []
    for rel in want:
        st = os.stat(os.path.join(wine, rel))
        key = [st.st_size, st.st_mtime_ns]
        if index.get(rel) != key or not os.path.isfile(os.path.join(out, rel)):
            todo.append((rel, key))

    def one(item):
        rel, key = item
        src, dst = os.path.join(wine, rel), os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = dst + ".tmp"
        if is_pe(src):
            r = subprocess.run([strip, "--strip-debug", "-o", tmp, src], capture_output=True, text=True)
            if r.returncode:
                return rel, key, r.stderr.strip() or f"llvm-strip exit {r.returncode}"
        else:
            shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
        return rel, key, None

    bad = []
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        for rel, key, err in ex.map(one, todo):
            if err:
                bad.append(f"{rel}: {err}")
            else:
                index[rel] = key
    keep = set(want)
    gone = [rel for rel in index if rel not in keep]
    for rel in gone:
        index.pop(rel)
        try:
            os.remove(os.path.join(out, rel))
        except FileNotFoundError:
            pass
    os.makedirs(out, exist_ok=True)
    with open(index_path + ".tmp", "w") as f:
        json.dump(index, f, sort_keys=True)
    os.replace(index_path + ".tmp", index_path)
    before = sum(os.path.getsize(os.path.join(wine, r)) for r in want)
    after = sum(os.path.getsize(os.path.join(out, r)) for r in want if os.path.isfile(os.path.join(out, r)))
    print(f"wine-pe-strip: {len(want)} files ({len(todo)} written, {len(gone)} removed): "
          f"{before / 2**20:.1f} -> {after / 2**20:.1f} MiB")
    if bad:
        print("\n".join(bad), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

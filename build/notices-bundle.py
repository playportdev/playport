#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check or stage a notice bundle: a `pp notices` output as the app's Licenses/.

  notices-bundle.py check DIR [--distribution]
  notices-bundle.py stage SRC DEST

A bundle is exactly what build/notices-assemble.sh publishes: payloads,
inventory.json (every payload's name, size and sha256, and the collection's
status) and SHA256SUMS (every file but itself). `check` fails on a missing,
changed or unlisted file, a symlink, a special file, an empty directory, an
unsafe or duplicated name, or the two manifests disagreeing. It never repairs
anything. With --distribution it also fails unless the inventory's status is
RELEASE_STATUS, which build/notices-app.py writes only from a reviewed
selection (build/app-notices.json; decision 0039).

`stage` checks SRC, copies it beside DEST, checks the copy against SRC's result
and only then replaces DEST, so a failure leaves DEST as it was. It stages an
incomplete inventory as it is: the status travels with it and `pp verify`
reports it; nothing here marks a bundle release-ready or supplies a placeholder.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path

MANIFESTS = ("inventory.json", "SHA256SUMS")
RELEASE_STATUS = "release-reviewed"
SUM_LINE = re.compile(r"([0-9a-f]{64})  (.+)")


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def safe_name(name):
    parts = name.split("/")
    return (name and not name.startswith("/") and "\\" not in name
            and not any(ord(c) < 0x20 or c == "\x7f" for c in name)
            and all(p not in ("", ".", "..") for p in parts))


def walk(root):
    """Every regular file under root, relative and POSIX; refuse anything else."""
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        here = Path(dirpath)
        if here != root and not dirnames and not filenames:
            raise ValueError(f"empty directory: {here.relative_to(root).as_posix()}")
        for name in dirnames + filenames:
            path = here / name
            rel = path.relative_to(root).as_posix()
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                raise ValueError(f"symlink: {rel}")
            if name in dirnames:
                continue
            if not stat.S_ISREG(mode):
                raise ValueError(f"not a regular file: {rel}")
            if not safe_name(rel):
                raise ValueError(f"unsafe name: {rel!r}")
            files.append(rel)
    return sorted(files)


def read_sums(root):
    listed = {}
    for n, line in enumerate((root / "SHA256SUMS").read_text(encoding="utf-8").splitlines(), 1):
        m = SUM_LINE.fullmatch(line)
        if not m:
            raise ValueError(f"SHA256SUMS line {n} is malformed")
        name = m.group(2).removeprefix("./")
        if not safe_name(name) or name == "SHA256SUMS":
            raise ValueError(f"SHA256SUMS line {n} names an unsafe path")
        if name in listed:
            raise ValueError(f"SHA256SUMS lists {name} twice")
        listed[name] = m.group(1)
    return listed


def read_inventory(root):
    data = json.loads((root / "inventory.json").read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schema") != 1 or not isinstance(data.get("status"), str) \
            or not isinstance(data.get("files"), list):
        raise ValueError("inventory.json is not a schema 1 inventory")
    entries = {}
    for entry in data["files"]:
        if not isinstance(entry, dict) or set(entry) != {"name", "size", "sha256"} \
                or not isinstance(entry["name"], str) or not safe_name(entry["name"]) \
                or type(entry["size"]) is not int or not isinstance(entry["sha256"], str) \
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("inventory.json has a malformed file entry")
        if entry["name"] in MANIFESTS or entry["name"] in entries:
            raise ValueError(f"inventory.json lists {entry['name']} twice or as a payload")
        entries[entry["name"]] = (entry["size"], entry["sha256"])
    return data["status"], entries


def check(root, distribution=False):
    """The bundle's status, file count and payload bytes; ValueError on any defect."""
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"not a directory: {root}")
    files = walk(root)
    for name in MANIFESTS:
        if name not in files:
            raise ValueError(f"missing {name}")
    listed = read_sums(root)
    expected = set(files) - {"SHA256SUMS"}
    if set(listed) - expected:
        raise ValueError("SHA256SUMS lists missing files: " + ", ".join(sorted(set(listed) - expected)[:5]))
    if expected - set(listed):
        raise ValueError("files not in SHA256SUMS: " + ", ".join(sorted(expected - set(listed))[:5]))
    changed = sorted(name for name in listed if digest(root / name) != listed[name])
    if changed:
        raise ValueError("files differ from SHA256SUMS: " + ", ".join(changed[:5]))
    status, entries = read_inventory(root)
    payloads = expected - {"inventory.json"}
    if set(entries) != payloads:
        diff = sorted(set(entries) ^ payloads)
        raise ValueError("inventory.json and the files differ: " + ", ".join(diff[:5]))
    for name, (size, sha) in entries.items():
        if (root / name).stat().st_size != size or listed[name] != sha:
            raise ValueError(f"inventory.json records {name} differently")
    if distribution and status != RELEASE_STATUS:
        raise ValueError(f"inventory status is {status!r}, not {RELEASE_STATUS!r}: not distributable")
    return {"status": status, "files": len(payloads), "bytes": sum(s for s, _ in entries.values())}


def stage(src, dest):
    src, dest = Path(src).resolve(), Path(os.path.abspath(dest))
    if dest.is_symlink() or (dest.exists() and not dest.is_dir()):
        raise ValueError(f"not a directory: {dest}")
    if src == dest or src in dest.parents or dest in src.parents:
        raise ValueError("source and destination overlap")
    want = check(src)
    dest.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=f".{dest.name}.partial.", dir=dest.parent))
    old = None
    try:
        copy = work / "bundle"
        shutil.copytree(src, copy, symlinks=True)
        if check(copy) != want or read_sums(copy) != read_sums(src):
            raise ValueError("the staged copy differs from its source")
        if dest.exists():
            old = work / "old"
            dest.rename(old)
        copy.rename(dest)
    except BaseException:
        if old is not None and not dest.exists():
            old.rename(dest)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return want


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    c = sub.add_parser("check")
    c.add_argument("dir", type=Path)
    c.add_argument("--distribution", action="store_true")
    s = sub.add_parser("stage")
    s.add_argument("src", type=Path)
    s.add_argument("dest", type=Path)
    a = ap.parse_args()
    try:
        r = check(a.dir, a.distribution) if a.command == "check" else stage(a.src, a.dest)
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        sys.exit(f"notice bundle: {exc}")
    print(f"notice bundle: {r['files']} files, {r['bytes']:,} B, status {r['status']}"
          + ("" if r["status"] == RELEASE_STATUS else " (not distributable)"))


if __name__ == "__main__":
    main()

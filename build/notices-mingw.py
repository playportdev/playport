#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Collect exact mingw-w64 source notices; not toolchain/binary derivation proof."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re

spec = importlib.util.spec_from_file_location("mingw_provenance", Path(__file__).with_name("notices-provenance.py"))
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)

REQUIRED = (
    "COPYING", "AUTHORS", "COPYING.MinGW-w64/COPYING.MinGW-w64.txt",
    "COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt",
    "mingw-w64-crt/profile/COPYING", "mingw-w64-libraries/winpthreads/COPYING",
    "mingw-w64-libraries/winstorecompat/COPYING",
)
INSTALLED = {
    "COPYING": "COPYING",
    "COPYING.MinGW-w64.txt": "COPYING.MinGW-w64/COPYING.MinGW-w64.txt",
    "COPYING.MinGW-w64-runtime.txt": "COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt",
    "COPYING.winpthreads.txt": "mingw-w64-libraries/winpthreads/COPYING",
    "COPYING.winstorecompat.txt": "mingw-w64-libraries/winstorecompat/COPYING",
}
TARGETS = ("aarch64-w64-mingw32", "i686-w64-mingw32", "x86_64-w64-mingw32")
MANIFEST = "mingw-provenance.json"


def regular(path):
    if any(p.is_symlink() for p in (path, *path.parents)) or not path.is_file():
        raise ValueError(f"not a regular non-symlink notice input: {path}")
    return path.read_bytes()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_source(path):
    return (isinstance(path, str) and bool(path) and not any(ord(c) < 32 or ord(c) == 127 for c in path)
            and "\\" not in path and ":" not in path and not path.startswith("/")
            and all(p not in ("", ".", "..") for p in path.split("/")))


def payloads(record):
    """Recheck internal coverage/origins without accepting a partial copy set."""
    candidates = record["notice_candidates"]
    if record["lock"]["schema"] != 1:
        raise ValueError("unsupported mingw notice lock")
    for component in ("llvm_mingw", "mingw_w64"):
        tree = record["trees"][component]
        if (tree["base_commit"] != record["lock"][component]["commit"]
                or tree["pin"] != tree["base_commit"] or tree["patches"]):
            raise ValueError("mingw tree provenance differs from lock")
    if record["schema"] != 1 or not set(REQUIRED).issubset(candidates):
        raise ValueError("mingw notice inventory lacks required sources")
    expected = {}
    for path, details in sorted(candidates.items()):
        if not safe_source(path):
            raise ValueError("unsafe mingw notice source path")
        name = "mingw-source-" + path.replace("/", "-")
        if name in expected:
            raise ValueError("duplicate flattened mingw notice name")
        if not re.fullmatch(r"[0-9a-f]{64}", details["sha256"]) or details["size"] < 0:
            raise ValueError("invalid mingw notice hash/size")
        expected[name] = {"source": path, **details}
    if record["collected_notices"] != expected:
        raise ValueError("mingw notice origin coverage differs")
    installed = {}
    for target in TARGETS:
        for name, source in INSTALLED.items():
            installed[f"{target}/share/mingw32/{name}"] = {"source": source, **candidates[source]}
    if record["installed_notices"] != installed:
        raise ValueError("mingw installed notice coverage differs")
    return expected


def prepare(repo, source, llvm_source, toolchain, scratch):
    lock_path = repo / "build/mingw-notices.lock.json"
    regular(lock_path)
    provenance.tracked_file(repo, lock_path)
    lock = json.loads(lock_path.read_text())
    if lock["schema"] != 1:
        raise ValueError("unsupported mingw notice lock")
    for component in ("llvm_mingw", "mingw_w64"):
        if not re.fullmatch(r"[0-9a-f]{40}", lock[component]["commit"]):
            raise ValueError("mingw notice lock requires full commits")
    if lock["llvm_mingw"]["script"] != "build-mingw-w64.sh":
        raise ValueError("unexpected llvm-mingw build script")
    for root in (source, llvm_source, toolchain):
        if any(p.is_symlink() for p in (root, *root.parents)) or not root.is_dir():
            raise ValueError(f"not a non-symlink input directory: {root}")
    if (any(p.is_symlink() for p in (scratch, *scratch.parents))
            or any(scratch.resolve().is_relative_to(root.resolve()) for root in (source, llvm_source, toolchain))):
        raise ValueError("notice scratch must not be symlinked or inside an input tree")
    scratch.mkdir(parents=True, exist_ok=True)
    trees = {
        "mingw_w64": provenance.verify_tree(source, lock["mingw_w64"]["commit"], [], scratch),
        "llvm_mingw": provenance.verify_tree(llvm_source, lock["llvm_mingw"]["commit"], [], scratch),
    }
    script_path = llvm_source / lock["llvm_mingw"]["script"]
    provenance.tracked_file(llvm_source, script_path)
    script = regular(script_path)
    if sha(script) != lock["llvm_mingw"]["script_sha256"]:
        raise ValueError("llvm-mingw build script checksum differs")
    versions = re.findall(rb'^: \$\{MINGW_W64_VERSION:=([0-9a-f]{40})\}$', script, re.MULTILINE)
    if versions != [lock["mingw_w64"]["commit"].encode()]:
        raise ValueError("llvm-mingw script does not name the locked mingw-w64 revision")
    notices = {}
    for entry in provenance.git(source, "ls-tree", "-rz", "HEAD").split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        path = raw_path.decode()
        if (path != "AUTHORS" and not PurePosixPath(path).name.lower().startswith(
                ("copying", "copyright", "license", "licence", "notice", "unlicense"))):
            continue
        if not safe_source(path) or metadata.split()[0] not in (b"100644", b"100755"):
            raise ValueError("unsafe/non-regular committed mingw notice")
        provenance.tracked_file(source, source / path)
        notices[path] = regular(source / path)
    if not set(REQUIRED).issubset(notices):
        raise ValueError("missing required mingw source notices")
    candidates = {p: {"sha256": sha(data), "size": len(data)} for p, data in sorted(notices.items())}
    installed = {}
    for target in TARGETS:
        for name, path in INSTALLED.items():
            relative = f"{target}/share/mingw32/{name}"
            if regular(toolchain / relative) != notices[path]:
                raise ValueError(f"installed mingw notice differs from locked source: {relative}")
            installed[relative] = {"source": path, **candidates[path]}
    collected = {}
    for path, details in candidates.items():
        name = "mingw-source-" + path.replace("/", "-")
        if name in collected:
            raise ValueError("duplicate flattened mingw notice name")
        collected[name] = {"source": path, **details}
    record = {"schema": 1, "scope": "source notice superset and installed notice bytes; not binary derivation or IPA provenance",
              "lock_sha256": provenance.digest(lock_path), "lock": lock, "trees": trees,
              "notice_candidates": candidates, "installed_notices": installed, "collected_notices": collected}
    payloads(record)
    return record, {name: notices[origin["source"]] for name, origin in collected.items()}


def collect(repo, source, llvm_source, toolchain, scratch, out):
    if any(out.resolve().is_relative_to(root.resolve()) for root in (source, llvm_source, toolchain)):
        raise ValueError("notice output must not be inside an input tree")
    record, copies = prepare(repo, source, llvm_source, toolchain, scratch)
    copies[MANIFEST] = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
    if any(p.is_symlink() for p in (out, *out.parents)) or not out.is_dir():
        raise ValueError("notice output must be a non-symlink directory")
    for name in copies:
        if (out / name).exists() or (out / name).is_symlink():
            raise ValueError(f"notice output already exists: {name}")
    created = []
    try:
        for name, data in copies.items():
            path = out / name
            with path.open("xb") as handle:
                created.append(path)
                handle.write(data)
    except BaseException:
        for path in reversed(created):
            path.unlink()
        raise
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "source", "llvm_source", "toolchain", "scratch", "out"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        collect(args.repo, args.source, args.llvm_source, args.toolchain, args.scratch, args.out)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"MinGW notice collection: {exc}\n")


if __name__ == "__main__":
    main()

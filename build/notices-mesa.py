#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Preserve Mesa Vulkan/SPIR-V headers as a committed-byte notice superset.

No guessed comment ranges: copy full headers, including code, all copyright and
permission blocks and normative warnings. This is not compiled-header or linked
member evidence. Assembly first requires the exact Mesa pin-plus-series tree.
"""

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("notice_provenance", Path(__file__).with_name("notices-provenance.py"))
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)

DIRECTORIES = ("include/vulkan", "include/vk_video", "src/compiler/spirv")
REQUIRED = (
    "include/vulkan/vulkan.h", "include/vulkan/vulkan_core.h",
    "include/vulkan/vk_platform.h", "include/vulkan/vk_icd.h",
    "include/vulkan/vk_layer.h", "include/vulkan/vk_android_native_buffer.h",
    "include/vk_video/vulkan_video_codecs_common.h",
    *("src/compiler/spirv/" + name for name in
      ("spirv.h", "GLSL.std.450.h", "GLSL.ext.AMD.h", "OpenCL.std.h", "NonSemanticShaderDebugInfo100.h")),
)
PREFIX = "mesa-header-superset-"
MANIFEST = "mesa-provenance.json"
SCOPE = "full-header notice superset, including other platforms and Mesa-local SPIR-V headers; not applicability or linked members"


def regular_path(path, directory=False):
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError(f"symlink in Mesa notice path: {path}")
    if not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f"missing regular Mesa notice input: {path}")
    if any(ord(c) < 32 or ord(c) == 127 for c in str(path)):
        raise ValueError("control character in Mesa notice path")


def selected(relative):
    path = Path(relative)
    return (path.suffix == ".h" and
            (any(relative.startswith(root + "/") for root in DIRECTORIES[:2])
             or path.parent.as_posix() == DIRECTORIES[2]))


def snapshot(tree):
    """Read clean committed source bytes and the complete selected file set."""
    regular_path(tree, directory=True)
    tree = tree.resolve(strict=True)
    actual = Path(provenance.git(tree, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if actual != tree:
        raise ValueError("Mesa input is not a repository root")
    # Disable Git's optional index refresh: shared source inputs are read only.
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    if provenance.git(tree, "status", "--porcelain", "--untracked-files=all", env=env):
        raise ValueError("dirty or untracked Mesa source inputs")
    tracked = {}
    for entry in provenance.git(tree, "ls-tree", "-rz", "HEAD").split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        relative = raw_path.decode()
        if selected(relative):
            mode, kind, oid = metadata.decode().split()
            if mode not in ("100644", "100755") or kind != "blob":
                raise ValueError(f"Mesa header is not a committed regular file: {relative}")
            tracked[relative] = oid
    discovered = set()
    for directory in DIRECTORIES:
        root = tree / directory
        regular_path(root, directory=True)
        # Check every directory/link, even if it hides header candidates.
        for path in root.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"symlink in Mesa header directory: {path}")
            if selected(path.relative_to(tree).as_posix()):
                regular_path(path)
                discovered.add(path.relative_to(tree).as_posix())
    if not set(REQUIRED) <= set(tracked) or not set(REQUIRED) <= discovered:
        raise ValueError("missing required Mesa vendored header")
    if discovered != set(tracked):
        raise ValueError("missing or untracked (including ignored) Mesa header inputs")
    payloads, origins = {}, {}
    for relative, oid in sorted(tracked.items()):
        source = tree / relative
        origin = provenance.committed_origin(source, [("mesa", tree)])
        # Refuse undeclared/nested repositories even when their bytes match.
        if Path(provenance.git(source.parent, "rev-parse", "--show-toplevel").decode().strip()).resolve() != tree:
            raise ValueError("Mesa vendored header must belong to the component repository")
        data = source.read_bytes()
        if not data:
            raise ValueError(f"empty Mesa header: {relative}")
        # Recompare bytes read for copying; do not rely on an earlier hash only.
        if data != provenance.git(tree, "cat-file", "blob", oid):
            raise ValueError(f"Mesa header bytes differ from HEAD: {relative}")
        name = PREFIX + relative.replace("/", "-") + ".txt"
        if name in payloads:
            raise ValueError(f"duplicate Mesa notice output: {name}")
        sha256 = hashlib.sha256(data).hexdigest()
        payloads[name] = data
        origins[name] = {**origin, "kind": "full-header", "blob": oid,
                         "first_line": 1, "last_line": len(io.BytesIO(data).readlines()),
                         "source_sha256": sha256, "sha256": sha256, "size": len(data)}
    record = {"schema": 1, "scope": SCOPE,
              "selection": {"recursive_header_directories": list(DIRECTORIES[:2]),
                            "top_level_header_directory": DIRECTORIES[2],
                            "required": list(REQUIRED)},
              "tree": provenance.git(tree, "rev-parse", "HEAD^{tree}").decode().strip(),
              "files": origins}
    return record, payloads


def collect(tree, out):
    regular_path(out, directory=True)
    regular_path(tree, directory=True)
    if out.resolve().is_relative_to(tree.resolve()) or tree.resolve().is_relative_to(out.resolve()):
        raise ValueError("Mesa notice output overlaps source tree")
    record, payloads = snapshot(tree)
    payloads[MANIFEST] = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()
    for name in payloads:
        if (out / name).exists() or (out / name).is_symlink():
            raise ValueError(f"duplicate Mesa notice output: {name}")
    created = []
    try:
        for name, data in payloads.items():
            with (out / name).open("xb") as output:
                created.append(out / name)
                output.write(data)
    except Exception:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    return record


def validate(tree, out):
    """Recheck committed bytes, selection, exact origins and all copied payloads."""
    record = json.loads(provenance.notice_payload(out, MANIFEST).read_text())
    expected, payloads = snapshot(tree)
    if record != expected:
        raise ValueError("Mesa notice origin/selection map differs from committed sources")
    actual = {path.name for path in out.iterdir() if path.name.startswith(PREFIX)}
    if actual != set(payloads):
        raise ValueError("Mesa notice payload set differs from provenance")
    for name, data in payloads.items():
        if provenance.notice_payload(out, name).read_bytes() != data:
            raise ValueError(f"Mesa notice changed after collection: {name}")
    gate = out / "tree-provenance.json"
    if gate.exists():
        tree_record = json.loads(provenance.notice_payload(out, gate.name).read_text())
        if tree_record["trees"]["mesa"]["tree"] != record["tree"]:
            raise ValueError("Mesa notice tree differs from assembly's exact tree gate")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mesa", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    try:
        record = collect(args.mesa, args.out)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Mesa notice collection: {exc}\n")
    print(f"{len(record['files'])} full Mesa headers (notice superset, not applicability audit)")


if __name__ == "__main__":
    main()

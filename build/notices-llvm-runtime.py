#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline exact-source LLVM runtime credit superset; deliberately incomplete."""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile

# Loading shared validation code must not create cache files beside read-only
# release-script inputs. Restore the caller's interpreter setting afterwards.
bytecode = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("llvm_notice_helpers", Path(__file__).with_name("notices-mingw.py"))
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
finally:
    sys.dont_write_bytecode = bytecode
regular, sha, safe_source = helpers.regular, helpers.sha, helpers.safe_source

LOCK = "build/llvm-runtime-notices.lock.json"
MANIFEST = "llvm-runtime-provenance.json"
SCOPES = ("libcxx", "libcxxabi", "libunwind", "compiler-rt", "clang/lib/Headers")
SCRIPTS = ("build-llvm.sh", "build-libcxx.sh", "build-compiler-rt.sh", "build-all.sh", "release.sh", "Dockerfile")
REQUIRED = (
    "LICENSE.TXT", "libcxx/LICENSE.TXT", "libcxx/CREDITS.TXT",
    "libcxxabi/LICENSE.TXT", "libcxxabi/CREDITS.TXT", "libunwind/LICENSE.TXT",
    "compiler-rt/LICENSE.TXT", "compiler-rt/CREDITS.TXT", "compiler-rt/lib/builtins/README.txt",
    "libcxx/src/include/ryu/ryu.h", "libcxx/src/include/to_chars_floating_point.h",
    "libunwind/src/dwarf2.h", "clang/lib/Headers/avxvnniintrin.h",
    "clang/lib/Headers/cuda_wrappers/new",
    "libcxx/include/__format/escaped_output_table.h",
    "libcxx/include/__format/extended_grapheme_cluster_table.h",
    "libcxx/include/__format/indic_conjunct_break_table.h",
    "libcxx/include/__format/width_estimation_table.h",
    "libcxx/include/__mdspan/extents.h", "compiler-rt/lib/BlocksRuntime/Block.h",
    "compiler-rt/lib/profile/WindowsMMap.c",
)
POLICY = "recursive-whole-file-credit-superset-v1"
MARKERS = re.compile(rb"copyright|licen[cs]e|permission|attribution|credits?|authors?|derived from|public domain|SPDX", re.I)
BASENAMES = ("license", "licence", "copying", "copyright", "notice", "unlicense", "credits", "authors")
SCOPE_TEXT = ("INCOMPLETE LLVM runtime/header credit superset.\n"
              "Recursive notice files and whole files containing credit/license markers are preserved byte for byte.\n"
              "Includes tests, tools, documentation and other platforms; not a linked-member inventory.\n"
              "Marker discovery is not a complete header/generated-data attribution audit.\n"
              "Generated installed headers, external dependencies, binary derivation and exact-IPA linkage remain open.\n"
              "Not legal release approval or complete Corresponding Source.\n").encode()


def git(root, *args):
    # Never let a partial clone fetch missing objects during collection/verification.
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    return helpers.provenance.git(root, *args, env=env)


def no_symlinks(path):
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("symlinked path or parent")


def directory(path):
    no_symlinks(path)
    if not path.is_dir():
        raise ValueError("missing input/output directory")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def load(data):
    return json.loads(data, object_pairs_hook=unique_object)


def encoded(record):
    return (json.dumps(record, indent=2, sort_keys=True) + "\n").encode()


def object_id(kind, data):
    return hashlib.sha1(kind.encode() + b" " + str(len(data)).encode() + b"\0" + data).hexdigest()


def blob(data):
    return object_id("blob", data)


def details(data):
    return {"blob": blob(data), "sha256": sha(data), "size": len(data)}


def tree(root, identity):
    directory(root)
    no_symlinks(root / ".git")
    for field in ("commit", "tree"):
        if not re.fullmatch(r"[0-9a-f]{40}", identity[field]):
            raise ValueError("lock needs full commit/tree identities")
    if Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve() != root.resolve():
        raise ValueError("not a Git source root")
    if (git(root, "rev-parse", "HEAD").decode().strip() != identity["commit"]
            or git(root, "rev-parse", "HEAD^{tree}").decode().strip() != identity["tree"]):
        raise ValueError("source is not the locked exact commit/tree")
    for kind in ("commit", "tree"):
        if object_id(kind, git(root, "cat-file", kind, identity[kind])) != identity[kind]:
            raise ValueError("Git source object checksum differs")
    git(root, "diff", "--no-ext-diff", "--no-textconv", "--cached", "--exit-code", "HEAD")
    git(root, "diff", "--no-ext-diff", "--no-textconv", "--exit-code", "HEAD")
    # Do not trust index flags which can hide materialized dirty files.
    for entry in git(root, "ls-files", "-v", "-z").split(b"\0"):
        if not entry:
            continue
        flag, raw_path = entry.split(b" ", 1)
        path = raw_path.decode("utf-8")
        if not safe_source(path):
            raise ValueError("unsafe tracked source path")
        if flag.islower() or (flag == b"S" and (root / path).exists()):
            raise ValueError("hidden materialized/assume-unchanged source input")
    # Sparse absent paths outside the scanned scope are allowed, extras are not,
    # including ignored generated files.
    if git(root, "ls-files", "--others", "-z"):
        raise ValueError("untracked source files")


def entries(root, paths):
    result = {}
    for entry in git(root, "ls-tree", "-rz", "HEAD", "--", *paths).split(b"\0"):
        if not entry:
            continue
        meta, raw = entry.split(b"\t", 1)
        path = raw.decode("utf-8")
        mode, kind, oid = meta.decode().split()
        if not safe_source(path) or mode not in ("100644", "100755") or kind != "blob":
            raise ValueError("unsafe/non-regular source entry")
        result[path] = {"mode": mode, "blob": oid}
    return result


def committed(root, path, entry):
    data = regular(root / path)
    info = details(data)
    if info["blob"] != entry["blob"]:
        raise ValueError("source bytes differ from committed blob: " + path)
    return data, info


def prepare(repo, source, llvm_mingw):
    """Read-only, offline; enumerate every scoped regular source, not just notices."""
    directory(repo)
    no_symlinks(repo / ".git")
    raw_lock = regular(repo / LOCK)
    locked = entries(repo, (LOCK,))
    if LOCK not in locked or blob(raw_lock) != locked[LOCK]["blob"]:
        raise ValueError("notice lock differs from committed bytes")
    if git(repo, "diff", "--cached", "--name-only", "HEAD", "--", LOCK):
        raise ValueError("staged notice lock changes")
    lock = load(raw_lock)
    if lock["schema"] != 1 or lock["policy"] != POLICY:
        raise ValueError("unsupported lock/policy")
    if set(lock["scripts"]) != set(SCRIPTS) or set(lock["required_inputs"]) != set(REQUIRED):
        raise ValueError("missing mandatory locked notice/script inputs")
    if lock["llvm"]["repository"] != "https://github.com/llvm/llvm-project.git":
        raise ValueError("unexpected LLVM source repository")
    tree(source, lock["llvm"])
    tree(llvm_mingw, lock["llvm_mingw"])
    script_entries = entries(llvm_mingw, SCRIPTS)
    scripts = {}
    for path in SCRIPTS:
        data, info = committed(llvm_mingw, path, script_entries[path])
        if info != lock["scripts"][path]:
            raise ValueError("release script checksum/blob differs")
        scripts[path] = data
    for key, value in (("LLVM_REPOSITORY", lock["llvm"]["repository"]), ("LLVM_VERSION", lock["llvm"]["tag"])):
        if re.findall(rb"^: \$\{" + key.encode() + rb":=([^}\r\n]+)\}$", scripts["build-llvm.sh"], re.M) != [value.encode()]:
            raise ValueError("release script default differs from lock")
    scanned, candidates, copies = {}, {}, {}
    source_entries = entries(source, ("LICENSE.TXT", *SCOPES))
    if not set(REQUIRED).issubset(source_entries):
        raise ValueError("missing mandatory source notices/credits")
    for scope in SCOPES:
        if not any(p.startswith(scope + "/") for p in source_entries):
            raise ValueError("missing source scope")
    for path, entry in sorted(source_entries.items()):
        data, info = committed(source, path, entry)
        if path in REQUIRED and info != lock["required_inputs"][path]:
            raise ValueError("mandatory notice/credit checksum differs")
        reasons = []
        if path in REQUIRED:
            reasons.append("mandatory-reviewed-input")
        if PurePosixPath(path).name.lower().startswith(BASENAMES) or "LICENSES" in path.split("/"):
            reasons.append("notice-path")
        if MARKERS.search(data):
            reasons.append("credit-marker")
        scanned[path] = {**entry, **info, "selected_by": reasons}
        if not reasons:
            continue
        # Whole source files, not lossy/reformatted comment extraction. Binary
        # fixtures are scanned/hashed but may not masquerade as notice texts.
        if b"\0" in data:
            raise ValueError("selected notice/credit input is binary: " + path)
        name = "llvm-runtime-" + path.replace("/", "-")
        if name in copies:
            raise ValueError("flattened notice name collision")
        copies[name] = data
        candidates[name] = {"source": path, "commit": lock["llvm"]["commit"],
                            "tree": lock["llvm"]["tree"], "selector": "whole-file",
                            **scanned[path]}
    record = {"schema": 1, "complete": False, "policy": POLICY, "scopes": list(SCOPES),
              "lock_sha256": sha(raw_lock), "lock": lock,
              "scanned_files": scanned, "collected_notices": candidates}
    return record, copies


def output_bytes(record, copies):
    result = dict(copies)
    result[MANIFEST] = encoded(record)
    result["SCOPE.txt"] = SCOPE_TEXT
    result["SHA256SUMS"] = "".join(f"{sha(data)}  {name}\n" for name, data in sorted(result.items())).encode()
    return result


def verify_output(out, record, copies):
    """Compare complete regenerated origins, discovery, texts and checksums."""
    directory(out)
    expected = output_bytes(record, copies)
    if set(p.name for p in out.iterdir()) != set(expected):
        raise ValueError("output payload set differs")
    for name, data in expected.items():
        if regular(out / name) != data:
            raise ValueError("output bytes/origins changed: " + name)


def verify(repo, source, llvm_mingw, out):
    record, copies = prepare(repo, source, llvm_mingw)
    verify_output(out, record, copies)
    return record


def publish(stage, out):
    """Linux atomic no-replace publication, including a racing empty directory."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(stage), -100, os.fsencode(out), 1):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def collect(repo, source, llvm_mingw, out):
    no_symlinks(out)
    directory(out.parent)
    if out.exists():
        raise ValueError("output already exists")
    for root in (repo, source, llvm_mingw):
        if out.resolve().is_relative_to(root.resolve()) or root.resolve().is_relative_to(out.resolve()):
            # The Playport repository's own .work is the intended output area.
            if root == repo and out.resolve().is_relative_to((repo / ".work").resolve()):
                continue
            raise ValueError("output overlaps an input tree")
    record, copies = prepare(repo, source, llvm_mingw)
    stage = Path(tempfile.mkdtemp(prefix=out.name + ".partial.", dir=out.parent))
    try:
        for name, data in output_bytes(record, copies).items():
            with (stage / name).open("xb") as handle:
                handle.write(data)
        # Repeat source and lock validation immediately before publication.
        verify(repo, source, llvm_mingw, stage)
        no_symlinks(out)
        publish(stage, out)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "collect", "verify"))
    for name in ("repo", "source", "llvm_mingw"):
        parser.add_argument(name, type=Path)
    parser.add_argument("out", type=Path, nargs="?")
    args = parser.parse_args()
    if (args.action == "inspect") != (args.out is None):
        parser.error("collect/verify require OUT; inspect does not accept OUT")
    try:
        if args.action == "inspect":
            print(encoded(prepare(args.repo, args.source, args.llvm_mingw)[0]).decode(), end="")
        else:
            record = (collect if args.action == "collect" else verify)(args.repo, args.source, args.llvm_mingw, args.out)
            print(json.dumps({"complete": False, "scanned": len(record["scanned_files"]),
                              "collected": len(record["collected_notices"])}))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        parser.exit(1, f"LLVM runtime notices: {exc}\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare the notice collection's source inputs from their committed locks.

  notices-inputs.py CACHE [--plan]

build/notices-assemble.sh reads these offline and never fetches them. This puts
each one in CACHE (the build's $PLAYPORT_BUILD/cache) where it is missing:

  mingw-w64-notices, llvm-mingw-notices   clean checkouts at build/mingw-notices.lock.json's commits
  llvm-runtime-notices                    a sparse checkout of build/llvm-runtime-notices.lock.json's
                                          LLVM commit (the runtime scopes and the root files)
  rust-dist/ARCHIVE                       build/rust-dist.lock.json's three release archives
  gstreamer-notices/cerbero.tar.gz, gstreamer-notices/sources/ARCHIVE
                                          build/gstreamer-notices.sources.json's archives

A file is taken only with its locked sha256 and a checkout only at its locked
commit, each built in a private directory beside its final path and moved into
place when complete, so two builds sharing the cache never see half an input.
One that is already there is kept when it is right and refused when it is not:
a wrong or dirty checkout, or a file with another checksum, is reported, never
replaced. An input named by its environment variable (MINGW_SOURCE,
LLVM_MINGW_SOURCE, LLVM_RUNTIME_SOURCE, RUST_NOTICE_DIST, GST_NOTICE_CERBERO,
GST_NOTICE_SOURCES) is the person's: it is left alone. Collection checks every
input again against its lock; this only saves preparing them by hand
(docs/NOTICES.md, "Collecting the files"). --plan fetches nothing and prints
what is missing.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("notices_llvm_runtime", REPO / "build/notices-llvm-runtime.py")
llvm_runtime = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(llvm_runtime)


def lock(name):
    return json.loads((REPO / "build" / name).read_text(encoding="utf-8"))


def inputs(env=os.environ):
    """(kind, path relative to CACHE, source, identity, extra, overriding variable) for every input."""
    mingw = lock("mingw-notices.lock.json")
    runtime = lock("llvm-runtime-notices.lock.json")
    rust = lock("rust-dist.lock.json")
    gst = lock("gstreamer-notices.sources.json")
    out = [
        ("git", "mingw-w64-notices", mingw["mingw_w64"]["repository"], mingw["mingw_w64"]["commit"], None,
         "MINGW_SOURCE"),
        ("git", "llvm-mingw-notices", mingw["llvm_mingw"]["repository"], mingw["llvm_mingw"]["commit"], None,
         "LLVM_MINGW_SOURCE"),
        ("git", "llvm-runtime-notices", runtime["llvm"]["repository"], runtime["llvm"]["commit"],
         list(llvm_runtime.SCOPES), "LLVM_RUNTIME_SOURCE"),
    ]
    if runtime["llvm_mingw"]["commit"] != mingw["llvm_mingw"]["commit"]:
        raise ValueError("the LLVM runtime and mingw-w64 locks name different llvm-mingw commits")
    for c in rust["components"].values():
        out.append(("file", f"rust-dist/{c['archive']}", c["url"], c["sha256"], None, "RUST_NOTICE_DIST"))
    out.append(("file", "gstreamer-notices/cerbero.tar.gz", gst["cerbero"]["url"], gst["cerbero"]["sha256"], None,
                "GST_NOTICE_CERBERO"))
    for c in gst["components"].values():
        out.append(("file", f"gstreamer-notices/sources/{c['archive']}", c["reviewed_download_url"], c["sha256"],
                    None, "GST_NOTICE_SOURCES"))
    for kind, rel, source, ident, _, _ in out:
        full = {"git": 40, "file": 64}[kind]
        if not source.startswith("https://") or ".." in rel.split("/") or len(ident) != full:
            raise ValueError(f"lock entry for {rel} is not an https source with a full identity")
    return [i for i in out if not env.get(i[5])]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def git(root, *args, capture=True):
    r = subprocess.run(["git", "-C", str(root), *args], check=True, text=True,
                       stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                       stderr=subprocess.PIPE if capture else None)
    return (r.stdout or "").strip()


def state(kind, path, ident):
    """'missing', 'ok', or why what is there is not the input."""
    if not path.exists() and not path.is_symlink():
        return "missing"
    if path.is_symlink():
        return "is a symlink"
    if kind == "file":
        if not path.is_file():
            return "is not a regular file"
        got = sha256(path)
        return "ok" if got == ident else f"has sha256 {got}, not {ident}"
    try:
        if Path(git(path, "rev-parse", "--show-toplevel")).resolve() != path.resolve():
            return "is not a Git checkout root"
        head = git(path, "rev-parse", "HEAD")
        if head != ident:
            return f"is at {head}, not {ident}"
        if git(path, "status", "--porcelain", "--untracked-files=all", "--ignored"):
            return "has local changes or untracked files"
    except subprocess.CalledProcessError as e:
        return f"is not a usable Git checkout ({(e.stderr or '').strip().splitlines()[-1:] or e})"
    return "ok"


def fetch_file(url, ident, part):
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(part), url], check=True)
    got = sha256(part)
    if got != ident:
        raise ValueError(f"{url} has sha256 {got}, not the locked {ident}")


def fetch_git(url, commit, sparse, part):
    part.mkdir()
    git(part, "init", "-q")
    git(part, "remote", "add", "origin", url)
    if sparse:
        # Cone mode keeps the root's files (LICENSE.TXT) with the scoped directories.
        git(part, "sparse-checkout", "set", "--cone", *sparse)
    git(part, "fetch", "-q", "--depth", "1", *(["--filter=blob:none"] if sparse else []), "origin", commit,
        capture=False)
    git(part, "-c", "advice.detachedHead=false", "checkout", "-q", "--detach", "FETCH_HEAD", capture=False)
    # A partial clone would fetch any missing blob on demand; collection must fail instead.
    git(part, "remote", "remove", "origin")
    if git(part, "rev-parse", "HEAD") != commit:
        raise ValueError(f"{url} gave another commit for {commit}")


def prepare(cache, items, plan=False, fetchers=None):
    """Put each missing item in cache; return the relative paths prepared (or, with plan, missing)."""
    fetchers = fetchers or {"file": lambda src, ident, extra, part: fetch_file(src, ident, part),
                            "git": lambda src, ident, extra, part: fetch_git(src, ident, extra, part)}
    cache = Path(cache)
    bad = []
    todo = []
    for kind, rel, source, ident, extra, var in items:
        s = state(kind, cache / rel, ident)
        if s == "missing":
            todo.append((kind, rel, source, ident, extra))
        elif s != "ok":
            bad.append(f"{cache / rel} {s} (remove it to prepare it again, or name another with {var})")
    if bad:
        raise ValueError("\n".join(bad))
    if plan:
        return [rel for _, rel, *_ in todo]
    done = []
    for kind, rel, source, ident, extra in todo:
        final = cache / rel
        final.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=final.parent, prefix=f".{final.name}.partial.") as tmp:
            part = Path(tmp) / final.name
            print(f"preparing {rel} from {source}", flush=True)
            fetchers[kind](source, ident, extra, part)
            if state(kind, part, ident) != "ok":
                raise ValueError(f"{rel} is not its locked input after preparing it: {state(kind, part, ident)}")
            try:
                part.rename(final)
            except OSError:
                # Another build prepared it meanwhile; keep theirs if it is right.
                if state(kind, final, ident) != "ok":
                    raise
        done.append(rel)
    return done


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cache", type=Path)
    ap.add_argument("--plan", action="store_true", help="print what is missing; fetch nothing")
    a = ap.parse_args()
    try:
        items = inputs()
        got = prepare(a.cache, items, a.plan)
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        sys.exit(f"notices-inputs: {e}")
    if a.plan:
        print("\n".join(f"missing {r}" for r in got) or "every notice input is prepared")
    else:
        print(f"notice inputs: {len(items)} ready ({len(got)} prepared now)")


if __name__ == "__main__":
    main()

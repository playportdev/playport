#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""pp sync: move Playport's pins to a Madeira commit, or hold with a report.

  pp sync <madeira-sha> [--dry-run] [--push] [--rerun] [--device-wait S]

Stages (docs/UPSTREAM-SYNC.md has why they are these):

  resolve  fetch Madeira and read its gitlinks for wine, FEX and dxmt
           (research/dxmt before Madeira's 79e28f0) and its FEX's
           External/rpmalloc at <madeira-sha>; the gitlinks are
           the component pins, never a fork's branch head. wine is the
           wine-port row, dxmt the dxmt-port row, FEX the fex-port row
           and FEX's rpmalloc the rpmalloc-port row: a move of any of them
           holds, for patches/wine-port, patches/dxmt-port, patches/fex-port or
           patches/rpmalloc-port to be re-ported by hand. wine (WineHQ), dxmt
           (3Shain/dxmt), fex (FEX-Emu/FEX) and rpmalloc (FEX-Emu/rpmalloc)
           keep their own pins. Record
           whether the commit descends from the current pin, any .gitmodules
           change and any licence file changed in a component. A Madeira
           submodule that is no row (madeira-dock) is named in the report: the
           build never checks it out.
  replay   for every patches/<target>/series but those on pins no Madeira
           commit moves (mesa, vkd3d-proton, gbe, idevice), a fresh sparse checkout (a
           `git clone --shared` of the mirror) at the new component commit (for wine, dxmt and fex, with patches/wine-port
           (and for wine's own series patches/wine-valve), patches/dxmt-port or
           patches/fex-port applied first) and `git am -3` patch by patch; each patch is
           clean, merged-3way, already-upstream or conflict.
  build    pp build in a candidate checkout (a `git clone --shared` of this
           repository, <sha8>/playport) on branch sync/<sha8>, with the new
           pins.lock and gitlink, and its own run and out directories
           (PLAYPORT_RUN, PLAYPORT_OUT) under <sha8>/. The branch is fetched
           back into this repository; the clone is deleted when the run ends.
  static   pp names and `swift test` for each of checks.SWIFT_PACKAGES
           (verify-ipa.py already ran as the build's last stage).
  device   under the device lock (phonelib: $PLAYPORT_DEVICE_LOCK, default
           .work/device.lock, with its holder recorded for
           pp phone status): the candidate's IPA installed in place
           (pp install --no-build), then Hollow Knight played through the UI
           to 10 s after its first frame (pp ui --play app-367520).
  decide   merge only when every patch is clean or already-upstream, every gate
           passes and no .gitmodules or licence file changed; otherwise hold.

Every run also fetches Valve's branch (the wine-valve row's, bleeding-edge) and,
when it has commits past the wine-valve pin, lists them oldest first in
wine-valve-new.tsv (commit, date, subject, files) in the run directory and in
$PLAYPORT_BUILD/sync, and names that file in the report and the last line.
It is reported only and never holds: the wine-valve row moves by hand
(decision 0018). The sync-level file is removed once nothing is new.

--dry-run stops after replay and changes nothing but the sync area. A merge
fast-forwards the local main (its checkout too when it is checked out and
clean). --push also pushes the result: main on a merge (fast-forward
only), the sync/<sha8> branch on a hold that has one. --rerun ignores a recorded result for this
commit; without it a second run reprints the recorded result (a run paused for
the device resumes at the device gates).

Everything is kept under $PLAYPORT_BUILD/sync (default .work/sync):
mirrors/ (the fetched repositories), madeira-pin.git (whose main is the pinned
Madeira commit, for a poller to watch) and <sha8>/ per commit, with
REPORT.md and result.json.

Exit status: 0 merged or no-op (a dry run: replay allows a merge); 10 hold for
review; 11 upstream-broken (the build failed with no conflict and no merged-3way
patch: hold at the current pin, retry on the next Madeira push); 12 paused (built, awaiting the device or the device lock); 1 the tool
itself failed; 2 usage.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import checks  # noqa: E402
import phonelib  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD = os.environ.get("PLAYPORT_BUILD") or os.path.join(REPO, ".work")
SYNC = os.path.join(BUILD, "sync")
MIRRORS = os.path.join(SYNC, "mirrors")
PIN_MIRROR = os.path.join(SYNC, "madeira-pin.git")
SWIFT = os.environ.get("SWIFT", "/usr/lib/swift/bin/swift")

EXIT = {"merged": 0, "no-op": 0, "replay-clean": 0, "hold": 10, "upstream-broken": 11, "paused": 12}

# Components: the repository each is fetched from comes from pins.lock; the
# gitlink is where Madeira (or FEX, for rpmalloc) records it.
# wine, dxmt, fex and rpmalloc are not Madeira gitlinks: they are upstream
# commits pinned on their own (decisions 0007, 0008, 0013), and the *-port rows are the
# Madeira gitlinks their port series were rebased from. rpmalloc is also the
# External/rpmalloc gitlink of the fex pin.
GITLINKS = {"wine-port": ("madeira", "wine"), "fex-port": ("madeira", "FEX"), "dxmt-port": ("madeira", "dxmt"),
            "rpmalloc-port": ("fex-port", "External/rpmalloc"), "rpmalloc": ("fex", "External/rpmalloc")}
# A row whose gitlink moved: the first of these paths that is a gitlink at a
# commit is the row's there (Madeira's 79e28f0 moved research/dxmt to dxmt).
GITLINK_PATHS = {"dxmt-port": ("dxmt", "research/dxmt")}
COMPONENTS = ["madeira", "wine", "wine-port", "fex", "fex-port", "dxmt", "dxmt-port", "rpmalloc", "rpmalloc-port"]
# The rows whose move holds for a hand re-port of patches/<row> (they are never moved by this tool).
PORT_ROWS = ["wine-port", "fex-port", "dxmt-port", "rpmalloc-port"]
# Which component each patches/<target> series applies to.
TARGET_COMPONENT = {"madeira-unix": "madeira", "madeira-winios": "madeira", "wine-port": "wine", "wine-valve": "wine",
                    "wine-unix": "wine", "wine-pe": "wine", "fex-port": "fex", "fex": "fex", "dxmt-port": "dxmt",
                    "dxmt": "dxmt", "rpmalloc-port": "rpmalloc", "rpmalloc": "rpmalloc"}
# Series on pins no Madeira commit moves (their own upstreams, outside COMPONENTS):
# a sync does not replay them.
NOT_REPLAYED = {"mesa", "vkd3d-proton", "gbe", "idevice"}
# Series applied under a target's own, in order, as build/stages/unix.sh,
# build/stages/wine-pe.sh, build/stages/dxmt-patched.sh and build/stages/fex.sh do.
BELOW = {"wine-valve": ["wine-port"], "wine-unix": ["wine-port", "wine-valve"], "wine-pe": ["wine-port", "wine-valve"],
         "dxmt": ["dxmt-port"], "fex": ["fex-port"], "rpmalloc": ["rpmalloc-port"]}
# Madeira is small and needs full history for the candidate's submodule; the
# forks are fetched without blobs, which are read on demand.
PARTIAL = {"wine-valve", "wine", "wine-port", "fex", "fex-port", "dxmt", "dxmt-port", "rpmalloc", "rpmalloc-port"}
LICENCE_RE = re.compile(r"(^|/)(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE)[^/]*$", re.I)
BOT = {"GIT_COMMITTER_NAME": "upstream-sync", "GIT_COMMITTER_EMAIL": "upstream-sync@localhost"}


class Fail(Exception):
    """The tool itself could not do its job (exit 1)."""


def log(msg):
    print(f"{time.strftime('%H:%M:%S')}  {msg}", flush=True)


def sh(args, cwd=None, check=True, env=None, timeout=None, stdout=None):
    """Run a command; return (status, output). Output is stdout+stderr as text."""
    e = dict(os.environ, **(env or {}))
    try:
        r = subprocess.run(args, cwd=cwd, env=e, timeout=timeout, text=True, errors="replace",
                           stdout=stdout or subprocess.PIPE, stderr=subprocess.STDOUT)
    except subprocess.TimeoutExpired:
        if check:
            raise Fail(f"timed out after {timeout} s: {' '.join(args)}")
        return 124, f"timed out after {timeout} s"
    out = r.stdout if stdout is None else ""
    if check and r.returncode != 0:
        raise Fail(f"{' '.join(args)} (in {cwd or os.getcwd()}) exited {r.returncode}:\n{(out or '').strip()[-2000:]}")
    return r.returncode, out or ""


def git(repo, *args, **kw):
    return sh(["git", "-C", repo, *args], **kw)[1].strip()


def git_ok(repo, *args, **kw):
    return sh(["git", "-C", repo, *args], check=False, **kw)[0] == 0


# --- pins.lock --------------------------------------------------------------

def read_pins(text):
    pins = {}
    for line in text.splitlines():
        f = line.split()
        if f and not line.startswith("#") and len(f) >= 4:
            pins[f[0]] = {"commit": f[1], "url": f[2], "branch": f[3]}
    return pins


def rewrite_pins(text, new):
    """pins.lock with the commit (and, where it changed, branch) columns replaced."""
    out = []
    for line in text.splitlines(keepends=True):
        f = line.split()
        if f and not line.startswith("#") and f[0] in new:
            n = new[f[0]]
            line = line.replace(f[1], n["commit"], 1)
            if n.get("branch") and n["branch"] != f[3]:
                line = re.sub(r"(\s)" + re.escape(f[3]) + r"(\s*)$", r"\g<1>" + n["branch"] + r"\g<2>", line)
        out.append(line)
    return "".join(out)


def series(repo, target):
    d = os.path.join(repo, "patches", target)
    with open(os.path.join(d, "series")) as f:
        return [os.path.join(d, l.strip()) for l in f if l.strip() and not l.startswith("#")]


def patch_paths(patch):
    paths = set()
    with open(patch, errors="replace") as f:
        for line in f:
            m = re.match(r"^diff --git a/(\S+) b/(\S+)$", line)
            if m:
                paths.update(m.groups())
    return sorted(paths)


def patch_subject(patch):
    with open(patch, errors="replace") as f:
        for line in f:
            if line.startswith("Subject:"):
                return re.sub(r"^Subject:\s*(\[PATCH[^]]*\]\s*)?", "", line).strip()
    return os.path.basename(patch)


# --- mirrors ----------------------------------------------------------------

def mirror(comp, url, branch):
    """The bare mirror of one component, created on first use."""
    path = os.path.join(MIRRORS, comp + ".git")
    if os.path.isdir(path) and git(path, "config", "remote.origin.url") != url:
        git(path, "config", "remote.origin.url", url)
    if not os.path.isdir(path):
        log(f"mirror {comp}: cloning {url}")
        os.makedirs(MIRRORS, exist_ok=True)
        args = ["git", "clone", "--bare", "--no-tags", "--quiet"]
        if comp in PARTIAL:
            args += ["--filter=blob:none"]
        if branch != "-":
            args += ["--single-branch", "--branch", branch]
        sh(args + [url, path + ".tmp"], timeout=3600)
        git(path + ".tmp", "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        os.rename(path + ".tmp", path)
    return path


def fetch(path, branch, shas):
    """Fetch the branch head and every commit in shas that the mirror lacks."""
    if branch != "-":
        sh(["git", "-C", path, "fetch", "--quiet", "--no-tags", "origin",
            f"+refs/heads/{branch}:refs/remotes/origin/{branch}"], timeout=3600)
    for sha in shas:
        if not git_ok(path, "cat-file", "-e", sha + "^{commit}"):
            sh(["git", "-C", path, "fetch", "--quiet", "--no-tags", "origin", f"{sha}:refs/sync/{sha}"],
               check=False, timeout=3600)
        if not git_ok(path, "cat-file", "-e", sha + "^{commit}"):
            raise Fail(f"{path}: the remote has no commit {sha} (force-pushed away, or not a commit)")
        git(path, "update-ref", f"refs/sync/{sha}", sha)


def gitlink(repo, commit, path):
    out = git(repo, "ls-tree", commit, "--", path)
    f = out.split()
    if len(f) < 3 or f[1] != "commit":
        raise Fail(f"{repo} has no gitlink {path} at {commit}")
    return f[2]


def gitmodules(repo, commit):
    """{submodule path: {key: value}} from commit:.gitmodules."""
    st, out = sh(["git", "-C", repo, "config", "--blob", f"{commit}:.gitmodules", "--list"], check=False)
    subs = {}
    for line in out.splitlines() if st == 0 else []:
        m = re.match(r"^submodule\.(.+)\.([a-z]+)=(.*)$", line)
        if m:
            subs.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
    return {v.get("path", k): v for k, v in subs.items()}


def link_path(repo, commit, comp):
    """The path of the GITLINKS row comp at commit (GITLINK_PATHS for a row that moved)."""
    paths = GITLINK_PATHS.get(comp, (GITLINKS[comp][1],))
    for path in paths:
        f = git(repo, "ls-tree", commit, "--", path).split()
        if len(f) >= 3 and f[1] == "commit":
            return path
    raise Fail(f"{repo} has no gitlink {' or '.join(paths)} ({comp}) at {commit}")


# --- resolve ----------------------------------------------------------------

def resolve(new_madeira, pins):
    res = {"old": {}, "new": {}, "mirrors": {}, "flags": [], "info": []}
    old = {c: pins[c]["commit"] for c in COMPONENTS}
    m = mirror("madeira", pins["madeira"]["url"], pins["madeira"]["branch"])
    fetch(m, pins["madeira"]["branch"], [old["madeira"], new_madeira])
    new_madeira = git(m, "rev-parse", new_madeira + "^{commit}")
    res["mirrors"]["madeira"] = m
    new = {"madeira": new_madeira}
    for comp in ("wine-port", "fex-port", "dxmt-port"):
        new[comp] = gitlink(m, new_madeira, link_path(m, new_madeira, comp))
        mm = mirror(comp, pins[comp]["url"], pins[comp]["branch"])
        fetch(mm, pins[comp]["branch"], [old[comp], new[comp]])
        res["mirrors"][comp] = mm
    new["rpmalloc-port"] = gitlink(res["mirrors"]["fex-port"], new["fex-port"], GITLINKS["rpmalloc-port"][1])
    mm = mirror("rpmalloc-port", pins["rpmalloc-port"]["url"], pins["rpmalloc-port"]["branch"])
    fetch(mm, pins["rpmalloc-port"]["branch"], [old["rpmalloc-port"], new["rpmalloc-port"]])
    res["mirrors"]["rpmalloc-port"] = mm
    for comp in ("wine", "dxmt", "fex", "rpmalloc"):
        new[comp] = old[comp]
        mm = mirror(comp, pins[comp]["url"], pins[comp]["branch"])
        fetch(mm, pins[comp]["branch"], [old[comp]])
        res["mirrors"][comp] = mm
    res["old"], res["new"] = old, new

    # The pins must be Madeira's own gitlinks at the old pin, or the base is inconsistent.
    for comp, (parent, _) in GITLINKS.items():
        path = link_path(res["mirrors"][parent], old[parent], comp)
        pinned = gitlink(res["mirrors"][parent], old[parent], path)
        if pinned != old[comp]:
            raise Fail(f"pins.lock {comp} {old[comp]} is not the {path} gitlink {pinned} of the {parent} pin")
    for row in PORT_ROWS:
        if new[row] != old[row]:
            base = row[:-len("-port")]
            res["flags"].append({"kind": f"{row}-moved", "hold": True,
                                 "detail": f"Madeira's {GITLINKS[row][1]} ({row}) moved {old[row][:12]} -> "
                                           f"{new[row][:12]}: re-port patches/{row} onto the {base} pin by hand "
                                           f"and move {row} in pins.lock with it (docs/UPSTREAM-SYNC.md, "
                                           "\"What moves\")"})

    ancestry = {}
    for comp in COMPONENTS:
        mm = res["mirrors"][comp]
        if old[comp] == new[comp]:
            ancestry[comp] = "unchanged"
        elif git_ok(mm, "merge-base", "--is-ancestor", old[comp], new[comp]):
            ancestry[comp] = "fast-forward, %s commits" % git(mm, "rev-list", "--count", f"{old[comp]}..{new[comp]}")
        else:
            base = git(mm, "merge-base", old[comp], new[comp], check=False) or "none"
            ancestry[comp] = f"NOT a descendant of the pin (merge base {base[:12]})"
            res["flags"].append({"kind": "non-fast-forward", "hold": False,
                                 "detail": f"{comp} {new[comp][:12]} does not descend from the pin {old[comp][:12]} "
                                           f"(a force-push upstream); merge base {base[:12]}"})
    res["ancestry"] = ancestry

    # .gitmodules: a branch or URL switch changes what, and under which licence, Playport builds.
    for comp, parent_commit in (("madeira", "madeira"), ("fex-port", "fex-port")):
        mm = res["mirrors"][comp]
        a, b = gitmodules(mm, old[parent_commit]), gitmodules(mm, new[parent_commit])
        for path in sorted(set(a) | set(b)):
            for key in sorted(set(a.get(path, {})) | set(b.get(path, {}))):
                va, vb = a.get(path, {}).get(key), b.get(path, {}).get(key)
                if va != vb:
                    res["flags"].append({"kind": "gitmodules", "hold": True,
                                         "detail": f"{comp} .gitmodules {path} {key}: {va} -> {vb}"})
    rows = {comp: link_path(m, new_madeira, comp) for comp in ("wine-port", "fex-port", "dxmt-port")}
    for path in sorted(set(gitmodules(m, new_madeira)) - set(rows.values())):
        res["info"].append(f"Madeira submodule {path} is no pins.lock row: the build does not use it "
                           "and the sources stage does not check it out")
    new_branches = {}
    for comp in ("wine-port", "fex-port", "dxmt-port"):
        b = gitmodules(m, new_madeira).get(rows[comp], {}).get("branch")
        if b:
            new_branches[comp] = b
    res["new_branches"] = new_branches

    for comp in COMPONENTS:
        if old[comp] == new[comp]:
            continue
        names = git(res["mirrors"][comp], "diff", "--name-only", "--no-renames", old[comp], new[comp]).splitlines()
        lic = [n for n in names if LICENCE_RE.search(n)]
        if lic:
            res["flags"].append({"kind": "licence", "hold": True,
                                 "detail": f"{comp}: licence files changed: {', '.join(lic[:20])}"})

    # For information only: a fork branch that has moved past Madeira's gitlink.
    for comp in ("wine-port", "fex-port", "dxmt-port"):
        mm, br = res["mirrors"][comp], pins[comp]["branch"]
        head = git(mm, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{br}", check=False)
        if head and head != new[comp]:
            if git_ok(mm, "merge-base", "--is-ancestor", new[comp], head):
                n = git(mm, "rev-list", "--count", f"{new[comp]}..{head}")
                res["info"].append(f"{comp} branch {br} is {n} commits past Madeira's gitlink (reported only)")
            else:
                res["info"].append(f"{comp} branch {br} head {head[:12]} is not a descendant of Madeira's gitlink")
    return res


# --- Valve's branch -----------------------------------------------------------

VALVE_ROW = "wine-valve"


def valve_news(pins):
    """Valve's commits on the wine-valve row's branch that the pin does not have.

    {"pin", "head", "branch", "rebased", "commits": [{commit, date, subject, files}]}, or None
    when pins.lock has no wine-valve row. When the branch was rewritten (Valve rebases
    it), a commit is new when its subject is not among the pin's since the merge base."""
    if VALVE_ROW not in pins:
        return None
    pin, url, branch = pins[VALVE_ROW]["commit"], pins[VALVE_ROW]["url"], pins[VALVE_ROW]["branch"]
    mm = mirror(VALVE_ROW, url, branch)
    fetch(mm, branch, [pin])
    head = git(mm, "rev-parse", f"refs/remotes/origin/{branch}")
    out = {"pin": pin, "head": head, "branch": branch, "url": url, "rebased": False, "commits": []}
    if head == pin:
        return out
    if git_ok(mm, "merge-base", "--is-ancestor", pin, head):
        rng, known = f"{pin}..{head}", set()
    else:
        base = git(mm, "merge-base", pin, head, check=False)
        if not base:
            raise Fail(f"{VALVE_ROW}: {branch} head {head[:12]} shares no history with the pin {pin[:12]}")
        out["rebased"] = True
        rng = f"{base}..{head}"
        known = set(git(mm, "log", "--no-merges", "--format=%s", f"{base}..{pin}").splitlines())
    raw = git(mm, "log", "--reverse", "--no-merges", "--name-only", "--format=@@@%H%x09%as%x09%s", rng)
    cur = None
    for line in raw.splitlines():
        if line.startswith("@@@"):
            h, d, s = line[3:].split("\t", 2)
            cur = None if s in known else {"commit": h, "date": d, "subject": s, "files": []}
            if cur:
                out["commits"].append(cur)
        elif line.strip() and cur:
            cur["files"].append(line.strip())
    return out


def write_valve_news(valve, rundir):
    """wine-valve-new.tsv in the run directory and in the sync area; the path, or None."""
    stable = os.path.join(SYNC, "wine-valve-new.tsv")
    if not valve or valve.get("error"):
        return None
    if not valve["commits"]:
        if os.path.exists(stable):
            os.remove(stable)
        return None
    how = ("rewritten since the pin: new by subject, which lists a new WineHQ base's commits too"
           if valve["rebased"] else "descends from the pin")
    text = (f"# commit\tdate\tsubject\tfiles  ({valve['url']} {valve['branch']} "
            f"{valve['pin'][:12]}..{valve['head'][:12]}, {how}; oldest first. Sort them by decision 0018's "
            "rules, pick the wanted ones onto patches/wine-valve and move the wine-valve row)\n")
    text += "".join(f"{c['commit'][:11]}\t{c['date']}\t{c['subject']}\t{','.join(c['files'])}\n"
                    for c in valve["commits"])
    for path in (os.path.join(rundir, "wine-valve-new.tsv"), stable):
        with open(path, "w") as f:
            f.write(text)
    return stable


def valve_notice(valve, path):
    if valve is None:
        return None
    if valve.get("error"):
        return f"wine-valve: could not check Valve's branch: {valve['error']} (reported only)"
    if not valve["commits"]:
        return f"wine-valve: {valve['branch']} has nothing past the pin {valve['pin'][:12]}"
    return (f"wine-valve: {len(valve['commits'])} new Valve commit(s) on {valve['branch']} past the pin "
            f"{valve['pin'][:12]} (head {valve['head'][:12]}" + (", branch rewritten" if valve["rebased"] else "") +
            f"), listed in {path}: review them and move the wine-valve row by hand (decision 0018; reported only)")


# --- replay -----------------------------------------------------------------

def conflict_blocks(path):
    """[(first, last, text)] of each conflict block, as line numbers of the HEAD side."""
    blocks, n, state, cur = [], 0, None, None
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return blocks
    for line in lines:
        if line.startswith("<<<<<<< "):
            state, cur = "ours", {"first": n + 1, "count": 0, "text": [line]}
            continue
        if state and line.startswith("||||||| "):
            state = "base"
        elif state and line == "=======":
            state = "theirs"
        elif state and line.startswith(">>>>>>> "):
            cur["text"].append(line)
            first = cur["first"]
            last = max(first, first + cur["count"] - 1)
            blocks.append((max(1, first - 1), last + 1, "\n".join(cur["text"][:80])))
            state = None
            continue
        if state:
            cur["text"].append(line)
            if state == "ours":
                cur["count"] += 1
                n += 1
        else:
            n += 1
    return blocks


def upstream_commits(wt, since, path, first=None, last=None):
    fmt = "--format=%h %ad %s"
    if first is not None:
        st, out = sh(["git", "-C", wt, "log", "--no-patch", fmt, "--date=short", f"{since}..HEAD",
                      "-L", f"{first},{last}:{path}"], check=False, timeout=900)
        if st == 0:
            return [l for l in out.splitlines() if l.strip()]
    st, out = sh(["git", "-C", wt, "log", fmt, "--date=short", f"{since}..HEAD", "--", path],
                 check=False, timeout=900)
    return [l for l in out.splitlines() if l.strip()]


def superseded_by(mm, wt, since, new, patch, paths):
    """The first commit in since..new at which the patch's reverse applies."""
    commits = git(mm, "rev-list", "--reverse", f"{since}..{new}", "--", *paths).splitlines()
    if not commits:
        return None
    idx = wt + ".index"

    def reverse_applies(c):
        env = {"GIT_INDEX_FILE": idx}
        sh(["git", "-C", wt, "read-tree", c], env=env)
        return sh(["git", "-C", wt, "apply", "--cached", "--check", "-R", patch], env=env, check=False)[0] == 0

    lo, hi = 0, len(commits) - 1
    if not reverse_applies(commits[hi]):
        found = commits[hi]  # empty after a 3-way merge: the last commit touching its files is the best lead
    else:
        while lo < hi:
            mid = (lo + hi) // 2
            if reverse_applies(commits[mid]):
                hi = mid
            else:
                lo = mid + 1
        found = commits[lo]
    if os.path.exists(idx):
        os.remove(idx)
    return f"{found[:12]} " + git(mm, "log", "-1", "--format=%s", found)


def sparse_checkout(mm, wt, commit, paths):
    """A clone of mirror mm at commit holding only paths (a full wine checkout is ~30k files).
    --shared borrows the mirror's objects, so every commit of the mirror is there."""
    if os.path.exists(wt):
        shutil.rmtree(wt)
    git(mm, "clone", "--quiet", "--shared", "--no-checkout", mm, wt)
    git(wt, "sparse-checkout", "set", "--no-cone", *["/" + p for p in paths])
    git(wt, "checkout", "--quiet", "--detach", commit)
    return wt


def replay_target(target, comp, res, rundir, patches_repo):
    mm = res["mirrors"][comp]
    old, new = res["old"][comp], res["new"][comp]
    since = git(mm, "merge-base", old, new, check=False) or old
    below = [p for t in BELOW.get(target, []) for p in series(patches_repo, t)]
    patches = series(patches_repo, target)
    paths = sorted({p for patch in below + patches for p in patch_paths(patch)})
    env = dict(BOT, GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
    # Preimage pass: the series on its own pin, where it must apply as it is.
    # A 3-way fallback finds each patch's preimage by its blob hash, and the
    # preimage of a later patch is a blob only this pass creates.
    pre = sparse_checkout(mm, os.path.join(rundir, "replay", target + ".pin"), old, paths)
    st, msg = sh(["git", "-C", pre, "am", "--quiet", *below, *patches], env=env, check=False)
    if st != 0:
        raise Fail(f"patches/{target} does not apply to its own pin {old[:12]}:\n{msg.strip()[-1500:]}")
    shutil.rmtree(pre)
    wt = sparse_checkout(mm, os.path.join(rundir, "replay", target), new, paths)
    if below:
        st, msg = sh(["git", "-C", wt, "am", "--quiet", *below], env=env, check=False)
        if st != 0:
            raise Fail(f"patches/{' '.join(BELOW[target])} under patches/{target} does not apply to "
                       f"{new[:12]}:\n{msg.strip()[-1500:]}")
    out = []
    for patch in patches:
        name = os.path.basename(patch)
        rec = {"patch": name, "subject": patch_subject(patch)}
        head = git(wt, "rev-parse", "HEAD")
        if git_ok(wt, "apply", "--check", patch):
            st, msg = sh(["git", "-C", wt, "am", "-3", "--quiet", patch], env=env, check=False)
            rec["class"] = "clean" if st == 0 else None
        elif git_ok(wt, "apply", "--check", "-R", patch):
            rec["class"] = "already-upstream"
        else:
            st, msg = sh(["git", "-C", wt, "-c", "merge.conflictStyle=diff3", "am", "-3", "--quiet", "--empty=drop",
                          patch], env=env, check=False)
            if st == 0:
                rec["class"] = "merged-3way" if git(wt, "rev-parse", "HEAD") != head else "already-upstream"
            else:
                unmerged = git(wt, "diff", "--name-only", "--diff-filter=U").splitlines()
                if not unmerged and git_ok(wt, "diff", "--cached", "--quiet", "HEAD"):
                    sh(["git", "-C", wt, "am", "--skip"], env=env, check=False)
                    rec["class"] = "already-upstream"
                else:
                    rec["class"] = "conflict"
                    rec["am"] = msg.strip()[-3000:]
                    rec["files"] = []
                    for f in unmerged or patch_paths(patch):
                        blocks = conflict_blocks(os.path.join(wt, f))
                        entry = {"file": f, "hunks": []}
                        for first, last, text in blocks:
                            entry["hunks"].append({"lines": f"{first},{last}", "text": text,
                                                   "upstream": upstream_commits(wt, since, f, first, last)})
                        if not blocks:
                            entry["upstream"] = upstream_commits(wt, since, f)
                        rec["files"].append(entry)
                    sh(["git", "-C", wt, "am", "--abort"], check=False)
                    git(wt, "reset", "--hard", "--quiet", head)
        if rec["class"] is None:  # apply --check passed but am did not: never expected
            sh(["git", "-C", wt, "am", "--abort"], check=False)
            raise Fail(f"{target}/{name}: git apply --check passes but git am fails")
        if rec["class"] == "already-upstream":
            rec["superseded_by"] = superseded_by(mm, wt, since, new, patch, patch_paths(patch)) \
                if old != new else None
        if rec["class"] in ("clean", "merged-3way"):
            rec["commit"] = git(wt, "rev-parse", "HEAD")
        out.append(rec)
        log(f"  {target}/{name}: {rec['class']}" +
            (f" (superseded by {rec['superseded_by']})" if rec.get("superseded_by") else ""))
    return {"target": target, "component": comp, "base": new, "tree": wt, "patches": out}


def refreshed_patch(wt, commit):
    return sh(["git", "-C", wt, "-c", "core.abbrev=7", "format-patch", "-1", "--zero-commit", "--no-signature",
               "--stdout", commit])[1]


def remove_trees(res, replay):
    for r in replay:
        tree = r.get("tree")
        if tree and os.path.exists(tree):
            shutil.rmtree(tree)


# --- candidate, build, static gates ------------------------------------------

def make_candidate(rundir, sha8, res, replay, base):
    cand = os.path.join(rundir, "playport")
    if os.path.exists(cand):
        shutil.rmtree(cand)
    # A clone that borrows this repository's objects; its branch is fetched back below.
    git(REPO, "clone", "--quiet", "--shared", "--no-checkout", REPO, cand)
    git(cand, "checkout", "--quiet", "-B", f"sync/{sha8}", base)
    new = {c: {"commit": res["new"][c], "branch": res["new_branches"].get(c)} for c in COMPONENTS}
    lock = os.path.join(cand, "pins.lock")
    text = open(lock).read()
    open(lock, "w").write(rewrite_pins(text, new))
    git(cand, "update-index", "--cacheinfo", f"160000,{res['new']['madeira']},upstream/madeira")
    body = []
    for r in replay:
        sdir = os.path.join(cand, "patches", r["target"])
        drop = [p for p in r["patches"] if p["class"] == "already-upstream"]
        for p in r["patches"]:
            if p["class"] == "merged-3way":
                open(os.path.join(sdir, p["patch"]), "w").write(refreshed_patch(r["tree"], p["commit"]))
                body.append(f"Refresh patches/{r['target']}/{p['patch']}: applied only through a 3-way merge.")
        if drop:
            lines = open(os.path.join(sdir, "series")).read().splitlines(keepends=True)
            names = {p["patch"] for p in drop}
            open(os.path.join(sdir, "series"), "w").write("".join(l for l in lines if l.strip() not in names))
            for p in drop:
                os.remove(os.path.join(sdir, p["patch"]))
                body.append(f"Drop patches/{r['target']}/{p['patch']}: already upstream, superseded by "
                            f"{r['component']} {p.get('superseded_by') or '(no single commit found)'}.")
    git(cand, "add", "-A", "pins.lock", "patches")
    pins = "\n".join(f"{c}: {res['old'][c][:12]} -> {res['new'][c][:12]}" for c in COMPONENTS
                     if res["old"][c] != res["new"][c])
    msg = f"Move the Madeira pin to {res['new']['madeira'][:12]}\n\nMade by pp sync.\n\n{pins}\n"
    if body:
        msg += "\n" + "\n".join(body) + "\n"
    git(cand, "commit", "--quiet", "-m", msg)
    fetch_branch(cand, sha8)
    return cand


def fetch_branch(cand, sha8):
    """The candidate's branch into this repository, where it outlives the clone."""
    git(REPO, "fetch", "--quiet", cand, f"+refs/heads/sync/{sha8}:refs/heads/sync/{sha8}")


def init_submodule(cand, res):
    sh(["git", "-C", cand, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--quiet",
        "--reference", res["mirrors"]["madeira"], "upstream/madeira"], timeout=3600)


def run_build(cand, rundir):
    logf = os.path.join(rundir, "logs", "build.log")
    log(f"build: pp build (log {logf})")
    run = os.path.join(rundir, "build-run")
    # This checkout's build area: the machine's inputs.local, toolchains and caches (the
    # clone's own .work has none), with the candidate's own run and out directories.
    env = dict(os.environ, PLAYPORT_BUILD=BUILD, PLAYPORT_RUN=run, PLAYPORT_OUT=os.path.join(rundir, "build-out"))
    with open(logf, "w") as f:
        st = subprocess.run([os.path.join(cand, "build", "pipeline")], cwd=cand, stdout=f,
                            stderr=subprocess.STDOUT, env=env).returncode
    text = open(logf, errors="replace").read()
    b = {"ok": st == 0, "log": logf}
    m = re.search(r"^\S+\s+IPA (\S+)$", text, re.M)
    s = re.search(r"^\S+\s+sha256 ([0-9a-f]{64})$", text, re.M)
    if m and s:
        b["ipa"], b["sha256"] = m.group(1), s.group(1)
    if st != 0:
        fl = re.search(r"FAILED: .*\(log: (\S+)\)", text)
        b["stage_log"] = fl.group(1) if fl else logf
        b["stage"] = os.path.splitext(os.path.basename(b["stage_log"]))[0]
        b["first_error"] = first_error(b["stage_log"]) or (fl.group(0) if fl else text.strip()[-500:])
    # Keep the run's logs and drop its trees (~12 GB); the IPA and its logs are in build-out.
    kept = os.path.join(rundir, "logs", "build")
    if os.path.isdir(os.path.join(run, "logs")):
        shutil.copytree(os.path.join(run, "logs"), kept, dirs_exist_ok=True)
    if b.get("stage_log", "").startswith(os.path.join(run, "logs") + os.sep):
        b["stage_log"] = os.path.join(kept, os.path.relpath(b["stage_log"], os.path.join(run, "logs")))
    shutil.rmtree(run, ignore_errors=True)
    return b


def first_error(path):
    try:
        for line in open(path, errors="replace"):
            if re.search(r"\berror\b|\bError\b|FAILED|fatal:", line) and "-Werror" not in line:
                return line.strip()[:500]
    except OSError:
        pass
    return None


def static_gates(cand, rundir):
    gates = {}
    st, out = sh([os.path.join(cand, "pp"), "names"], cwd=cand, check=False)
    gates["check-names"] = {"ok": st == 0, "detail": out.strip().splitlines()[-1] if out.strip() else ""}
    for d in checks.SWIFT_PACKAGES:
        name = "swift-test " + os.path.basename(d)
        logf = os.path.join(rundir, "logs", name.replace(" ", "-") + ".log")
        with open(logf, "w") as f:
            st = subprocess.run([SWIFT, "test", "--build-system", "native", "--scratch-path",
                                 os.path.join(rundir, "swift", os.path.basename(d))],
                                cwd=os.path.join(cand, d), stdout=f, stderr=subprocess.STDOUT).returncode
        tail = [l for l in open(logf, errors="replace").read().splitlines() if "Executed" in l or "error:" in l]
        gates[name] = {"ok": st == 0, "detail": (tail[-1] if tail else f"exit {st}"), "log": logf}
    return gates


# --- device gates --------------------------------------------------------------

def device_gates(cand, ipa, rundir, wait):
    """(gates, None) or (None, why-paused): the candidate's IPA installed in
    place, then Hollow Knight played through the UI to 10 s after its first
    frame, both with the candidate's own tools under this tool's hold of the
    device lock (phonelib, which records the holder for waiters)."""
    d = os.path.join(rundir, "device")
    os.makedirs(d, exist_ok=True)
    try:
        with phonelib.device_lock(f"pp sync {os.path.basename(rundir)} device gates", wait=wait):
            phone = phonelib.Phone(d)
            if len(phone.devices()) != 1:
                return None, "no phone answered (pymobiledevice3 usbmux list): built, awaiting device"
            try:
                phone.bundle_id()
            except phonelib.PhoneError:
                return None, "the Playport app is not installed on the phone (pp install)"
            # This checkout's build area: its inputs.local, and the phone's lock and install record.
            env = dict(os.environ, PLAYPORT_BUILD=BUILD, PLAYPORT_DEVICE_LOCK_HELD="1")
            gates = {}
            log("device: install in place (pp install --no-build)")
            with open(os.path.join(d, "install.txt"), "w") as f:
                st = subprocess.run([os.path.join(cand, "build", "install"), "--no-build", "--ipa", ipa], cwd=cand,
                                    stdout=f, stderr=subprocess.STDOUT, env=env).returncode
            if st == 3:
                return None, "the phone stopped answering during the install"
            gates["install"] = {"ok": st == 0, "log": os.path.join(d, "install.txt"),
                                "detail": "installed in place" if st == 0 else f"install failed (exit {st})"}
            if st != 0:
                return gates, None
            log("device: Hollow Knight to 10 s after its first frame (pp ui --play app-367520)")
            play = os.path.join(d, "play")
            with open(os.path.join(d, "play-events.jsonl"), "w") as f:
                st = subprocess.run([os.path.join(cand, "pp"), "ui", "--play", "app-367520",
                                     "--until", "first-frame+10", "--shot", "--wait", "900", "--out", play],
                                    cwd=cand, stdout=f, stderr=subprocess.STDOUT, env=env).returncode
            gates["play hollow-knight"] = {"ok": st == 0, "log": play,
                                           "detail": "first frame, running 10 s later" if st == 0 else f"driver exit {st}"}
            if st != 0 and len(phone.devices()) != 1:
                return None, "the phone stopped answering during the play"
            return gates, None
    except phonelib.PhoneError as e:   # the lock stayed held for `wait` seconds
        return None, str(e)


# --- evidence and merge ------------------------------------------------------

def scrub(text):
    text = re.sub(r"XTL-[A-Z0-9]{10}\.", "XTL-TEAMIDXXXX.", text)
    text = re.sub(r"(/var/mobile/Containers/(?:Data|Shared)/[A-Za-z]+/)[0-9A-F-]{36}", r"\1<container>", text)
    text = text.replace(REPO + os.sep, "")
    return text.replace(os.path.expanduser("~"), "~")


def write_evidence(cand, res, replay, result):
    sha8 = res["new"]["madeira"][:8]
    name = f"{datetime.date.today().isoformat()}-madeira-{sha8}"
    rel = f"docs/evidence/{name}"
    edir = os.path.join(cand, rel)
    os.makedirs(edir, exist_ok=True)
    b = result["build"]
    outdir = os.path.dirname(b["ipa"])
    copies = [(os.path.join(outdir, "logs", f), f"build/{f}") for f in ("build.log", "verify.log", "inputs.txt")]
    copies += [(os.path.join(outdir, f), f"build/{f}") for f in ("provenance.txt", "SHA256SUMS")]
    play = os.path.join(result["rundir"], "device", "play")
    copies += [(os.path.join(play, f), f"play/{f}") for f in ("events.jsonl", "timeline.txt")]
    for src, dst in copies:
        if os.path.exists(src):
            os.makedirs(os.path.dirname(os.path.join(edir, dst)), exist_ok=True)
            open(os.path.join(edir, dst), "w").write(scrub(open(src, errors="replace").read()))
    rows = "\n".join(f"| {c} | `{res['old'][c]}` | `{res['new'][c]}` |" for c in COMPONENTS)
    reps = "\n".join(f"| {r['target']} | {p['patch']} | {p['class']}"
                     f"{' (superseded by ' + p['superseded_by'] + ')' if p.get('superseded_by') else ''} |"
                     for r in replay for p in r["patches"])
    gates = "\n".join(f"| {k} | {'pass' if g['ok'] else 'FAIL'} | {g.get('detail', '')} |"
                      for k, g in result["gates"].items())
    open(os.path.join(edir + ".md"), "w").write(f"""# Madeira {sha8}: pins moved by pp sync

**Date:** {datetime.date.today().isoformat()}. **Generated** by `pp sync {res['new']['madeira']}`.
**IPA:** `{os.path.basename(b['ipa'])}`, sha256 `{b['sha256']}`.
**Result:** every patch clean or already upstream, every gate passed; merged.

## Pins

| Component | Old | New |
| --- | --- | --- |
{rows}

Ancestry: {'; '.join(f'{c} {a}' for c, a in res['ancestry'].items())}.

## Replay

| Series | Patch | Result |
| --- | --- | --- |
{reps}

## Gates

| Gate | Result | Detail |
| --- | --- | --- |
{gates}

Build logs: [`build/`]({name}/build/); the device play: [`play/`]({name}/play/).
""")
    hits = []
    for root, _, files in os.walk(edir):
        for f in files:
            text = open(os.path.join(root, f), errors="replace").read()
            hits += [f"{f}: {what}" for what, _ in checks.secret_hits(text)]
    return rel, hits


def ff_main(sha8, push):
    notes = []
    if push:
        st, out = sh(["git", "-C", REPO, "push", "origin", f"sync/{sha8}:main"], check=False, timeout=600)
        if st != 0:
            return False, [f"push to origin main refused (not a fast-forward?): {out.strip()[-500:]}"]
        notes.append("pushed to origin main")
    ref = f"refs/heads/sync/{sha8}"
    old = git(REPO, "rev-parse", "--verify", "--quiet", "refs/heads/main", check=False)
    holder = REPO if git(REPO, "symbolic-ref", "--quiet", "HEAD", check=False) == "refs/heads/main" else None
    st, out = 1, ""
    if not old:
        out = "there is no local main"
    elif not git_ok(REPO, "merge-base", "--is-ancestor", old, ref):
        out = f"main {old[:12]} is not an ancestor of sync/{sha8}"
    elif holder is None:
        st, out = sh(["git", "-C", REPO, "update-ref", "refs/heads/main", ref, old], check=False)
    elif git(holder, "status", "--porcelain", "--untracked-files=no"):
        out = "main is checked out, with uncommitted changes"
    else:
        st, out = sh(["git", "-C", holder, "merge", "--ff-only", "--quiet", ref], check=False)
    if st == 0:
        notes.append("local main fast-forwarded" + (" and checked out" if holder else ""))
    elif not push:
        return False, [f"local main not fast-forwarded: {out.strip()[-500:]}"]
    else:
        notes.append(f"local main left behind origin main: {out.strip()[-500:]}")
    return True, notes


def set_pin_mirror(sha):
    """madeira-pin.git's main is the pinned Madeira commit, for a poller to watch."""
    if not os.path.isdir(PIN_MIRROR):
        sh(["git", "init", "--quiet", "--bare", PIN_MIRROR])
        git(PIN_MIRROR, "remote", "add", "origin", "https://github.com/willfaust/Madeira.git")
    if git(PIN_MIRROR, "rev-parse", "--verify", "--quiet", "refs/heads/main", check=False) == sha:
        return
    # Only commits up to the pin: a newer Madeira commit here would change what the check reports.
    sh(["git", "-C", PIN_MIRROR, "fetch", "--quiet", "--no-tags", os.path.join(MIRRORS, "madeira.git"),
        f"+refs/sync/{sha}:refs/heads/main"])
    git(PIN_MIRROR, "symbolic-ref", "HEAD", "refs/heads/main")


# --- report ------------------------------------------------------------------

def write_report(result, res, replay):
    r = result
    lines = [f"# upstream-sync {r['madeira']}", "",
             f"**Outcome: {r['outcome']}**" + (" (dry run: stopped after replay)" if r["dry_run"] else ""),
             ""]
    lines += [f"- {x}" for x in r["reasons"]] + [""]
    if res:
        lines += ["## Resolve", "", "| Component | Pin | New | Ancestry |", "| --- | --- | --- | --- |"]
        lines += [f"| {c} | `{res['old'][c][:12]}` | `{res['new'][c][:12]}` | {res['ancestry'][c]} |"
                  for c in COMPONENTS]
        lines += [""] + ([f"- {i}" for i in res["info"]] + [""] if res["info"] else [])
    if replay:
        lines += ["## Replay", "", "| Series | Patch | Result |", "| --- | --- | --- |"]
        for t in replay:
            for p in t["patches"]:
                extra = f" (superseded by {p['superseded_by']})" if p.get("superseded_by") else ""
                lines.append(f"| {t['target']} | {p['patch']} | {p['class']}{extra} |")
        lines.append("")
        for t in replay:
            for p in t["patches"]:
                if p["class"] != "conflict":
                    continue
                lines += [f"### Conflict: patches/{t['target']}/{p['patch']}", "", p["subject"], "",
                          "In each hunk the `HEAD` side is upstream, the `|||||||` side the patch's preimage "
                          "and the last side the patch.", ""]
                for f in p["files"]:
                    lines.append(f"`{f['file']}`:")
                    for h in f["hunks"]:
                        lines += ["", f"lines {h['lines']} of the replay tree; upstream commits that touched them:"]
                        lines += [f"- {c}" for c in h["upstream"][:30]] or ["- (none found)"]
                        lines += ["", "```", h["text"], "```"]
                    if f.get("upstream") is not None:
                        lines += ["", "upstream commits touching the file:"] + \
                                 [f"- {c}" for c in f["upstream"][:30]]
                    lines.append("")
                lines += ["`git am` said:", "", "```", p["am"], "```", ""]
    if r.get("build"):
        b = r["build"]
        lines += ["## Build", "", f"- {'ok' if b['ok'] else 'FAILED in stage ' + b.get('stage', '?')}; log `{b['log']}`"]
        if b.get("ipa"):
            lines.append(f"- IPA `{b['ipa']}`, sha256 `{b['sha256']}`")
        if b.get("first_error"):
            lines += ["- first error:", "", "```", b["first_error"], "```"]
        lines.append("")
    if r.get("gates"):
        lines += ["## Gates", "", "| Gate | Result | Detail |", "| --- | --- | --- |"]
        lines += [f"| {k} | {'pass' if g['ok'] else 'FAIL'} | {g.get('detail', '')} |" for k, g in r["gates"].items()]
        lines.append("")
    if r.get("branch"):
        lines += [f"Candidate branch: `{r['branch']}`" + (f" (checkout `{r['candidate']}`)."
                                                            if os.path.isdir(r.get("candidate", "")) else "."), ""]
    if r.get("notes"):
        lines += [f"- {n}" for n in r["notes"]] + [""]
    path = os.path.join(r["rundir"], "REPORT.md")
    open(path, "w").write("\n".join(lines))
    json.dump({"result": r, "resolve": res, "replay": replay}, open(os.path.join(r["rundir"], "result.json"), "w"),
              indent=2)
    return path


# --- main --------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(prog="pp sync", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("sha", help="the Madeira commit to move to (a full or unique abbreviated SHA)")
    p.add_argument("--dry-run", action="store_true", help="stop after replay; change nothing but the sync area")
    p.add_argument("--push", action="store_true", help="push main on a merge, the sync branch on a hold")
    p.add_argument("--rerun", action="store_true", help="ignore a recorded result for this commit")
    p.add_argument("--device-wait", type=int, default=3600, help="seconds to wait for the device lock")
    a = p.parse_args()
    if not re.fullmatch(r"[0-9a-f]{7,40}", a.sha):
        p.error("the Madeira commit must be a hexadecimal SHA")

    os.makedirs(SYNC, exist_ok=True)
    lockf = open(os.path.join(SYNC, "sync.lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("pp sync: another run holds the sync lock; try again later", file=sys.stderr)
        return EXIT["paused"]

    dirty = git(REPO, "status", "--porcelain", "--", "pins.lock", "patches", ".gitmodules")
    if dirty:
        raise Fail(f"pins.lock or patches/ has uncommitted changes:\n{dirty}")
    base = git(REPO, "rev-parse", "HEAD")
    pins_text = git(REPO, "show", "HEAD:pins.lock") + "\n"
    pins = read_pins(pins_text)
    if gitlink(REPO, "HEAD", "upstream/madeira") != pins["madeira"]["commit"]:
        raise Fail("pins.lock madeira is not the upstream/madeira gitlink")
    key = hashlib.sha256((git(REPO, "rev-parse", "HEAD:patches") + git(REPO, "rev-parse", "HEAD:pins.lock"))
                         .encode()).hexdigest()[:16]

    log(f"resolve: Madeira {a.sha}")
    res = resolve(a.sha, pins)
    new = res["new"]["madeira"]
    log("valve: Valve's branch past the wine-valve pin")
    try:
        valve = valve_news(pins)
    except Fail as e:   # reported only: a Valve fetch never stops a Madeira sync
        valve = {"error": str(e).splitlines()[0][:300], "commits": []}
    sha8 = new[:8]
    rundir = os.path.join(SYNC, sha8 + ("-dry-run" if a.dry_run else ""))
    # The watched pin mirror follows the pin of the base, so a hand-landed update is picked up.
    set_pin_mirror(pins["madeira"]["commit"])

    recorded = os.path.join(rundir, "result.json")
    resume = None
    if not a.dry_run and not a.rerun and os.path.exists(recorded):
        prev = json.load(open(recorded))
        pr = prev["result"]
        if pr.get("key") == key and pr["outcome"] != "paused":
            print(open(os.path.join(rundir, "REPORT.md")).read())
            notice = valve_notice(valve, write_valve_news(valve, rundir))
            if notice:
                print(f"pp sync: {notice}")
            print(f"pp sync: {pr['outcome']} {new[:12]} (recorded; report {rundir}/REPORT.md)")
            return EXIT[pr["outcome"]]
        if pr.get("key") == key and pr.get("build", {}).get("ok") and os.path.exists(pr["build"].get("ipa", "")) \
                and os.path.isdir(pr.get("candidate", "")):
            resume = prev
    if resume is None and os.path.isdir(rundir):
        cand = os.path.join(rundir, "playport")
        if os.path.isdir(cand):
            shutil.rmtree(cand)
        shutil.rmtree(rundir)
    os.makedirs(os.path.join(rundir, "logs"), exist_ok=True)

    result = {"madeira": new, "base": base, "key": key, "dry_run": a.dry_run, "rundir": rundir,
              "reasons": [], "notes": [], "gates": {}}
    valve_file = write_valve_news(valve, rundir)
    notice = valve_notice(valve, valve_file)
    if notice:
        result["reasons"].append(notice)
        result["valve"] = {k: v for k, v in valve.items() if k != "commits"} | {"new": len(valve["commits"]),
                                                                              "file": valve_file}

    def finish(outcome, replay):
        result["outcome"] = outcome
        if outcome == "hold" and a.push and result.get("branch"):
            st, out = sh(["git", "-C", REPO, "push", "--force", "origin", result["branch"]],
                         check=False, timeout=600)
            result["notes"].append("pushed branch " + result["branch"] if st == 0 else f"push failed: {out.strip()[-300:]}")
        remove_trees(res, replay)
        if outcome != "paused":
            shutil.rmtree(os.path.join(rundir, "build-out"), ignore_errors=True)
            if result.get("candidate"):
                shutil.rmtree(result["candidate"], ignore_errors=True)
        report = write_report(result, res, replay)
        print(open(report).read())
        print(f"pp sync: {outcome} {new[:12]} (report {report})")
        if valve_file:
            print(f"pp sync: {len(valve['commits'])} new Valve commit(s) past the wine-valve pin: {valve_file}")
        return EXIT[outcome]

    if resume:
        log(f"resume: {sha8} was paused at the device gates; resuming there")
        replay = resume["replay"]
        result.update({k: resume["result"][k] for k in ("build", "candidate", "branch")})
        result["gates"] = {k: v for k, v in resume["result"]["gates"].items() if not k.startswith(("install", "play"))}
        cand = result["candidate"]
    else:
        log("replay")
        replay = [replay_target(t, TARGET_COMPONENT[t], res, rundir, REPO)
                  for t in sorted(os.listdir(os.path.join(REPO, "patches"))) if t in TARGET_COMPONENT]
        unknown = sorted(set(os.listdir(os.path.join(REPO, "patches"))) - set(TARGET_COMPONENT) - NOT_REPLAYED)
        if unknown:
            raise Fail(f"patches/ has series this tool does not know the component of: {unknown}")
        classes = [p["class"] for t in replay for p in t["patches"]]
        holds = [f for f in res["flags"] if f["hold"]]
        conflicts = classes.count("conflict")
        merged3 = [f"{t['target']}/{p['patch']}" for t in replay for p in t["patches"] if p["class"] == "merged-3way"]
        for f in res["flags"]:
            result["reasons"].append(f"{f['kind']}: {f['detail']}" + (" (hold for review)" if f["hold"] else ""))
        if conflicts:
            result["reasons"].append(f"{conflicts} patch(es) conflict: re-port them, then run the tool again")
            return finish("hold", replay)
        if any(f["kind"] in [f"{row}-moved" for row in PORT_ROWS] for f in holds):
            return finish("hold", replay)
        if new == pins["madeira"]["commit"]:
            if merged3 or classes.count("already-upstream"):
                result["reasons"].append("the current pin does not replay cleanly: the committed series is stale")
                return finish("hold", replay)
            result["reasons"].append(f"Madeira {new[:12]} is the current pin: every patch replays clean; nothing to do")
            return finish("no-op", replay)
        if a.dry_run:
            if merged3 or holds:
                result["reasons"].append(f"a real run would hold: {len(merged3)} merged-3way patch(es), "
                                         f"{len(holds)} hold flag(s)")
                return finish("hold", replay)
            result["reasons"].append("replay allows a merge; a real run builds and runs the gates")
            return finish("replay-clean", replay)

        cand = make_candidate(rundir, sha8, res, replay, base)
        result.update({"candidate": cand, "branch": f"sync/{sha8}"})
        init_submodule(cand, res)
        result["build"] = run_build(cand, rundir)
        if not result["build"]["ok"]:
            suspects = f"; suspects, the merged-3way patches: {', '.join(merged3)}" if merged3 else ""
            if result["build"].get("stage") == "verify":
                result["gates"]["verify-ipa"] = {"ok": False, "detail": result["build"]["first_error"]}
                result["reasons"].append("verify-ipa.py failed on the candidate IPA" + suspects)
                return finish("hold", replay)
            if merged3:
                result["reasons"].append(f"the build fails in stage {result['build']['stage']}{suspects}. "
                                         f"First error: {result['build']['first_error']}")
                return finish("hold", replay)
            result["reasons"].append("the build fails with no patch conflict and no merged-3way patch: "
                                     "upstream-broken; hold at the current pin and retry on the next Madeira push. "
                                     f"First error: {result['build']['first_error']}")
            return finish("upstream-broken", replay)
        result["gates"]["verify-ipa"] = {"ok": True, "detail": "passed (build stage verify)"}
        # The build rewrites these when its outputs change; they belong to the pin move.
        git(cand, "add", "app/artifacts.tsv", "build/generated")
        if not git_ok(cand, "diff", "--cached", "--quiet"):
            git(cand, "commit", "--quiet", "-m", f"Record the build outputs of Madeira {new[:12]}")
            fetch_branch(cand, sha8)
        log("static gates")
        result["gates"].update(static_gates(cand, rundir))
        shutil.rmtree(os.path.join(rundir, "swift"), ignore_errors=True)
        if not all(g["ok"] for g in result["gates"].values()):
            result["reasons"].append("a static gate failed: " +
                                     ", ".join(k for k, g in result["gates"].items() if not g["ok"]) +
                                     (f"; suspects, the merged-3way patches: {', '.join(merged3)}" if merged3 else ""))
            return finish("hold", replay)

    gates, paused = device_gates(cand, result["build"]["ipa"], rundir, a.device_wait)
    if paused:
        result["reasons"].append(paused + "; rerun the same command to resume at the device gates")
        return finish("paused", replay)
    result["gates"].update(gates)
    failed = [k for k, g in result["gates"].items() if not g["ok"]]
    merged3 = [f"{t['target']}/{p['patch']}" for t in replay for p in t["patches"] if p["class"] == "merged-3way"]
    if failed:
        result["reasons"].append("gate regression: " + ", ".join(failed) +
                                 (f"; bisect hint, the merged-3way patches: {', '.join(merged3)}" if merged3 else ""))
    if merged3:
        result["reasons"].append("merged-3way patches need review (refreshed on the branch): " + ", ".join(merged3))
    if failed or merged3 or any(f["hold"] for f in res["flags"]):
        return finish("hold", replay)

    rel, hits = write_evidence(cand, res, replay, result)
    if hits:
        result["reasons"].append(f"the evidence record failed the secret scan: {hits}")
        return finish("hold", replay)
    git(cand, "add", "docs/evidence")
    git(cand, "commit", "--quiet", "-m", f"Record the gates of Madeira {new[:12]}\n\nGenerated by pp sync: {rel}.md\n")
    fetch_branch(cand, sha8)
    ok, notes = ff_main(sha8, a.push)
    result["notes"] += notes
    result["evidence"] = rel + ".md"
    if not ok:
        result["reasons"].append("every gate passed, but main could not be fast-forwarded: " + "; ".join(notes))
        return finish("hold", replay)
    set_pin_mirror(new)
    result["reasons"].append(f"every patch clean or already upstream and every gate passed; evidence {rel}.md")
    return finish("merged", replay)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Fail as e:
        print(f"pp sync: failed: {e}", file=sys.stderr)
        sys.exit(1)

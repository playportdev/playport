#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""pp rebase: move one target's patch series onto a new upstream commit, in a scratch clone.

  pp rebase TARGET NEW [--trial] [--fetch]   start a move (or only count its conflicts)
  pp rebase TARGET --continue                after resolving the conflict it stopped at
  pp rebase TARGET --abort                   drop the run (the recorded resolutions stay)
  pp rebase TARGET --write [--pins]          copy a finished run's series into patches/
                                             (--pins: and the target's pins.lock row)

TARGET is a patches/<target> series; the series under it move with it, in the
order the build applies them (tools/sync.py BELOW: fex is patches/fex-port then
patches/fex). The component is the pins.lock row the series applies to
(fex), and NEW a commit, tag or branch of its mirror,
$PLAYPORT_BUILD/cache/<component>.git (build/lib.sh mirror); --fetch fetches the
mirror first (it is fetched anyway when it lacks NEW).

The run is $PLAYPORT_BUILD/rebase/<target>/: tree/ is a `git clone --shared` of
the mirror where the old patched tree (the pin plus each series by `git am -3`)
is built and its commits are cherry-picked onto NEW one by one, with
merge.conflictStyle=zdiff3 and rerere on. Recorded resolutions are kept per
component in $PLAYPORT_BUILD/rebase/rr-cache/<component>, across runs, so a
conflict resolved once is resolved again the same way.

Each patch is clean (git apply takes it as it is), 3-way (applies only through a
merge), rerere (conflicts a recorded resolution settled), resolved (conflicts a
person resolved), upstream (empty on NEW: dropped from the series) or conflict.

--trial counts conflicts without stopping: a conflicting patch is counted once,
then picked again with -X theirs so the patches after it are not counted for the
same cause (resolutions are not recorded). It writes trial-<new12>.tsv
(series, patch, class, files).

Otherwise the run stops at each conflict (exit 10) for a person to resolve in
tree/ (`git add` the files, then --continue). When every patch is picked it
writes, next to the run:
  range-diff.txt  git range-diff OLD..OLD-TIP NEW..NEW-TIP
  flags.txt       each patch the range-diff shows changed that no person
                  resolved (clean, 3-way or rerere): check its hunks against
                  both sides; git can misplace an auto-merged hunk
  patches/<series>/  the series: a clean patch as it is (it still applies),
                  every other re-exported (docs/ARCHITECTURE.md, "Patch
                  series") with its Subject header kept and a `Rebased:` or
                  `Picked:` trailer set to resolved when this move needed a
                  resolution (it stays resolved once it is); the upstream
                  patches are left out
  series.diff     those against patches/
--write copies them into patches/ (uncommitted, for review); --pins also sets
the component's pins.lock row to NEW. Nothing else in the repository changes.

Exit status: 0 done; 10 stopped at a conflict; 1 the tool failed; 2 usage.
"""

import argparse
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync  # noqa: E402
from sync import Fail, git, git_ok, log, sh  # noqa: E402

COMMITTER = {"GIT_COMMITTER_NAME": "pp-rebase", "GIT_COMMITTER_EMAIL": "pp-rebase@localhost"}
TRAILER_RE = re.compile(r"^(Rebased|Picked): (clean|resolved)$", re.M)
# The class of a pick a person resolved in this run: its range-diff change is theirs, not flagged.
RESOLVED = {"resolved"}


def paths():
    repo = os.environ.get("PLAYPORT_REPO") or sync.REPO
    build = os.environ.get("PLAYPORT_BUILD") or os.path.join(repo, ".work")
    return repo, build


def stack(target):
    return sync.BELOW.get(target, []) + [target]


def mirror(build, comp, url, rev, fetch):
    """The build's cache mirror of comp (build/lib.sh mirror): cloned when absent, fetched when asked or lacking rev."""
    mm = os.path.join(build, "cache", comp + ".git")
    if not os.path.isdir(mm):
        log(f"mirror {comp}: cloning {url}")
        os.makedirs(os.path.dirname(mm), exist_ok=True)
        sh(["git", "clone", "-q", "--bare", url, mm], timeout=3600)
    if fetch or not git_ok(mm, "rev-parse", "-q", "--verify", rev + "^{commit}"):
        log(f"mirror {comp}: fetching {url}")
        sh(["git", "-C", mm, "fetch", "-q", url, "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"],
           timeout=3600)
    return mm


def unmerged(tree):
    return git(tree, "diff", "--name-only", "--diff-filter=U").splitlines()


def apply_failures(tree, commit):
    """The files of commit that git apply cannot take as they are on HEAD ([] when it applies)."""
    patch = sh(["git", "-C", tree, "format-patch", "-1", "--binary", "--stdout", commit])[1]
    p = subprocess.run(["git", "-C", tree, "apply", "--check", "-"], input=patch, text=True, capture_output=True)
    if p.returncode == 0:
        return []
    files = re.findall(r"^error: (?:patch failed: |)(\S+?):(?:\d+|.*does not exist in index|.*already exists)",
                       p.stderr, re.M)
    return sorted(set(files)) or ["?"]


def cherry_pick(tree, commit, *extra):
    return sh(["git", "-C", tree, "cherry-pick", "--empty=drop", *extra, commit], env=COMMITTER, check=False)[0]


def pick(tree, rec, trial):
    """Pick rec's commit onto HEAD; set rec's class and files. False when it stopped at a conflict."""
    head = git(tree, "rev-parse", "HEAD")
    failed = apply_failures(tree, rec["old_commit"])
    if cherry_pick(tree, rec["old_commit"]) == 0:
        rec["class"] = "upstream" if git(tree, "rev-parse", "HEAD") == head else "3-way" if failed else "clean"
        rec["files"] = failed
        return True
    left = unmerged(tree)
    if not left and git_ok(tree, "rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD"):
        rec["class"], rec["files"] = "rerere", failed
        return finish_pick(tree, rec)
    rec["files"] = left or failed
    if not trial:
        rec["class"], rec["head_before"] = "conflict", head
        return False
    sh(["git", "-C", tree, "cherry-pick", "--abort"], check=False)
    git(tree, "reset", "-q", "--hard", head)
    sh(["git", "-C", tree, "rerere", "clear"], check=False)
    if cherry_pick(tree, rec["old_commit"], "-X", "theirs") == 0:
        rec["class"] = "conflict"
    else:
        rec["class"] = "conflict-unresolvable"
        sh(["git", "-C", tree, "cherry-pick", "--abort"], check=False)
        git(tree, "reset", "-q", "--hard", head)
    return True


def finish_pick(tree, rec):
    """Commit a pick whose conflicts are resolved and staged (rerere records the resolution)."""
    if git_ok(tree, "diff", "--cached", "--quiet", "HEAD"):
        sh(["git", "-C", tree, "cherry-pick", "--skip"], env=COMMITTER)
        rec["class"] = "upstream"
    else:
        sh(["git", "-C", tree, "-c", "core.editor=true", "cherry-pick", "--continue"], env=COMMITTER)
    return True


def start(repo, build, target, new, trial, fetch):
    # A trial works in its own directory, so it leaves a run's results alone.
    run = os.path.join(build, "rebase", target, "trial") if trial else os.path.join(build, "rebase", target)
    state_file = os.path.join(run, "state.json")
    if not trial and os.path.exists(state_file) and read_json(state_file)["phase"] == "stopped":
        raise Fail(f"{run} is stopped at a conflict: --continue it or --abort it first")
    pins = sync.read_pins(open(os.path.join(repo, "pins.lock")).read())
    comp = sync.TARGET_COMPONENT.get(target)
    if comp not in pins:
        raise Fail(f"no pins.lock row for {target}'s component ({comp})")
    old = pins[comp]["commit"]
    mm = mirror(build, comp, pins[comp]["url"], new, fetch)
    new_sha = git(mm, "rev-parse", new + "^{commit}")
    old = git(mm, "rev-parse", old + "^{commit}")
    clear(run)
    tree = os.path.join(run, "tree")
    os.makedirs(run, exist_ok=True)
    sh(["git", "clone", "-q", "--shared", "--no-checkout", mm, tree])
    for k, v in (("rerere.enabled", "true"), ("rerere.autoUpdate", "true"), ("merge.conflictStyle", "zdiff3"),
                 ("core.abbrev", "7"), ("advice.detachedHead", "false")):
        git(tree, "config", k, v)
    rr = os.path.join(build, "rebase", "rr-cache", comp)
    os.makedirs(rr, exist_ok=True)
    rr_tree = os.path.join(tree, ".git", "rr-cache")
    if trial:  # a copy: the -X theirs picks must not record resolutions
        shutil.copytree(rr, rr_tree)
    else:
        os.symlink(rr, rr_tree)
    git(tree, "checkout", "-q", "-f", old)
    picks = []
    for s in stack(target):
        files = sync.series(repo, s)
        if files:
            sh(["git", "-C", tree, "am", "-3", "--quiet", *files], env=COMMITTER)
        picks += [{"series": s, "patch": os.path.basename(f)} for f in files]
    old_tip = git(tree, "rev-parse", "HEAD")
    commits = git(tree, "rev-list", "--reverse", f"{old}..{old_tip}").splitlines()
    if len(commits) != len(picks):
        raise Fail(f"{len(picks)} patches made {len(commits)} commits")
    for rec, c in zip(picks, commits):
        rec["old_commit"] = c
    state = {"target": target, "component": comp, "stack": stack(target), "old": old, "new": new_sha,
             "new_ref": new, "old_tip": old_tip, "picks": picks, "next": 0, "trial": trial,
             "distance": int(git(tree, "rev-list", "--count", f"{old}..{new_sha}")),
             "descends": git_ok(tree, "merge-base", "--is-ancestor", old, new_sha),
             "moves": moved_gitlinks(mm, comp, new_sha, pins)}
    git(tree, "checkout", "-q", "--detach", new_sha)
    log(f"{target}: {len(picks)} patches ({' + '.join(state['stack'])}) from {old[:12]} onto {new_sha[:12]} "
        f"({state['distance']} upstream commits{'' if state['descends'] else ', not a descendant'})")
    return replay(run, state)


def clear(run):
    """Drop a run's tree, state and results (not the trial tables or the recorded resolutions)."""
    for f in ("tree", "trial", "patches", "state.json", "range-diff.txt", "flags.txt", "series.diff"):
        p = os.path.join(run, f)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        elif os.path.lexists(p):
            os.remove(p)


def moved_gitlinks(mm, comp, new, pins):
    """Rows pinned at a gitlink of comp (fex's External/rpmalloc is the rpmalloc row) that NEW moves."""
    out = {}
    for row, (src, path) in sync.GITLINKS.items():
        if src == comp and row in pins:
            try:
                at = sync.gitlink(mm, new, path)
            except Fail:
                at = None
            if at != pins[row]["commit"]:
                out[row] = {"path": path, "pin": pins[row]["commit"], "new": at}
    return out


def read_json(path):
    with open(path) as f:
        return json.load(f)


def save(run, state):
    with open(os.path.join(run, "state.json") + ".tmp", "w") as f:
        json.dump(state, f, indent=1)
    os.replace(os.path.join(run, "state.json") + ".tmp", os.path.join(run, "state.json"))


def replay(run, state):
    tree = os.path.join(run, "tree")
    picks = state["picks"]
    while state["next"] < len(picks):
        rec = picks[state["next"]]
        if not pick(tree, rec, state["trial"]):
            state["phase"] = "stopped"
            save(run, state)
            log(f"{rec['series']}/{rec['patch']}: conflict in {', '.join(rec['files'])}")
            print(f"Resolve it in {tree} (both sides: `git diff`, `git log -p {state['old']}..{state['new']} -- FILE`), "
                  f"`git add` the files, then: pp rebase {state['target']} --continue", flush=True)
            return 10
        rec["new_commit"] = git(tree, "rev-parse", "HEAD")
        log(f"  {rec['series']}/{rec['patch']}: {rec['class']}" + (f" ({', '.join(rec['files'])})" if rec["files"] else ""))
        state["next"] += 1
        if not state["trial"]:
            state["phase"] = "replaying"
            save(run, state)
    return trial_done(run, state) if state["trial"] else done(run, state)


def table(state):
    rows = [f"{r['series']}\t{r['patch']}\t{r['class']}\t{' '.join(r['files'])}" for r in state["picks"]]
    counts = {}
    for r in state["picks"]:
        counts[r["class"]] = counts.get(r["class"], 0) + 1
    return rows, ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))


def trial_done(run, state):
    rows, summary = table(state)
    out = os.path.join(os.path.dirname(run), f"trial-{state['new'][:12]}.tsv")
    with open(out, "w") as f:
        f.write("series\tpatch\tclass\tfiles\n" + "\n".join(rows) + "\n")
    shutil.rmtree(run)
    print("\n".join(r for r in rows if r.split("\t")[2] != "clean"))
    print(f"{state['target']} onto {state['new'][:12]} ({state['distance']} upstream commits): {summary}; "
          f"table in {out}")
    note_moves(state)
    return 0


def note_moves(state):
    for row, m in state["moves"].items():
        print(f"note: {state['new'][:12]} moves {row} (its {m['path']} gitlink) from {m['pin'][:12]} to "
              f"{(m['new'] or 'nothing')[:12]}: that row moves with it (pp rebase {row} {m['new']})")


def cont(repo, build, target):
    run, state = load(build, target)
    if state["phase"] != "stopped":
        raise Fail(f"{run} is not stopped at a conflict")
    tree = os.path.join(run, "tree")
    rec = state["picks"][state["next"]]
    left = unmerged(tree)
    if left:
        raise Fail(f"still unmerged in {tree}: {', '.join(left)}")
    if git_ok(tree, "rev-parse", "-q", "--verify", "CHERRY_PICK_HEAD"):
        sh(["git", "-C", tree, "add", "-u"])
        finish_pick(tree, rec)
    elif git(tree, "rev-parse", "HEAD") == rec["head_before"]:
        raise Fail(f"{tree} has no pick in progress and no new commit: pick it again or --abort")
    if rec["class"] == "conflict":
        rec["class"] = "resolved"
    state["phase"] = "replaying"
    rec["new_commit"] = git(tree, "rev-parse", "HEAD")
    log(f"  {rec['series']}/{rec['patch']}: {rec['class']}")
    state["next"] += 1
    return replay(run, state)


def load(build, target):
    run = os.path.join(build, "rebase", target)
    if not os.path.exists(os.path.join(run, "state.json")):
        raise Fail(f"no run for {target} in {run}")
    return run, read_json(os.path.join(run, "state.json"))


def range_diff_marks(text, picks):
    """{old commit: '=' | '!' | '<'} from git range-diff output."""
    marks = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(?:\d+|-):\s+([0-9a-f]+|-+)\s+([=!<>])\s", line)
        if m and not m.group(1).startswith("-"):
            for r in picks:
                if r["old_commit"].startswith(m.group(1)):
                    marks[r["old_commit"]] = m.group(2)
    return marks


def reexport(text, original, cls):
    """The exported patch with the original's Subject header (git am drops a [WIP] or a [PATCH 2/9] from the
    subject, so it cannot come back from the commit) and its Rebased:/Picked: trailer set to resolved when this
    move needed a resolution."""
    subject = re.search(r"^Subject: .*\n(?: .*\n)*", original, re.M)
    if subject:
        text = re.sub(r"^Subject: .*\n(?: .*\n)*", lambda m: subject.group(0), text, count=1, flags=re.M)
    head, sep, rest = text.partition("\n---\n")
    if cls in RESOLVED or cls == "rerere":
        head = TRAILER_RE.sub(lambda m: f"{m.group(1)}: resolved", head)
    return head + sep + rest


def done(run, state):
    repo, _ = paths()
    tree = os.path.join(run, "tree")
    new_tip = git(tree, "rev-parse", "HEAD")
    state["new_tip"] = new_tip
    rd = git(tree, "range-diff", "--no-color", f"{state['old']}..{state['old_tip']}", f"{state['new']}..{new_tip}")
    with open(os.path.join(run, "range-diff.txt"), "w") as f:
        f.write(rd + "\n")
    marks = range_diff_marks(rd, state["picks"])
    flags = []
    for r in state["picks"]:
        r["range_diff"] = marks.get(r["old_commit"], "?")
        if r["range_diff"] == "!" and r["class"] not in RESOLVED:
            flags.append(f"{r['series']}/{r['patch']}\t{r['class']}\t{' '.join(r['files'])}")
    with open(os.path.join(run, "flags.txt"), "w") as f:
        f.write("".join(l + "\n" for l in flags))
    out = os.path.join(run, "patches")
    for s in state["stack"]:
        d = os.path.join(out, s)
        os.makedirs(d, exist_ok=True)
        dropped = {r["patch"] for r in state["picks"] if r["series"] == s and r["class"] == "upstream"}
        lines = open(os.path.join(repo, "patches", s, "series")).read().splitlines(keepends=True)
        with open(os.path.join(d, "series"), "w") as f:
            f.write("".join(l for l in lines if l.strip() not in dropped))
        for r in state["picks"]:
            if r["series"] == s and r["class"] == "clean":  # it applies as it is: the file stays
                shutil.copyfile(os.path.join(repo, "patches", s, r["patch"]), os.path.join(d, r["patch"]))
            elif r["series"] == s and r["class"] != "upstream":
                text = sh(["git", "-C", tree, "-c", "core.abbrev=7", "format-patch", "-1", "--zero-commit",
                           "--no-signature", "--stdout", r["new_commit"]])[1]
                with open(os.path.join(repo, "patches", s, r["patch"]), errors="replace") as f:
                    original = f.read()
                with open(os.path.join(d, r["patch"]), "w") as f:
                    f.write(reexport(text, original, r["class"]))
    diff = ""
    for s in state["stack"]:
        diff += sh(["git", "diff", "--no-index", "--no-color", os.path.join("patches", s),
                    os.path.relpath(os.path.join(out, s), repo)], cwd=repo, check=False)[1]
    with open(os.path.join(run, "series.diff"), "w") as f:
        f.write(diff)
    state["phase"] = "done"
    save(run, state)
    rows, summary = table(state)
    log(f"{state['target']} onto {state['new'][:12]}: {summary}; range-diff in {run}/range-diff.txt")
    for fl in flags:
        print(f"check (auto-merged, changed in the range-diff): {fl}")
    print(f"series re-exported to {out}; against patches/: {run}/series.diff; pp rebase {state['target']} --write "
          f"copies it into patches/")
    note_moves(state)
    return 0


def write(repo, build, target, pins_too):
    run, state = load(build, target)
    if state["phase"] != "done":
        raise Fail(f"{run} has not finished")
    for s in state["stack"]:
        src, dst = os.path.join(run, "patches", s), os.path.join(repo, "patches", s)
        for r in state["picks"]:
            if r["series"] == s and r["class"] == "upstream" and os.path.exists(os.path.join(dst, r["patch"])):
                os.remove(os.path.join(dst, r["patch"]))
        for name in os.listdir(src):
            shutil.copyfile(os.path.join(src, name), os.path.join(dst, name))
    if pins_too:
        lock = os.path.join(repo, "pins.lock")
        comp = state["component"]
        mm = os.path.join(build, "cache", comp + ".git")
        branch = state["new_ref"] if git_ok(mm, "rev-parse", "-q", "--verify",
                                            f"refs/heads/{state['new_ref']}") else None
        text = open(lock).read()
        open(lock, "w").write(sync.rewrite_pins(text, {comp: {"commit": state["new"], "branch": branch}}))
    print(sh(["git", "diff", "--stat", "--", "patches", "pins.lock"], cwd=repo)[1].rstrip())
    note_moves(state)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="pp rebase", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target")
    ap.add_argument("new", nargs="?")
    ap.add_argument("--trial", action="store_true")
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--continue", dest="cont", action="store_true")
    ap.add_argument("--abort", action="store_true")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--pins", action="store_true")
    a = ap.parse_args(argv)
    modes = [a.new is not None, a.cont, a.abort, a.write]
    if sum(modes) != 1 or (a.pins and not a.write) or ((a.trial or a.fetch) and a.new is None):
        ap.print_usage(sys.stderr)
        return 2
    repo, build = paths()
    if a.target not in sync.TARGET_COMPONENT:
        print(f"pp rebase: {a.target} is not a series on a pinned component "
              f"({', '.join(sorted(sync.TARGET_COMPONENT))})", file=sys.stderr)
        return 2
    os.makedirs(os.path.join(build, "rebase"), exist_ok=True)
    with open(os.path.join(build, "rebase", a.target + ".lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"pp rebase: another pp rebase {a.target} is running", file=sys.stderr)
            return 1
        try:
            if a.abort:
                clear(os.path.join(build, "rebase", a.target))
                log(f"{a.target}: run dropped (resolutions kept in {os.path.join(build, 'rebase', 'rr-cache')})")
                return 0
            if a.cont:
                return cont(repo, build, a.target)
            if a.write:
                return write(repo, build, a.target, a.pins)
            return start(repo, build, a.target, a.new, a.trial, a.fetch)
        except Fail as e:
            print(f"pp rebase: {e}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

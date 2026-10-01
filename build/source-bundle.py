#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pack an IPA's Corresponding Source (docs/DISTRIBUTION.md, section 2).

  pp source OUT [--build DIR | --rev REV] [--offline] [--run DIR]

OUT must not exist. The Playport commit is the one DIR (a pp build output, with
provenance.txt, pins.lock and SHA256SUMS) was built from, or REV (default HEAD).
Everything is packed from that commit's pins.lock, never from the working copy:

  git        each source in build/source-bundle.json archived from its exact commit,
             submodules expanded in place (a tag-pinned one from the commit the
             catalog records for its tag); objects come from the local candidates
             it names, else a fetch by commit into $PLAYPORT_BUILD/cache/source
  files      release tarballs checked against their sha256, with GStreamer's Cerbero
             recipes and source archives from build/gstreamer-notices.sources.json
  crates     every .crate idevice's Cargo.lock names, checked against its checksum
  run files  generated inputs taken from the run tree (--run, default $PLAYPORT_BUILD/run)

It writes one tar.gz per source, SOURCE-MANIFEST.json (commits, URLs, what was left
out and why, the build it belongs to), README.md and SHA256SUMS, into a scratch
directory beside OUT that becomes OUT only after every check passed. It fails on a
commit it cannot find, a checksum mismatch, a submodule or prebuilt binary the
catalog does not account for, a keep or drop rule that matches nothing, a dirty
build, or a machine path in a generated file. The catalog's `missing` list marks
the bundle incomplete; the bundle does not claim more than it holds.
"""

import argparse
import fnmatch
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "build/source-bundle.json"
# Prebuilt-code extensions supplement the ELF content check; both require a named allowance.
BINARY = (".exe", ".dll", ".dylib", ".so", ".a", ".lib", ".o", ".obj", ".pdb", ".nls", ".framework")
GIT_ENV = {"GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_CONFIG_NOSYSTEM": "1"}


class Stop(Exception):
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def git(gitdir, *args, check=True, binary=False, stdout=None):
    env = {**os.environ, **GIT_ENV}
    r = subprocess.run(["git", "--git-dir", str(gitdir), *args], env=env, stdout=stdout or subprocess.PIPE,
                       stderr=subprocess.PIPE, text=not binary)
    if check and r.returncode:
        err = r.stderr.decode(errors="replace") if binary else r.stderr
        raise Stop(f"git {' '.join(args)} in {gitdir} failed: {err.strip()}")
    return r


def parse_pins(text):
    pins = {}
    for line in text.splitlines():
        parts = line.split()
        if parts and not line.startswith("#"):
            pins[parts[0]] = {"value": parts[1], "url": parts[2]}
    return pins


def gitdir_of(path):
    """The git directory of a checkout or bare repository at PATH, or None."""
    path = Path(path)
    if not path.exists():
        return None
    r = subprocess.run(["git", "-C", str(path), "rev-parse", "--absolute-git-dir"], capture_output=True, text=True,
                       env={**os.environ, **GIT_ENV})
    if r.returncode:
        return None
    gd = Path(r.stdout.strip())
    # Only PATH's own repository: not an enclosing one it happens to be inside.
    top = subprocess.run(["git", "-C", str(path), "rev-parse", "--is-bare-repository", "--show-toplevel"],
                         capture_output=True, text=True).stdout.split()
    if top and top[0] == "false" and (len(top) < 2 or Path(top[1]).resolve() != path.resolve()):
        return None
    return gd


def resolve_url(parent, url):
    """A submodule URL, relative ones (./x, ../x) taken against the parent's URL."""
    if not url.startswith(("./", "../")):
        return url
    base = parent.rstrip("/")
    for part in url.split("/"):
        if part == "..":
            base = base.rsplit("/", 1)[0]
        elif part not in (".", ""):
            base = f"{base}/{part}"
    return base


def store_name(url):
    """The cache directory name for URL's fetched objects."""
    s = re.sub(r"^[a-z+]+://", "", url).rstrip("/")
    s = re.sub(r"\.git$", "", s)
    s = re.sub(r"[^A-Za-z0-9._/-]", "_", s).strip("/")
    if not s or ".." in s.split("/"):
        raise Stop(f"cannot make a cache name for {url!r}")
    return s + ".git"


class Objects:
    """Finds a git directory that holds a commit's whole tree."""

    def __init__(self, cache, offline, say):
        self.cache, self.offline, self.say = Path(cache), offline, say

    def usable(self, gd, commit):
        if gd is None or git(gd, "cat-file", "-e", f"{commit}^{{tree}}", check=False).returncode:
            return False
        # A partial clone would fetch missing blobs lazily (and git before 2.44 ignores
        # GIT_NO_LAZY_FETCH): take it as not holding the tree.
        return not git(gd, "config", "--get", "extensions.partialClone", check=False).stdout.strip()

    def find(self, commit, url, local=()):
        for gd in local:
            if self.usable(gd, commit):
                return gd
        store = self.cache / store_name(url)
        if self.usable(store if store.exists() else None, commit):
            return store
        if self.offline:
            raise Stop(f"{commit} of {url} is in no local repository (--offline: not fetched)")
        store.mkdir(parents=True, exist_ok=True)
        if not (store / "HEAD").exists():
            git(store, "init", "-q", "--bare")
        self.say(f"source: fetch {commit[:12]} from {url}")
        git(store, "fetch", "-q", "--depth", "1", "--no-tags", url, commit)
        if not self.usable(store, commit):
            raise Stop(f"fetching {commit} from {url} did not give its tree")
        return store


class Rules:
    """keep/drop globs over paths from a component's root; keep wins."""

    def __init__(self, keep, drop):
        self.keep, self.drop = dict(keep or {}), dict(drop or {})
        self.hits = {("keep", p): 0 for p in self.keep} | {("drop", p): 0 for p in self.drop}

    def dropped(self, path):
        kept = [p for p in self.keep if fnmatch.fnmatchcase(path, p)]
        for p in kept:
            self.hits[("keep", p)] += 1
        if kept:
            return False
        drops = [p for p in self.drop if fnmatch.fnmatchcase(path, p)]
        for p in drops:
            self.hits[("drop", p)] += 1
        return bool(drops)

    def unused(self):
        return [f"{kind} {p!r}" for (kind, p), n in self.hits.items() if n == 0]


def gitmodules(gd, commit):
    """{path: url} from COMMIT's .gitmodules."""
    r = git(gd, "config", "--blob", f"{commit}:.gitmodules", "--get-regexp", r"^submodule\..*\.(path|url)$",
            check=False)
    names = {}
    for line in r.stdout.splitlines():
        key, _, value = line.partition(" ")
        name, field = key[len("submodule."):].rsplit(".", 1)
        names.setdefault(name, {})[field] = value.strip()
    return {v["path"]: v.get("url", "") for v in names.values() if "path" in v}


def gitlinks(gd, commit):
    """[(path, commit)] of COMMIT's submodule entries."""
    out = git(gd, "ls-tree", "-r", "-z", commit).stdout
    links = []
    for entry in out.split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        mode, kind, obj = meta.split()
        if mode == "160000":
            links.append((path, obj))
    return links


class Packer:
    def __init__(self, objects, say=print):
        self.objects, self.say = objects, say

    def component(self, comp, commit, url, local, dest):
        """Archive COMP at COMMIT into DEST (a .tar.gz); returns its manifest entry."""
        name = comp["name"]
        prefix = dest.name[: -len(".tar.gz")]
        rules = Rules(comp.get("keep"), comp.get("drop"))
        allow = dict(comp.get("allow_binary") or {})
        allow_hits = dict.fromkeys(allow, 0)
        skip_links = dict(comp.get("submodules") or {})
        skip_hits = dict.fromkeys(skip_links, 0)
        entry = {"name": name, "archive": dest.name, "url": url, "commit": commit, "why": comp.get("why", ""),
                 "repositories": [], "submodules_left_out": [], "dropped": {}}
        counts = {"files": 0, "bytes": 0}
        with open(dest, "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz, \
                tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as out:
            self.tree(name, commit, url, local, "", prefix, out, rules, allow, allow_hits, skip_links, skip_hits,
                      entry, counts)
        if entry.get("_binaries"):
            raise Stop(f"{name}: these look like prebuilt binaries; drop them or name them in allow_binary with a "
                       f"reason (build/source-bundle.json): {', '.join(entry['_binaries'])}")
        bad = rules.unused() + [f"allow_binary {p!r}" for p, n in allow_hits.items() if n == 0] \
            + [f"submodule {p!r}" for p, n in skip_hits.items() if n == 0]
        if bad:
            raise Stop(f"{name}: catalog rules that match nothing: {', '.join(bad)} (build/source-bundle.json)")
        entry["dropped"] = {p: {"reason": comp["drop"][p], "members": n}
                            for (kind, p), n in rules.hits.items() if kind == "drop"}
        if allow:
            entry["allowed_binaries"] = {p: {"reason": allow[p], "members": n} for p, n in allow_hits.items()}
        entry.update(counts)
        return entry

    def tree(self, name, commit, url, local, sub, prefix, out, rules, allow, allow_hits, skip_links, skip_hits,
             entry, counts):
        gd = self.objects.find(commit, url, local)
        entry["repositories"].append({"path": sub or ".", "url": url, "commit": commit,
                                      "tree": git(gd, "rev-parse", f"{commit}^{{tree}}").stdout.strip()})
        # stderr to a file: a pipe read only after stdout could fill and stall git.
        with tempfile.TemporaryFile() as errfile:
            proc = subprocess.Popen(["git", "--git-dir", str(gd), "archive", "--format=tar", commit],
                                    stdout=subprocess.PIPE, stderr=errfile, env={**os.environ, **GIT_ENV})
            whole = False
            try:
                with tarfile.open(fileobj=proc.stdout, mode="r|") as src:
                    for m in src:
                        rel = m.name.rstrip("/")
                        full = f"{sub}/{rel}" if sub else rel
                        if not rel or rel.startswith("/") or ".." in rel.split("/"):
                            raise Stop(f"{name}: unsafe member {m.name!r} in {url} {commit}")
                        if rules.dropped(full):
                            continue
                        m.name = f"{prefix}/{full}"
                        m.uid = m.gid = 0
                        m.uname = m.gname = ""
                        m.pax_headers = {}
                        if m.isfile():
                            with src.extractfile(m) as blob:
                                # ExFileObject is buffered: peek reads a bounded prefix without
                                # consuming it, including in streaming tar mode. addfile then
                                # copies every byte once, without buffering the whole member.
                                if full.endswith(BINARY) or blob.peek(4)[:4] == b"\x7fELF":
                                    ok = [p for p in allow if fnmatch.fnmatchcase(full, p)]
                                    if not ok:
                                        entry.setdefault("_binaries", []).append(full)
                                    for p in ok:
                                        allow_hits[p] += 1
                                out.addfile(m, blob)
                            counts["files"] += 1
                            counts["bytes"] += m.size
                        else:
                            out.addfile(m)
                proc.stdout.read()  # the archive's trailing padding, so git is not cut off
                whole = True
            finally:
                # An error part-way through stops git rather than leaking it and its pipe.
                if not whole:
                    proc.kill()
                proc.stdout.close()
                status = proc.wait()
            errfile.seek(0)
            err = errfile.read().decode(errors="replace")
        if status:
            raise Stop(f"git archive {commit} of {url} failed: {err.strip()}")
        mods = gitmodules(gd, commit)
        for path, subcommit in gitlinks(gd, commit):
            full = f"{sub}/{path}" if sub else path
            if full in skip_links:
                skip_hits[full] += 1
                entry["submodules_left_out"].append({"path": full, "commit": subcommit, "reason": skip_links[full]})
                continue
            if rules.dropped(full):
                continue
            if path not in mods or not mods[path]:
                raise Stop(f"{name}: submodule {full} at {subcommit} has no URL in .gitmodules")
            suburl = resolve_url(url, mods[path])
            # The object sources for a submodule: the same path in each local checkout.
            sublocal = [g for g in (gitdir_of(Path(c) / path) for c in self.checkouts(local)) if g]
            self.tree(name, subcommit, suburl, sublocal + list(local), full, prefix, out, rules, allow, allow_hits,
                      skip_links, skip_hits, entry, counts)

    @staticmethod
    def checkouts(local):
        """Working trees among the local git directories (a submodule's objects may be there)."""
        for gd in local:
            gd = Path(gd)
            if gd.name == ".git":
                yield gd.parent
            else:
                r = subprocess.run(["git", "--git-dir", str(gd), "rev-parse", "--is-bare-repository"],
                                   capture_output=True, text=True)
                if r.stdout.strip() == "false":
                    wt = subprocess.run(["git", "--git-dir", str(gd), "config", "--get", "core.worktree"],
                                        capture_output=True, text=True).stdout.strip()
                    if wt:
                        yield (gd / wt).resolve()


def local_candidates(specs, repo, build_dir, run_dir, commit):
    out = []
    for spec in specs or ():
        kind, _, rel = spec.partition(":")
        rel = rel.replace("{commit}", commit)
        base = {"repo": repo, "cache": build_dir / "cache", "run": run_dir}.get(kind)
        if base is None:
            raise Stop(f"unknown local source {spec!r} (build/source-bundle.json)")
        gd = gitdir_of(base / rel)
        if gd:
            out.append(gd)
    return out


def provenance(build, repo, rev_pins):
    """The superproject commit a pp build output DIR was made from; Stop if it is not a clean one."""
    lines = (build / "provenance.txt").read_text().splitlines()
    sup = [l.split()[1:] for l in lines if l.startswith("superproject ")]
    if len(sup) != 1:
        raise Stop(f"{build}/provenance.txt names no single superproject commit")
    if len(sup[0]) > 1:
        raise Stop(f"{build.name} was built with local changes: its source is no commit")
    head = sup[0][0]
    if (build / "pins.lock").read_bytes() != rev_pins(head):
        raise Stop(f"{build}/pins.lock is not {head[:8]}'s pins.lock")
    series = {}
    for l in lines:
        if l.startswith("series "):
            _, target, digest = l.split()
            series[target] = digest
    return head, lines, series


def series_digests(gd, commit):
    """provenance.txt's series lines, from COMMIT's patches/ (cat patches/T/*.patch | sha256sum | cut -c1-16)."""
    targets = git(gd, "ls-tree", "-d", "-z", "--name-only", f"{commit}:patches").stdout
    files = {t: [] for t in targets.split("\0") if t}
    out = git(gd, "ls-tree", "-r", "-z", "--name-only", commit, "--", "patches").stdout
    for p in out.split("\0"):
        parts = p.split("/")
        if len(parts) == 3 and p.endswith(".patch"):
            files.setdefault(parts[1], []).append(p)
    digests = {}
    for target, paths in files.items():
        h = hashlib.sha256()
        for p in sorted(paths, key=lambda s: s.encode()):
            h.update(git(gd, "cat-file", "blob", f"{commit}:{p}", binary=True).stdout)
        digests[target] = h.hexdigest()[:16]
    return digests


def file_sources(f, pin, blob):
    """[(name, file name, url, sha256, why, cache paths holding the same bytes)] for one catalog `files` entry;
    blob(path) reads a file of the packed commit."""
    if "gstreamer_lock" in f:
        # The GStreamer release's Cerbero recipes and the source archives its static prelink is taken from
        # (docs/release-audits/gstreamer.md); build/notices-inputs.py keeps the same bytes for the notices.
        lock = json.loads(blob(f["gstreamer_lock"]))
        if lock.get("schema") != 1 or lock.get("release") != pin["value"]:
            raise Stop(f"{f['gstreamer_lock']} is for GStreamer {lock.get('release')}, pins.lock says {pin['value']}")
        if hashlib.sha256(blob(f["stage"])).hexdigest() != lock["stage_sha256"]:
            raise Stop(f"{f['stage']} is not the stage {f['gstreamer_lock']} was reviewed against: review it again")
        c = lock["cerbero"]
        out = [("cerbero", f"cerbero-{c['commit']}.tar.gz", c["url"], c["sha256"],
                f"Cerbero {pin['value']} (tag object {c['tag_object']}): the recipes, patches and configuration "
                "GStreamer's iOS release is built with", ["gstreamer-notices/cerbero.tar.gz"])]
        for key, c in sorted(lock["components"].items()):
            base = key.removesuffix("-1.0")
            fname = c["archive"] if c["archive"].startswith(base) else f"{base}-{c['archive']}"
            out.append((key, fname, c["reviewed_download_url"], c["sha256"],
                        f"{key} {c['version']}, the source of Cerbero's {c['recipe']}",
                        [f"gstreamer-notices/sources/{c['archive']}"]))
        return out
    if "lock" in f:
        lock = json.loads(blob(f["lock"]))
        if lock.get("rust") != pin["value"]:
            raise Stop(f"{f['lock']} is for {lock.get('rust')}, pins.lock says {pin['value']}")
        c = lock["components"][f["component"]]
        return [(f["name"], c["archive"], c["url"], c["sha256"], f.get("why", ""), [])]
    if pin["value"] != f["tag"]:
        raise Stop(f"pins.lock pins {f['pin']} at {pin['value']}; build/source-bundle.json records "
                   f"{f['file']} for {f['tag']}: update it")
    return [(f["name"], f["file"], f["url"], f["sha256"], f.get("why", ""), [])]


def fetch_file(url, dest, sha, offline, say):
    if dest.is_file() and sha256_file(dest) == sha:
        return dest
    if offline:
        raise Stop(f"{dest.name} (sha256 {sha}) is not in {dest.parent} (--offline: not downloaded)")
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    say(f"source: download {url}")
    try:
        with urllib.request.urlopen(url, timeout=120) as r, open(part, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 20)
    except OSError as exc:
        part.unlink(missing_ok=True)
        raise Stop(f"downloading {url} failed: {exc}")
    got = sha256_file(part)
    if got != sha:
        part.unlink()
        raise Stop(f"{url} is sha256 {got}, not {sha}")
    part.replace(dest)
    return dest


def crates(lock_text, registry, rust_root, cache, url_pattern, offline, say):
    """[(file name, path, sha256)] for every registry package of a Cargo.lock."""
    found = []
    for pkg in tomllib.loads(lock_text).get("package", []):
        src = pkg.get("source")
        if src is None:
            continue  # a workspace member: its source is in the git archive
        if src != registry:
            raise Stop(f"Cargo.lock: {pkg['name']} {pkg['version']} comes from {src}, which pp source cannot pack")
        sha = pkg.get("checksum")
        if not sha:
            raise Stop(f"Cargo.lock: {pkg['name']} {pkg['version']} has no checksum")
        fname = f"{pkg['name']}-{pkg['version']}.crate"
        have = None
        for d in sorted((rust_root / "cargo/registry/cache").glob("*")) if rust_root else ():
            if (d / fname).is_file() and sha256_file(d / fname) == sha:
                have = d / fname
                break
        if have is None:
            have = fetch_file(url_pattern.format(name=pkg["name"], version=pkg["version"]), cache / fname, sha,
                              offline, say)
        found.append((fname, have, sha))
    return sorted(found)


def machine_paths(data, extra):
    pats = [rb"/home/[^/\s\"']+/", rb"/Users/[^/\s\"']+/", rb"/root/"] + [re.escape(os.fsencode(str(p))) for p in extra]
    return [m.decode(errors="replace") for m in {m.group(0) for p in pats for m in re.finditer(p, data)}]


def readme(manifest):
    lines = [f"# Playport {manifest['playport'][:10]}: Corresponding Source", ""]
    if manifest["status"] != "complete":
        lines += ["**Incomplete.** This bundle is known to lack:", ""]
        lines += [f"- {m['what']}: {m['why']}" for m in manifest["missing"]]
        lines.append("")
    if manifest.get("build"):
        b = manifest["build"]
        lines += [f"Built as `{b['ipa']}` (sha256 `{b['ipa_sha256']}`) from Playport commit "
                  f"`{manifest['playport']}`.", ""]
    else:
        lines += [f"Packed from Playport commit `{manifest['playport']}`, with no build output named.", ""]
    lines += ["Unpack `playport-*.tar.gz` first: its `pins.lock` names every commit below, `patches/` holds every",
              "change made to them, `build/` the scripts, and `docs/BUILDING.md` and `docs/DISTRIBUTION.md` how to",
              "build, sign, install and relink. Each other archive is one pinned tree at the commit listed, with",
              "its submodules in place.", "", "| Archive | Source | Commit or sha256 |", "| --- | --- | --- |"]
    for c in manifest["git"]:
        lines.append(f"| `{c['archive']}` | {c['url']} | `{c['commit']}` |")
    for f in manifest["files"]:
        lines.append(f"| `{f['archive']}` | {f['url']} | `{f['sha256']}` |")
    if manifest.get("crates"):
        c = manifest["crates"]
        lines.append(f"| `{c['archive']}` | {c['count']} crates from crates.io | Cargo.lock checksums |")
    for f in manifest["run_files"]:
        lines.append(f"| `{f['archive']}` | generated by the build | `{f['sha256']}` |")
    lines += ["", "`SOURCE-MANIFEST.json` lists every repository and submodule commit, what was left out and why.",
              "`SHA256SUMS` covers every file here.", ""]
    return "\n".join(lines)


def bundle(out, repo=REPO, build=None, rev=None, offline=False, run_dir=None, build_dir=None, rust_root=None,
           catalog=None, say=print):
    out = Path(out).resolve()
    if out.exists() or out.is_symlink():
        raise Stop(f"{out} already exists")
    build_dir = Path(build_dir or os.environ.get("PLAYPORT_BUILD") or repo / ".work").resolve()
    run_dir = Path(run_dir or build_dir / "run").resolve()
    rust_root = Path(rust_root or os.environ.get("RUST_ROOT") or build_dir / "inputs/rust")
    top = gitdir_of(repo)
    if top is None:
        raise Stop(f"{repo} is not a git checkout")

    def rev_pins(commit):
        r = git(top, "cat-file", "blob", f"{commit}:pins.lock", binary=True, check=False)
        if r.returncode:
            raise Stop(f"{commit} has no pins.lock")
        return r.stdout

    build_info = None
    if build:
        build = Path(build).resolve()
        head, lines, series = provenance(build, repo, rev_pins)
        want = series_digests(top, head)
        if series != want:
            raise Stop(f"{build.name}: provenance.txt's series lines are not {head[:8]}'s patches/")
        sums = dict(reversed(l.split(None, 1)) for l in (build / "SHA256SUMS").read_text().splitlines() if l.strip())
        ipas = [n for n in sums if n.endswith(".ipa")]
        if len(ipas) != 1:
            raise Stop(f"{build}/SHA256SUMS names no single IPA")
        if sha256_file(build / ipas[0]) != sums[ipas[0]]:
            raise Stop(f"{build}/{ipas[0]} does not match its SHA256SUMS")
        build_info = {"output": build.name, "ipa": ipas[0], "ipa_sha256": sums[ipas[0]], "provenance": lines}
    else:
        r = git(top, "rev-parse", "--verify", f"{rev or 'HEAD'}^{{commit}}", check=False)
        if r.returncode:
            raise Stop(f"no commit {rev or 'HEAD'}")
        head = r.stdout.strip()
    # The policy belongs to the same commit as the sources, not today's working
    # copy. An explicit catalog is only for callers' isolated test fixtures.
    cat_bytes = (Path(catalog).read_bytes() if catalog is not None else
                 git(top, "cat-file", "blob", f"{head}:build/source-bundle.json", binary=True).stdout)
    cat = json.loads(cat_bytes)
    if cat.get("schema") != 1:
        raise Stop(f"{catalog or 'build/source-bundle.json'}: unknown schema")
    pins = parse_pins(rev_pins(head).decode())
    objects = Objects(build_dir / "cache/source", offline, say)
    packer = Packer(objects, say)
    tmp = out.with_name(f".{out.name}.partial-{os.getpid()}")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    try:
        manifest = {"schema": 1, "playport": head, "build": build_info,
                    "catalog_sha256": hashlib.sha256(cat_bytes).hexdigest(),
                    "status": "incomplete" if cat.get("missing") else "complete",
                    "missing": cat.get("missing", []), "git": [], "files": [], "crates": None, "run_files": []}
        commits = {}
        for comp in cat["git"]:
            if comp["pin"] == "superproject":
                commit, url, local = head, "(this repository)", [top]
            else:
                pin = pins.get(comp["pin"])
                if pin is None:
                    raise Stop(f"pins.lock at {head[:8]} has no {comp['pin']}")
                url = pin["url"]
                if "tag" in comp:
                    if pin["value"] != comp["tag"]:
                        raise Stop(f"pins.lock pins {comp['pin']} at {pin['value']}; build/source-bundle.json records "
                                   f"the commit of {comp['tag']}: update its tag and commit together")
                    commit = comp["commit"]
                else:
                    commit = pin["value"]
                    if not re.fullmatch(r"[0-9a-f]{40}", commit):
                        raise Stop(f"{comp['pin']} is pinned by {commit!r}, not a commit: give the catalog its commit")
                local = local_candidates(comp.get("local"), repo, build_dir, run_dir, commit)
            commits[comp["name"]] = (commit, url, local)
            ident = comp.get("tag") or commit[:10]
            dest = tmp / f"{comp['name']}-{ident}.tar.gz"
            say(f"source: {comp['name']} {ident}")
            manifest["git"].append(packer.component(comp, commit, url, local, dest))
        taken = set()
        for f in cat.get("files", []):
            pin = pins.get(f["pin"])
            if pin is None:
                raise Stop(f"pins.lock at {head[:8]} has no {f['pin']}")
            for name, fname, url, sha, why, cached in file_sources(f, pin, lambda rel: git(
                    top, "cat-file", "blob", f"{head}:{rel}", binary=True).stdout):
                if fname in taken:
                    raise Stop(f"two files would be packed as {fname}")
                taken.add(fname)
                path = next((build_dir / "cache" / c for c in cached
                             if (build_dir / "cache" / c).is_file() and sha256_file(build_dir / "cache" / c) == sha),
                            None)
                path = path or fetch_file(url, build_dir / "cache/source/files" / fname, sha, offline, say)
                shutil.copyfile(path, tmp / fname)
                manifest["files"].append({"name": name, "archive": fname, "url": url, "sha256": sha, "why": why})
        if cat.get("crates"):
            c = cat["crates"]
            commit, url, local = commits[c["from"]]
            gd = objects.find(commit, url, local)
            lock_text = git(gd, "cat-file", "blob", f"{commit}:{c['lockfile']}").stdout
            found = crates(lock_text, c["registry"], rust_root, build_dir / "cache/source/crates", c["url"], offline,
                           say)
            name = f"{c['name']}-{commit[:10]}.tar"
            with tarfile.open(tmp / name, "w", format=tarfile.PAX_FORMAT) as t:
                for fname, path, _ in found:
                    info = tarfile.TarInfo(f"{c['name']}-{commit[:10]}/{fname}")
                    info.size, info.mode, info.mtime = path.stat().st_size, 0o644, 0
                    with open(path, "rb") as fh:
                        t.addfile(info, fh)
            manifest["crates"] = {"archive": name, "from": f"{c['from']} {commit}:{c['lockfile']}",
                                  "count": len(found), "why": c.get("why", ""),
                                  "crates": [{"file": f, "sha256": s} for f, _, s in found]}
        for f in cat.get("run_files", []):
            src = run_dir / f["path"]
            if not src.is_file():
                if build:
                    raise Stop(f"{src} is missing: pack from the run that built the IPA (--run)")
                manifest["missing"].append({"what": f"{f['name']} ({f['why']})",
                                            "why": f"no run tree with run/{f['path']} was given (--run)"})
                manifest["status"] = "incomplete"
                continue
            data = src.read_bytes()
            leaks = machine_paths(data, [build_dir, repo])
            if leaks:
                raise Stop(f"{src} names a machine path ({', '.join(sorted(leaks))})")
            (tmp / f["name"]).write_bytes(data)
            manifest["run_files"].append({"name": f["name"], "archive": f["name"], "from": f"run/{f['path']}",
                                          "sha256": hashlib.sha256(data).hexdigest(), "why": f.get("why", "")})
        text = json.dumps(manifest, indent=2, sort_keys=False) + "\n"
        leaks = machine_paths(text.encode(), [build_dir, repo])
        if leaks:
            raise Stop(f"the manifest names a machine path ({', '.join(sorted(leaks))})")
        (tmp / "SOURCE-MANIFEST.json").write_text(text)
        (tmp / "README.md").write_text(readme(manifest))
        names = sorted(p.name for p in tmp.iterdir())
        (tmp / "SHA256SUMS").write_text("".join(f"{sha256_file(tmp / n)}  {n}\n" for n in names))
        check(tmp)
        tmp.rename(out)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    say(f"source: {out} ({manifest['status']}; {len(manifest['git'])} trees, {len(manifest['files'])} files)")
    return manifest


def check(out):
    """OUT's SHA256SUMS covers exactly its files, each unchanged; its archives read to the end."""
    out = Path(out)
    listed = {}
    for line in (out / "SHA256SUMS").read_text().splitlines():
        sha, separator, name = line.partition("  ")
        if not separator or not re.fullmatch(r"[0-9a-f]{64}", sha) or not name or name in listed:
            raise Stop(f"{out}: malformed or duplicate SHA256SUMS entry")
        listed[name] = sha
    present = {p.name for p in out.iterdir() if p.name != "SHA256SUMS"}
    if any(p.is_symlink() or not p.is_file() for p in out.iterdir()):
        raise Stop(f"{out} holds something other than regular files")
    if set(listed) != present:
        raise Stop(f"{out}: SHA256SUMS lists {sorted(set(listed) ^ present)} wrongly")
    for name, sha in listed.items():
        if sha256_file(out / name) != sha:
            raise Stop(f"{out}/{name} does not match SHA256SUMS")
        if name.endswith((".tar", ".tar.gz")):
            with tarfile.open(out / name) as t:
                for m in t:
                    pass


def main():
    ap = argparse.ArgumentParser(prog="pp source", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--build", help="a pp build output directory (provenance.txt, pins.lock, SHA256SUMS, the IPA)")
    g.add_argument("--rev", help="a Playport commit, when no build output is named (default HEAD)")
    ap.add_argument("--offline", action="store_true", help="fetch and download nothing; use only what is here")
    ap.add_argument("--run", help="the run tree with the generated files (default $PLAYPORT_BUILD/run)")
    ap.add_argument("--check", action="store_true", help="only check OUT's SHA256SUMS and archives")
    a = ap.parse_args()
    if a.check and (a.build or a.rev or a.run or a.offline):
        ap.error("--check cannot be combined with packing options")
    try:
        if a.check:
            check(a.out)
            print(f"source: {a.out} matches its SHA256SUMS")
        else:
            bundle(a.out, build=a.build, rev=a.rev, offline=a.offline, run_dir=a.run)
    except (Stop, OSError, ValueError, KeyError, tarfile.TarError) as exc:
        sys.exit(f"pp source: {exc}")


if __name__ == "__main__":
    main()

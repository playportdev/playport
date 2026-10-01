#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assemble a local release draft; optionally upload a GitHub draft (never publish).

  pp release VERSION [--no-build] [--no-github]

Require a clean, pushed HEAD, matching versions, exact clean build provenance,
verified unsigned release IPA and checksum-checked, build-associated sources.
--no-github permits private incomplete preparation, not permission to distribute.
GitHub uploads additionally require --distribution verification of the IPA and
its attached, byte-identical notices. Incomplete sources stay labelled incomplete,
even in a private GitHub draft. Human approval and the other release-plan gates
are separate requirements; this command neither grants nor records approval.

Assemble atomically under $PLAYPORT_BUILD/releases/vVERSION; checksum every asset,
including notes, instructions and the release manifest. Never overwrite existing
outputs or follow symlink inputs. GitHub's repository and target are explicit.
No raw upload command is printed for an unverified local draft.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath

REPO = Path(__file__).resolve().parent.parent
PLISTS = ("app/Info.plist", "app/PlayportJIT-Info.plist")
INSTRUCTIONS = ("docs/DISTRIBUTION.md", "docs/BUILDING.md", "docs/DEVICE.md",
                "docs/LICENSING.md", "docs/NOTICES.md")
spec = importlib.util.spec_from_file_location("release_source_bundle", REPO / "build/source-bundle.py")
sb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sb)


class Stop(Exception):
    pass


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def no_links(path):
    """Also reject dangling links and symlink ancestors, before resolving a path."""
    path = Path(path).absolute()
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise Stop("symlink input/output path refused")
    return path


def regular(path):
    path = no_links(path)
    if not stat.S_ISREG(path.stat().st_mode):
        raise Stop(f"{path.name} is not a regular file")
    return path


def safe_name(name):
    return (isinstance(name, str) and name and not name.startswith("/") and "\\" not in name
            and ":" not in name and all(p not in ("", ".", "..") for p in name.split("/"))
            and not any(ord(c) < 32 or ord(c) == 127 for c in name))


def version_problems(version, repo=REPO):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        return [f"version {version!r} is not x.y.z"]
    problems = []
    for rel in PLISTS:
        got = plistlib.loads(regular(repo / rel).read_bytes()).get("CFBundleShortVersionString")
        if got != version:
            problems.append(f"{rel} CFBundleShortVersionString is {got!r}, not {version!r}")
    return problems


def git(repo, *args, run=subprocess.run, binary=False):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_REPLACE_OBJECTS="1",
               GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    r = run(["git", "--no-replace-objects", "-C", str(repo), *args], capture_output=True, text=not binary, env=env)
    if r.returncode:
        raise Stop(f"git {' '.join(args)} failed")
    return r.stdout


def clean_head(repo, run=subprocess.run):
    """Require this exact checkout, not an enclosing/ambient Git repository."""
    if Path(git(repo, "rev-parse", "--show-toplevel", run=run).strip()).resolve() != repo.resolve():
        raise Stop("release repository is not its own Git checkout")
    status = git(repo, "status", "--porcelain", "--untracked-files=all", run=run)
    if status.strip():
        raise Stop("the checkout has changes; commit or remove them first")
    head = git(repo, "rev-parse", "--verify", "HEAD^{commit}", run=run).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise Stop("invalid HEAD commit")
    if not git(repo, "branch", "-r", "--contains", head, run=run).strip():
        raise Stop(f"HEAD {head[:8]} is on no remote branch; push it first")
    return head


def github_repo(repo, run):
    url = git(repo, "remote", "get-url", "origin", run=run).strip()
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                         r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", url)
    if not match or any(p in (".", "..") for p in match.group(1).split("/")):
        raise Stop("origin is not an explicit GitHub repository")
    # Match origin's cached refs, not a different remote's branch. No fetch here.
    if not git(repo, "for-each-ref", "--format=%(refname)", "--contains", "HEAD", "refs/remotes/origin/", run=run).strip():
        raise Stop("HEAD is on no origin remote branch")
    return match.group(1)


def provenance(ipa, head):
    regular(ipa)
    lines = regular(ipa.parent / "provenance.txt").read_text().splitlines()
    if "(with local changes)" in "\n".join(lines):
        raise Stop("output was built with local changes")
    if [l for l in lines if l.startswith("superproject ")] != [f"superproject {head}"] \
            or [l for l in lines if l.startswith("variant ")] != ["variant release unsigned"]:
        raise Stop("output has no exact clean unsigned release provenance of HEAD")
    series = [l.split()[1] for l in lines if l.startswith("series ") and len(l.split()) > 1]
    if len(series) != len(set(series)) or any(not re.fullmatch(
            r"variant release unsigned|superproject [0-9a-f]{40}|series [a-z0-9-]+ [0-9a-f]{16}", l) for l in lines):
        raise Stop("malformed or duplicate build provenance")
    return lines


def find_output(out, head):
    out = no_links(out)
    candidates = list(out.glob("*/Playport-*-release-unsigned-*.ipa"))
    for p in candidates:
        regular(p)
        regular(p.parent / "provenance.txt")
    for ipa in sorted(candidates, key=lambda p: p.stat().st_mtime, reverse=True):
        lines = (ipa.parent / "provenance.txt").read_text().splitlines()
        if any(l.startswith(f"superproject {head}") for l in lines):
            provenance(ipa, head)
            return ipa
    raise Stop(f"no unsigned release output of {head[:8]} (run without --no-build)")


def read_sums(root):
    """Parse only flat, unique checksum names; never interpret a listed path."""
    sums = {}
    for line in regular(root / "SHA256SUMS").read_text().splitlines():
        m = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not m or not safe_name(m[2]) or "/" in m[2] or m[2] == "SHA256SUMS" or m[2] in sums:
            raise Stop("malformed or duplicate SHA256SUMS entry")
        sums[m[2]] = m[1]
    return sums


def build_records(ipa, head, repo, run):
    """Validate pipeline's two-entry checksum contract, not a flat source bundle.

    logs/ and records/ are producer-only outputs: never traverse, copy or attach
    them. Provenance and pins are separate regular inputs, not producer checksum
    entries; retain their original bytes and recheck them before publication of
    the local assembly. Source packing additionally verifies pins/series.
    """
    no_links(ipa.parent)
    sums = read_sums(ipa.parent)
    if set(sums) != {ipa.name, "artifacts.tsv"} or {p.name for p in ipa.parent.glob("*.ipa")} != {ipa.name}:
        raise Stop("build checksums/output do not name exactly the selected IPA and artifacts.tsv")
    for name, sha in sums.items():
        if sha256(regular(ipa.parent / name)) != sha:
            raise Stop("build file differs from SHA256SUMS")
    provenance(ipa, head)
    prov = regular(ipa.parent / "provenance.txt").read_bytes()
    pins = regular(ipa.parent / "pins.lock").read_bytes()
    if pins != git(repo, "show", f"{head}:pins.lock", run=run, binary=True):
        raise Stop("build pins.lock does not match HEAD")
    return {"sums": sums, "provenance": prov, "pins": pins}


def checksums(root):
    """Exact flat inventory for source/release assets, NOT pipeline output dirs."""
    no_links(root)
    files = {p.name: regular(p) for p in root.iterdir()}
    sums = read_sums(root)
    if set(sums) != set(files) - {"SHA256SUMS"}:
        raise Stop("SHA256SUMS does not cover exact file inventory")
    if any(sha256(files[n]) != s for n, s in sums.items()):
        raise Stop("file differs from SHA256SUMS")
    return sums


def source_record(root, ipa, head, ipa_sha, lines, repo, run):
    sums = checksums(root)
    data = json.loads((root / "SOURCE-MANIFEST.json").read_text())
    catalog = git(repo, "show", f"{head}:build/source-bundle.json", run=run, binary=True)
    if data.get("schema") != 1 or data.get("playport") != head \
            or data.get("catalog_sha256") != hashlib.sha256(catalog).hexdigest():
        raise Stop("source manifest does not match HEAD/catalog")
    if data.get("build") != {"output": ipa.parent.name, "ipa": ipa.name, "ipa_sha256": ipa_sha, "provenance": lines}:
        raise Stop("source manifest does not match selected IPA/build provenance")
    missing = data.get("missing")
    if not isinstance(missing, list) or data.get("status") != ("incomplete" if missing else "complete"):
        raise Stop("source completeness status contradicts missing sources")
    if any(m not in missing for m in json.loads(catalog).get("missing", [])):
        raise Stop("source manifest hides catalog missing sources")
    entries = data["git"] + data["files"] + data["run_files"] + ([data["crates"]] if data.get("crates") else [])
    names = [e["archive"] for e in entries]
    if len(names) != len(set(names)) or set(names) != set(sums) - {"README.md", "SOURCE-MANIFEST.json"}:
        raise Stop("source manifest does not cover exact file inventory")
    if any(e.get("sha256", sums[e["archive"]]) != sums[e["archive"]] for e in entries):
        raise Stop("source manifest/checksum disagreement")
    if (root / "README.md").read_text() != sb.readme(data):
        raise Stop("source README does not match manifest/completeness")
    return data


def tar_files(files, dest, prefix):
    """Sorted deterministic tar of explicit regular files; nested paths allowed."""
    with tarfile.open(dest, "x", format=tarfile.PAX_FORMAT) as tar:
        for name, path in sorted(files.items()):
            if not safe_name(name):
                raise Stop("unsafe tar asset name")
            path = regular(path)
            info = tarfile.TarInfo(f"{prefix}/{name}")
            info.size, info.mode, info.mtime = path.stat().st_size, 0o644, 0
            with path.open("rb") as source:
                tar.addfile(info, source)


def extract_notices(ipa, dest):
    """Copy only Playport.app/Licenses, never arbitrary IPA members or links."""
    prefix = "Payload/Playport.app/Licenses/"
    names = set()
    with zipfile.ZipFile(ipa) as archive:
        for info in archive.infolist():
            if not info.filename.startswith(prefix):
                continue
            name = info.filename[len(prefix):].rstrip("/")
            if not name and info.is_dir():
                continue
            if not safe_name(name) or name in names:
                raise Stop("unsafe or duplicate IPA notice path")
            names.add(name)
            mode = info.external_attr >> 16
            if stat.S_IFMT(mode) not in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG):
                raise Stop("non-regular IPA notice member")
            path = dest.joinpath(*PurePosixPath(name).parts)
            if info.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as source, path.open("xb") as target:
                    shutil.copyfileobj(source, target)
    return {p.relative_to(dest).as_posix(): regular(p) for p in dest.rglob("*") if not p.is_dir()}


def notes(version, head, ipa_name, ipa_sha, size, source_name, source_sha, source):
    gaps = "\n".join(f"- {m['what']}: {m['why']}" for m in source["missing"]) or "- No catalogued missing sources."
    return f"""# Playport {version} (draft)

**Draft pre-release. Do not publish.** Local preparation and even a private upload
are not permission to distribute; the source/IPA release-plan gates and explicit
owner approval still apply. This command never publishes.

Built from commit `{head}` with `pp release {version}`.

| File | sha256 |
| --- | --- |
| `{ipa_name}` ({size / 1e6:.0f} MB) | `{ipa_sha}` |
| `{source_name}` | `{source_sha}` |

## Source status: {source['status']}

This archive is the Corresponding Source of the IPA above, packed from the
exact commits its build used. Its manifest and README are inside. Known gaps:

{gaps}

## Install, rebuild and notices

`INSTALL-REBUILD.tar` carries the build commit's distribution, build, device,
licensing and notice instructions. Resolve their relative links in the supplied
Playport snapshot.
`NOTICES.tar`, when present, contains the IPA's exact Licenses/ bytes (no substitute
from a current staging directory). A GitHub upload requires --distribution
verification against those bytes; a local --no-github assembly does not.

The IPA is signed ad hoc with no certificate or profile. Sign again with your
own Apple ID, preserving increased-memory-limit and the JIT helper extension.
Bring your own games. Playport is GPL-3.0-or-later with LICENSE-EXCEPTION.md;
components keep their licences. No warranty except where the law requires one.

## Before publishing

- Complete and validate exact source, notices and usable rebuild/relink instructions.
- Demonstrate recipient signing, installation and JIT; retain matching source.
- Review the final payloads and all release-plan human/platform/privacy gates.
- Attach no Apple SDK, private signing/device data or games.
- Obtain explicit owner approval of the remote, history, upload and publication.

SHA256SUMS covers every attached asset, including these notes and RELEASE-MANIFEST.json.
"""


def release(version, repo=REPO, build_dir=None, build=True, github=True, run=subprocess.run, which=shutil.which,
            say=print):
    repo = no_links(repo)
    problems = version_problems(version, repo)
    if problems:
        raise Stop("; ".join(problems))
    build_dir = no_links(build_dir or os.environ.get("PLAYPORT_BUILD") or repo / ".work")
    out = no_links(os.environ.get("PLAYPORT_OUT") or build_dir / "out")
    # Fence inherited Git and path overrides; every child runs from the named repo.
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "PLAYPORT_"))}
    env.pop("GH_REPO", None)
    env.update(GH_HOST="github.com", PLAYPORT_REPO=str(repo), PLAYPORT_BUILD=str(build_dir), PLAYPORT_OUT=str(out),
               PLAYPORT_RUN=str(build_dir / "run"), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")

    def invoke(cmd, **kwargs):
        return run(cmd, cwd=repo, env=env, **kwargs)

    head = clean_head(repo, run)
    target_repo = github_repo(repo, run) if github else None
    say(f"release {version}: HEAD {head[:8]}")
    dest = no_links(build_dir / "releases" / f"v{version}")
    if dest.exists():
        raise Stop("release directory already exists; remove it to assemble again")
    if build:
        say("release: clean unsigned release build")
        if invoke([str(repo / "build/pipeline"), "--variant", "release", "--unsigned", "--clean"]).returncode:
            raise Stop("the build failed")
    if clean_head(repo, run) != head:
        raise Stop("the build changed HEAD")
    ipa = find_output(out, head)
    records = build_records(ipa, head, repo, run)
    lines = records["provenance"].decode().splitlines()
    ipa_sha = records["sums"][ipa.name]
    for name, cmd in (("names", [str(repo / "pp"), "names"]), ("secrets", [str(repo / "pp"), "secrets"]),
                      ("verify", [sys.executable, str(repo / "build/verify-ipa.py"), str(ipa), "--variant", "release",
                                  "--unsigned", "--sha256", ipa_sha])):
        if invoke(cmd).returncode:
            raise Stop(f"{name} failed")
    ipa_name, source_name = f"Playport-{version}.ipa", f"Playport-{version}-source.tar"
    part = no_links(dest.with_name(f".{dest.name}.partial-{os.getpid()}"))
    if part.exists():
        raise Stop("partial output already exists; refusing to remove it")
    part.mkdir(parents=True)
    try:
        if invoke([sys.executable, str(repo / "build/source-bundle.py"), str(part / "source"),
                   "--build", str(ipa.parent)]).returncode:
            raise Stop("pp source failed")
        source = source_record(part / "source", ipa, head, ipa_sha, lines, repo, run)
        source_manifest_sha = sha256(part / "source/SOURCE-MANIFEST.json")
        tar_files({p.name: p for p in (part / "source").iterdir()}, part / source_name, Path(source_name).stem)
        shutil.rmtree(part / "source")
        shutil.copyfile(regular(ipa), part / ipa_name)
        if sha256(part / ipa_name) != ipa_sha:
            raise Stop("the IPA changed while it was copied")
        for name in ("provenance.txt", "artifacts.tsv"):
            shutil.copyfile(regular(ipa.parent / name), part / name)
            expected = records["sums"][name] if name == "artifacts.tsv" else hashlib.sha256(records["provenance"]).hexdigest()
            if sha256(part / name) != expected:
                raise Stop("build records changed during assembly")
        payloads = extract_notices(part / ipa_name, part / "notices")
        if github:
            if not payloads:
                raise Stop("no matching notices to attach for GitHub upload")
            cmd = [sys.executable, str(repo / "build/verify-ipa.py"), str(part / ipa_name), "--variant", "release",
                   "--unsigned", "--sha256", ipa_sha, "--distribution", "--notices", str(part / "notices")]
            if invoke(cmd).returncode:
                raise Stop("distribution notice verification failed; no upload")
        if payloads:
            tar_files(payloads, part / "NOTICES.tar", "Licenses")
        if (part / "notices").exists():
            shutil.rmtree(part / "notices")
        instructions = part / "instructions"
        instructions.mkdir()
        for rel in INSTRUCTIONS:
            path = instructions / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(git(repo, "show", f"{head}:{rel}", run=run, binary=True))
        tar_files({rel: instructions / rel for rel in INSTRUCTIONS}, part / "INSTALL-REBUILD.tar", "INSTALL-REBUILD")
        shutil.rmtree(instructions)
        (part / "RELEASE-NOTES.md").write_text(notes(version, head, ipa_name, ipa_sha, ipa.stat().st_size,
                                                     source_name, sha256(part / source_name), source))
        files = {p.name: {"sha256": sha256(p), "size": p.stat().st_size} for p in sorted(part.iterdir())}
        manifest = {"schema": 1, "head": head, "version": version, "ipa_sha256": ipa_sha,
                    "source_manifest_sha256": source_manifest_sha, "source_status": source["status"],
                    "missing": source["missing"], "distribution_notices_verified": github,
                    "publication_approved": False, "github_repository": target_repo, "files": files}
        (part / "RELEASE-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
        assets = sorted(p.name for p in part.iterdir())
        (part / "SHA256SUMS").write_text("".join(f"{sha256(part / a)}  {a}\n" for a in assets))
        assembled_sums = checksums(part)
        if build_records(ipa, head, repo, run) != records:
            raise Stop("build records changed during assembly")
        if clean_head(repo, run) != head:
            raise Stop("HEAD changed during assembly")
        if dest.exists() or dest.is_symlink():
            raise Stop("release directory appeared during assembly")
        part.rename(dest)
    except BaseException:
        shutil.rmtree(part, ignore_errors=True)
        raise
    say(f"release: assembled local draft ({source['status']} sources); not distribution approval")
    if not github:
        say("release: no GitHub draft created (--no-github); no upload command supplied")
        return dest
    if not which("gh") or invoke(["gh", "auth", "status"], capture_output=True).returncode:
        say("release: no GitHub draft created (gh missing or not logged in)")
        return dest
    if invoke(["gh", "release", "view", f"v{version}", "--repo", target_repo], capture_output=True).returncode == 0:
        raise Stop(f"a release v{version} already exists on GitHub; local assembly retained")
    if checksums(dest) != assembled_sums:
        raise Stop("assembled assets changed before upload")
    if clean_head(repo, run) != head:
        raise Stop("HEAD changed before upload")
    cmd = ["gh", "release", "create", f"v{version}", "--repo", target_repo, "--draft", "--prerelease", "--target", head,
           "--title", f"Playport {version}", "--notes-file", str(dest / "RELEASE-NOTES.md"),
           *[str(dest / a) for a in assets + ["SHA256SUMS"]]]
    if invoke(cmd).returncode:
        raise Stop("gh release create failed; local assembly retained")
    say(f"release: draft v{version} created (not published)")
    return dest


def main():
    ap = argparse.ArgumentParser(prog="pp release", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version")
    ap.add_argument("--no-build", action="store_true", help="use the newest unsigned release output of HEAD")
    ap.add_argument("--no-github", action="store_true", help="private local assembly only; no upload command")
    a = ap.parse_args()
    try:
        release(a.version, build=not a.no_build, github=not a.no_github)
    except (Stop, OSError, ValueError, KeyError, tarfile.TarError, zipfile.BadZipFile) as exc:
        sys.exit(f"pp release: {exc}")


if __name__ == "__main__":
    main()

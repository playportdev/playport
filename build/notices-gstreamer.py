#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline preparatory GStreamer/Cerbero source-notice inventory, NOT IPA provenance."""

import argparse
import ast
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import tarfile
import tempfile

LOCK = "build/gstreamer-notices.sources.json"
NOTICE = re.compile(r"^(licen[cs]e|copying|copyright|notice|unlicense|authors|patents)", re.I)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_name(name):
    if (not isinstance(name, str) or not name or name.startswith("/") or
            "\\" in name or ":" in name or any(ord(c) < 32 or ord(c) == 127 for c in name) or
            any(p in ("", ".", "..") for p in name.split("/"))):
        raise ValueError("unsafe archive/lock path")
    return name


def no_links(path):
    path = Path(os.path.abspath(path))
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("symlinked filesystem input/output")
    return path


def archive(path, spec):
    """Read the same checksum-verified bytes; never extract filesystem paths.

    Internal single-hop symlinks to regular files are recorded, not followed on
    disk. This is needed for GLib's two COPYING aliases. Hardlinks, chains,
    escapes, dangling links, specials and ambiguous members are refused.
    """
    path = no_links(path)
    if not path.is_file():
        raise ValueError("missing source archive")
    data = path.read_bytes()
    if digest(data) != spec["sha256"]:
        raise ValueError("source archive checksum mismatch")
    root = safe_name(spec["root"])
    files, links, kinds = {}, {}, {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
        for member in tar:
            name = safe_name(member.name.rstrip("/") if member.isdir() else member.name)
            if name != root and not name.startswith(root + "/"):
                raise ValueError("wrong archive root")
            if name in kinds:
                raise ValueError("duplicate archive member")
            kinds[name] = "directory" if member.isdir() else "file"
            rel = name[len(root) + 1:] if name != root else ""
            if member.isdir():
                continue
            if not rel:
                raise ValueError("non-directory archive root")
            if member.isfile():
                total += member.size
                if member.size < 0 or total > 512 * 1024 * 1024:
                    raise ValueError("oversized source inventory")
                files[rel] = tar.extractfile(member).read()
            elif member.issym():
                target = member.linkname
                if (not target or target.startswith("/") or "\\" in target or ":" in target or
                        any(ord(c) < 32 or ord(c) == 127 for c in target)):
                    raise ValueError("unsafe archive symlink")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(rel), target))
                safe_name(resolved)
                links[rel] = {"target": target, "resolved": resolved}
            else:
                raise ValueError("unsupported archive member")
    for name in kinds:
        for parent in PurePosixPath(name).parents:
            if str(parent) in kinds and kinds[str(parent)] != "directory":
                raise ValueError("archive file/directory collision")
    for link in links.values():
        if link["resolved"] not in files:
            raise ValueError("dangling/chained/non-regular archive symlink")
    return files, links


def literal_assignment(data, field):
    tree = ast.parse(data)
    recipe = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Recipe"]
    if len(recipe) != 1:
        raise ValueError("ambiguous recipe class")
    values = [n.value for n in recipe[0].body if isinstance(n, ast.Assign) and
              any(isinstance(t, ast.Name) and t.id == field for t in n.targets)]
    if len(values) != 1:
        raise ValueError("missing/ambiguous literal recipe declaration")
    return ast.literal_eval(values[0])


def load_lock(repo):
    path = no_links(repo / LOCK)
    data = path.read_bytes()
    committed = subprocess.run(["git", "-C", str(repo), "show", "HEAD:" + LOCK],
                               capture_output=True, check=True).stdout
    if data != committed:
        raise ValueError("source review lock must match committed bytes")
    lock = json.loads(data)
    if lock["schema"] != 1 or lock["status"] != "preparatory-source-review-not-binary-build-lock":
        raise ValueError("unsupported source review lock")
    stage = no_links(repo / "build/stages/gstreamer.sh").read_bytes()
    pins = no_links(repo / "pins.lock").read_text().splitlines()
    gst = [l.split() for l in pins if l.split() and l.split()[0] == "gstreamer"]
    if (len(gst) != 1 or gst[0][1] != lock["release"] or
            digest(stage) != lock["stage_sha256"] or
            ("SHA256=" + lock["binary_archive_sha256"]).encode() not in stage):
        raise ValueError("build stage/pin differs from reviewed release")
    for spec in (lock["cerbero"], *lock["components"].values()):
        for key in ("archive", "root"):
            safe_name(spec[key])
        if "/" in spec["archive"] or not re.fullmatch(r"[0-9a-f]{64}", spec["sha256"]):
            raise ValueError("invalid locked archive identity")
    for name, spec in lock["components"].items():
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ValueError("unsafe component name")
        safe_name(spec["recipe"])
        if not spec["required_notices"]:
            raise ValueError("empty mandatory notice list")
        for notice in spec["required_notices"]:
            safe_name(notice)
    return lock, digest(data)


def prepare(repo, cerbero_path, sources, output, selected=None):
    repo, sources, output = map(no_links, (repo, sources, output))
    # Only outputs under this worktree's .work; inputs may be read-only caches.
    if not output.is_relative_to(repo / ".work"):
        raise ValueError("output must be inside repository .work")
    if output.exists():
        raise ValueError("output already exists")
    for source in (no_links(cerbero_path), sources):
        if output.is_relative_to(source) or source.is_relative_to(output):
            raise ValueError("input/output overlap")
    lock, lock_hash = load_lock(repo)
    selected = list(lock["components"]) if selected is None else selected
    if not selected or len(set(selected)) != len(selected) or set(selected) - lock["components"].keys():
        raise ValueError("empty/duplicate/unknown component selection")
    cerbero, _ = archive(cerbero_path, lock["cerbero"])
    required = dict(lock["cerbero"]["review_files"])
    required.update({s["recipe"]: s["recipe_sha256"] for s in lock["components"].values()})
    for name, expected in required.items():
        if name not in cerbero or digest(cerbero[name]) != expected:
            raise ValueError("Cerbero reviewed recipe/configuration checksum mismatch")
    for spec in lock["components"].values():
        if literal_assignment(cerbero[spec["recipe"]], "tarball_checksum") != spec["sha256"]:
            raise ValueError("source checksum differs from Cerbero recipe")
        if not spec["recipe"].startswith("recipes/gst"):
            if literal_assignment(cerbero[spec["recipe"]], "version") != spec["version"]:
                raise ValueError("source version differs from Cerbero recipe")
    manifest = {
        "schema": 1, "status": "incomplete-preparatory-notice-superset",
        "scope": "Checksum-verified recipe-associated source notices, not binary derivation, linked-code coverage, Corresponding Source or IPA approval",
        "lock_sha256": lock_hash, "release": lock["release"],
        "cerbero": {"commit": lock["cerbero"]["commit"], "archive_sha256": lock["cerbero"]["sha256"],
                    "archive_root": lock["cerbero"]["root"],
                    "reviewed_files": required,
                    "files": {p: {"sha256": digest(b), "size": len(b)} for p, b in sorted(cerbero.items())}},
        "omitted_components": sorted(set(lock["components"]) - set(selected)),
        "unresolved": lock["unresolved"], "components": {},
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=output.name + ".partial.") as temp:
        stage = Path(temp) / "inventory"
        stage.mkdir()
        for name in sorted(selected):
            spec = lock["components"][name]
            files, links = archive(sources / spec["archive"], spec)
            candidates = {p for p in (*files, *links) if NOTICE.match(PurePosixPath(p).name) or
                          "LICENSES" in PurePosixPath(p).parts}
            candidates.update(spec["required_notices"])
            notices = {}
            for source in sorted(candidates):
                resolved = links[source]["resolved"] if source in links else source
                if resolved not in files:
                    raise ValueError("missing mandatory notice")
                data = files[resolved]
                target = f"notices/{name}/{source}"
                dest = stage / target
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
                notices[source] = {"output": target, "archive_member": spec["root"] + "/" + resolved,
                                   "sha256": digest(data), "size": len(data)}
                if source in links:
                    notices[source]["alias"] = links[source]
            manifest["components"][name] = {
                "version": spec["version"], "recipe": spec["recipe"],
                "archive": spec["archive"], "archive_root": spec["root"],
                "archive_sha256": spec["sha256"], "reviewed_download_url": spec["reviewed_download_url"],
                "files": {p: {"sha256": digest(b), "size": len(b)} for p, b in sorted(files.items())},
                "symlinks": links, "notices": notices,
            }
        # Recheck created bytes and coverage before publishing; no extraction,
        # recipe execution, network, cache writes or compilation occurs here.
        expected = {n["output"]: n for c in manifest["components"].values() for n in c["notices"].values()}
        actual = {p.relative_to(stage).as_posix() for p in stage.rglob("*") if p.is_file()}
        if actual != expected.keys():
            raise ValueError("notice output coverage mismatch")
        for filename, record in expected.items():
            data = no_links(stage / filename).read_bytes()
            if digest(data) != record["sha256"] or len(data) != record["size"]:
                raise ValueError("notice copy checksum mismatch")
        (stage / "gstreamer-source-inventory.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        result = subprocess.run(["mv", "-T", "-n", "--", str(stage), str(output)], capture_output=True)
        if result.returncode or stage.exists():
            raise ValueError("output appeared during preparation or publication failed")
    return manifest


MANIFEST = "gstreamer-provenance.json"
PREFIX = "gstreamer-source-"


@contextmanager
def prepared(repo, cerbero_path, sources):
    """Recompute the complete standalone inventory in private, disposable scratch."""
    repo = no_links(repo)
    scratch = repo / ".work/tmp"
    no_links(scratch).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch, prefix="gstreamer-assembly.") as temp:
        root = Path(temp) / "prepared"
        manifest = prepare(repo, cerbero_path, sources, root)
        yield manifest, root


def assembly_payloads(manifest):
    """Flatten names only; preserve all original member/alias/source origins."""
    if (manifest["schema"] != 1 or
            manifest["status"] != "incomplete-preparatory-notice-superset" or
            manifest["omitted_components"] or not manifest["components"]):
        raise ValueError("assembly requires the complete preparatory component set")
    result = {}
    for component, record in manifest["components"].items():
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", component):
            raise ValueError("unsafe assembly component")
        for source, origin in record["notices"].items():
            safe_name(source)
            if origin["output"] != f"notices/{component}/{source}":
                raise ValueError("unexpected preparatory notice origin")
            name = PREFIX + component + "-" + source.replace("/", "-")
            if name in result:
                raise ValueError("flattened GStreamer notice collision")
            result[name] = origin
    return result


def assembly_output(repo, cerbero_path, sources, output):
    repo, output = map(no_links, (repo, output))
    if not output.is_dir():
        raise ValueError("assembly output must be an existing directory")
    for source in (no_links(cerbero_path), no_links(sources), repo / "build"):
        if output.is_relative_to(source) or source.is_relative_to(output):
            raise ValueError("assembly input/output overlap")
    return repo, output


def collect(repo, cerbero_path, sources, output):
    """Add a full preparatory superset, never claiming producer/IPA derivation."""
    repo, output = assembly_output(repo, cerbero_path, sources, output)
    created = []
    with prepared(repo, cerbero_path, sources) as (manifest, root):
        origins = assembly_payloads(manifest)
        if any(p.name.startswith(PREFIX) or p.name == MANIFEST for p in output.iterdir()):
            raise ValueError("GStreamer assembly output already exists")
        try:
            for name, origin in origins.items():
                data = no_links(root / origin["output"]).read_bytes()
                if digest(data) != origin["sha256"] or len(data) != origin["size"]:
                    raise ValueError("GStreamer prepared copy changed")
                path = output / name
                with path.open("xb") as stream:
                    created.append(path)
                    stream.write(data)
            path = output / MANIFEST
            with path.open("x") as stream:
                created.append(path)
                stream.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            verify_payloads(output, manifest)
        except BaseException:
            for path in reversed(created):
                path.unlink()
            raise
    return manifest


def verify_payloads(output, manifest):
    origins = assembly_payloads(manifest)
    actual = {p.name for p in output.iterdir() if p.name.startswith(PREFIX)}
    if actual != set(origins):
        raise ValueError("GStreamer assembly payload coverage mismatch")
    for name, origin in origins.items():
        path = no_links(output / name)
        if not path.is_file():
            raise ValueError("non-regular GStreamer notice payload")
        data = path.read_bytes()
        if digest(data) != origin["sha256"] or len(data) != origin["size"]:
            raise ValueError("GStreamer assembly payload changed")


def validate(repo, cerbero_path, sources, output):
    """Recheck lock, archives, complete origins and every payload before publication."""
    repo, output = assembly_output(repo, cerbero_path, sources, output)
    manifest = json.loads(no_links(output / MANIFEST).read_text())
    with prepared(repo, cerbero_path, sources) as (expected, _):
        if manifest != expected:
            raise ValueError("GStreamer assembly provenance differs from verified sources")
        verify_payloads(output, expected)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cerbero_archive", type=Path)
    parser.add_argument("source_archives", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--component", action="append", help="Explicit partial subset; default requires all 17 locked sources")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--assemble", action="store_true", help="Copy flat superset into an existing notice assembly")
    mode.add_argument("--verify-assembly", action="store_true", help="Recompute sources and verify an existing assembly")
    args = parser.parse_args()
    if args.component and (args.assemble or args.verify_assembly):
        parser.error("assembly requires all locked components; --component is standalone only")
    try:
        if args.assemble:
            manifest = collect(args.repo, args.cerbero_archive, args.source_archives, args.output)
        elif args.verify_assembly:
            manifest = validate(args.repo, args.cerbero_archive, args.source_archives, args.output)
        else:
            manifest = prepare(args.repo, args.cerbero_archive, args.source_archives, args.output, args.component)
    except (ValueError, OSError, KeyError, SyntaxError, tarfile.TarError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"gstreamer source inventory refused: {error}\n")
    print(f"Preparatory superset: {len(manifest['components'])} components; release gate remains open")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare a separate offline notice Cargo home from committed locked archives."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("notices_rust", Path(__file__).with_name("notices-rust.py"))
rust = module_from_spec(spec)
spec.loader.exec_module(rust)


def prepare(repo, idevice, home, scratch, output):
    if output.exists() or output.is_symlink():
        raise ValueError("notice Cargo home already exists")
    if output.resolve().is_relative_to(home.resolve()) or home.resolve().is_relative_to(output.resolve()):
        raise ValueError("notice Cargo home must be separate from build Cargo home")
    pins = {p[0]: p[1] for line in (repo / "pins.lock").read_text().splitlines()
            if (p := line.split()) and not line.startswith("#")}
    tree = rust.provenance.verify_tree(idevice, pins["idevice"], [], scratch)
    rust.provenance.tracked_file(idevice, idevice / "Cargo.lock")
    locked = tomllib.loads((idevice / "Cargo.lock").read_text())["package"]
    index = rust.no_links(home, Path("registry/index"))
    cache = rust.no_links(home, Path("registry/cache"))
    if not index.is_dir() or not cache.is_dir():
        raise ValueError("missing offline Cargo index/archive cache")
    # Never read registry/src: builds may write generated files there. Do not
    # copy executables, credentials, Cargo configuration or toolchain state.
    for path in index.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError("non-regular file or symlink in offline Cargo index")
    records = []
    identities = set()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=output.name + ".partial.") as temporary:
        stage = Path(temporary) / "cargo"
        shutil.copytree(index, stage / "registry/index")
        for package in locked:
            source = package.get("source")
            if source is None:
                continue
            if source != rust.REGISTRY:
                raise ValueError(f"unsupported locked crate source: {package['name']}")
            name, version = package["name"], package["version"]
            # Validate identity before using it in filesystem paths.
            if not all(re.fullmatch(r"[A-Za-z0-9_.+-]+", item) for item in (name, version)):
                raise ValueError("invalid locked crate identity")
            if (name, version) in identities:
                raise ValueError("duplicate locked crate identity")
            identities.add((name, version))
            candidates = list(cache.glob(f"*/{name}-{version}.crate"))
            if len(candidates) != 1:
                raise ValueError(f"missing/ambiguous locked crate archive: {name}-{version}")
            archive = rust.no_links(home, candidates[0].relative_to(home))
            files = rust.locked_archive(archive, package)
            if any(marker in files for marker in (".cargo-ok", ".cargo-checksum.json")):
                raise ValueError("crate archive contains reserved Cargo cache marker")
            relative_archive = archive.relative_to(home)
            saved_archive = stage / relative_archive
            saved_archive.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archive, saved_archive)
            # Detect source mutation while copying before materializing any bytes.
            if rust.locked_archive(saved_archive, package) != files:
                raise ValueError("crate archive changed while preparing notice inputs")
            source_dir = stage / "registry/src" / archive.parent.name / f"{name}-{version}"
            source_dir.mkdir(parents=True)
            hashes = {}
            for filename, data in files.items():
                path = source_dir / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                hashes[filename] = hashlib.sha256(data).hexdigest()
            # These bookkeeping markers are generated, not provenance authority.
            (source_dir / ".cargo-ok").write_text('{"v":1}\n')
            (source_dir / ".cargo-checksum.json").write_text(json.dumps(
                {"package": package["checksum"], "files": hashes}, sort_keys=True) + "\n")
            manifest = tomllib.loads(files["Cargo.toml"].decode())["package"]
            metadata = {"name": name, "version": version, "source": source,
                        "license": manifest.get("license"), "manifest_path": str(source_dir / "Cargo.toml")}
            records.append(rust.verify_crate(metadata, package, stage, home=stage))
        if not records:
            raise ValueError("Cargo.lock has no registry packages")
        data = {"schema": 1, "scope": "pristine locked registry inputs; not resolved, stdlib, linked-code or IPA provenance",
                "idevice_tree": tree["tree"], "cargo_lock_sha256": rust.provenance.digest(idevice / "Cargo.lock"),
                "crates": sorted(records, key=lambda p: (p["name"], p["version"]))}
        (stage / "notice-cache.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        # Same-filesystem publication, refusing even an empty racing destination.
        result = subprocess.run(["mv", "-T", "-n", "--", str(stage), str(output)], capture_output=True)
        if result.returncode or stage.exists():
            raise ValueError("notice Cargo home appeared during preparation or could not be published")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "idevice", "cargo_home", "scratch", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        args.scratch.mkdir(parents=True, exist_ok=True)
        data = prepare(args.repo.resolve(), args.idevice.resolve(), args.cargo_home.absolute(),
                       args.scratch.resolve(), args.output.absolute())
        print(f"{len(data['crates'])} pristine locked crates; notice inputs only")
    except (OSError, ValueError, KeyError, tarfile.TarError, EOFError) as exc:
        parser.exit(1, f"Rust notice cache: {exc}\n")


if __name__ == "__main__":
    main()

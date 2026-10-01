#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify Rust notices, iOS libraries and source inventory from locked archives.

Optional byte-for-byte source notice collection, without unpacking source paths.
No fetching, rustup invocation or build/linked-code/IPA proof.
"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tarfile
import tomllib


spec = importlib.util.spec_from_file_location("notices_rust", Path(__file__).with_name("notices-rust.py"))
rust = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rust)
HOST = "x86_64-unknown-linux-gnu"
TARGET = rust.cargo.TARGET
NOTICES = ("COPYRIGHT-library.html", *(f"licenses/{name}.txt" for name in
           ("MIT", "Apache-2.0", "BSD-2-Clause", "ISC")))


SOURCE = "rust-src/lib/rustlib/src/rust/"
SOURCE_REQUIRED = ("LICENSE-MIT", "LICENSE-APACHE", "COPYRIGHT", "version", "git-commit-hash",
                   *(SOURCE + f"library/{name}" for name in
                     ("Cargo.toml", "Cargo.lock", "core/src/lib.rs", "alloc/src/lib.rs",
                      "std/src/lib.rs", "compiler-builtins/LICENSE.txt")),
                   SOURCE + "src/llvm-project/libunwind/LICENSE.TXT")
NOTICE_PREFIXES = ("license", "licence", "copying", "copyright", "notice", "unlicense")


def read_component(path, checksum, prefix, selected=None, identity=None):
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("invalid locked Rust archive checksum")
    if path.is_symlink() or not path.is_file() or rust.provenance.digest(path) != checksum:
        raise ValueError(f"Rust distribution archive differs from lock: {path.name}")
    files = {}
    seen = {}
    release_files = {}
    archive_root = prefix.split("/")[0]
    # Stream large archives; only selected payloads are read into memory.
    with tarfile.open(path, "r|xz") as archive:
        for member in archive:
            relative = rust.safe_relative(member.name)
            if member.name in seen:
                raise ValueError(f"duplicate Rust archive member: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise ValueError(f"non-regular Rust archive member: {member.name}")
            if relative.parts[0] != archive_root:
                raise ValueError(f"unexpected Rust archive root: {member.name}")
            seen[member.name] = member.isdir()
            data = None
            if identity is not None and member.isfile() and member.name in (
                    archive_root + "/version", archive_root + "/git-commit-hash"):
                data = archive.extractfile(member).read()
                release_files[relative.name] = data
            if member.isfile() and member.name.startswith(prefix):
                name = member.name[len(prefix):]
                rust.safe_relative(name)
                if selected is None or name in selected or name.startswith("licenses/"):
                    files[name] = data if data is not None else archive.extractfile(member).read()
        for name in seen:
            if any(seen.get(parent.as_posix()) is False for parent in Path(name).parents):
                raise ValueError(f"file/directory collision in Rust archive: {name}")
    if not files or (selected is not None and not set(selected).issubset(files)):
        raise ValueError("Rust distribution archive lacks required payloads")
    if identity is not None and release_files != identity:
        raise ValueError("Rust archive release/source identity differs from lock")
    return files


def declared_notice_path(manifest, declaration):
    """Resolve a direct Cargo license-file inside the archive, never on disk.

    Cargo allows parent-relative paths. Inherited workspace declarations need
    separate resolution and are deliberately refused rather than guessed.
    """
    if (not isinstance(declaration, str) or not declaration
            or declaration.startswith("/") or "\\" in declaration or ":" in declaration
            or declaration.split("/")[-1] in ("", ".", "..")
            or any(ord(char) < 32 or ord(char) == 127 for char in declaration)):
        raise ValueError(f"invalid/unsupported Rust license-file declaration: {manifest}")
    parts = list(Path(manifest).parent.parts)
    for part in declaration.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise ValueError(f"Rust license-file escapes source archive: {manifest}")
            parts.pop()
        else:
            parts.append(part)
    if not parts:
        raise ValueError(f"invalid Rust license-file path: {manifest}")
    return "/".join(parts)


def verify_source(dist, lock, identity):
    """Inventory published source bytes, not an assertion of binary derivation."""
    locked = lock["components"]["rust-src"]
    name = f"rust-src-{lock['rust']}.tar.xz"
    if locked["target"] != "*" or locked["archive"] != name:
        raise ValueError("unexpected Rust source component identity")
    prefix = name[:-7] + "/"
    files = read_component(rust.no_links(dist, Path(name)), locked["sha256"], prefix, identity=identity)
    if not set(SOURCE_REQUIRED).issubset(files):
        raise ValueError("Rust source archive lacks required source/licence files")
    inventory = {path: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                 for path, data in files.items()}
    notices = {path: {"member": prefix + path, **inventory[path]}
               for path in files if Path(path).name.lower().startswith(NOTICE_PREFIXES)}
    # Read package declarations only. Do not invoke Cargo or treat this superset
    # (including tests, build dependencies and other platforms) as a linked graph.
    packages = []
    for path, data in sorted(files.items()):
        if path.startswith(SOURCE + "library/") and Path(path).name == "Cargo.toml":
            manifest = tomllib.loads(data.decode())
            package = manifest.get("package")
            if package is not None:
                record = {"manifest": path, "name": package["name"],
                          "version": package["version"], "license": package.get("license"),
                          "license_file": package.get("license-file")}
                if "license-file" in package:
                    notice = declared_notice_path(path, package["license-file"])
                    if notice not in files:
                        raise ValueError(f"Rust license-file lacks regular archive payload: {path}: {notice}")
                    record["license_file_source"] = notice
                    candidate = notices.setdefault(notice, {"member": prefix + notice, **inventory[notice]})
                    candidate.setdefault("declared_by", []).append(path)
                packages.append(record)
    return {"archive": name, "url": locked["url"], "archive_sha256": locked["sha256"],
            "source_commit": lock["source_commit"], "files": inventory,
            "notice_candidates": notices, "packages": packages,
            "scope": "published source/package/notice superset; not collected notices, build derivation, linked members or complete Corresponding Source"}


def collect_source_notices(dist, record, out):
    """Copy the verified candidate superset; not an applicability/header audit."""
    source = record["source"]
    prefix = source["archive"][:-7] + "/"
    candidates = source["notice_candidates"]
    files = read_component(rust.no_links(dist, Path(source["archive"])),
                           source["archive_sha256"], prefix, selected=candidates)
    payloads = {}
    origins = {}
    out = out.absolute()
    rust.no_links(Path(out.anchor), out.relative_to(out.anchor))
    if not out.is_dir():
        raise ValueError("source notice output must be an existing directory")
    for path, origin in sorted(candidates.items()):
        name = "rust-source-" + path.replace("/", "-")
        rust.safe_relative(name)
        if Path(name).name != name or len(name.encode()) > 255 or name in payloads:
            raise ValueError(f"colliding/invalid source notice output: {name}")
        if (out / name).exists() or (out / name).is_symlink():
            raise ValueError(f"source notice output already exists: {name}")
        data = files[path]
        if (hashlib.sha256(data).hexdigest() != origin["sha256"] or len(data) != origin["size"]
                or origin["member"] != prefix + path):
            raise ValueError(f"source notice changed after verification: {path}")
        payloads[name] = data
        origins[name] = {"source": path, **origin, "archive_sha256": source["archive_sha256"]}
    written = []
    try:
        for name, data in payloads.items():
            with (out / name).open("xb") as file:
                written.append(out / name)
                file.write(data)
    except OSError:
        for path in written:
            path.unlink()
        raise
    return origins


def verify(repo, root, dist):
    pins = {p[0]: p[1] for line in (repo / "pins.lock").read_text().splitlines()
            if (p := line.split()) and not line.startswith("#")}
    lock_path = repo / "build/rust-dist.lock.json"
    rust.provenance.tracked_file(repo, lock_path)
    lock = json.loads(lock_path.read_text())
    version = pins["rust"]
    if lock["schema"] != 1 or lock["rust"] != version or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Rust distribution lock disagrees with pins.lock")
    if not re.fullmatch(r"[0-9a-f]{40}", lock["source_commit"]):
        raise ValueError("invalid locked Rust source commit")
    release_pattern = re.escape(version) + r" \(" + lock["source_commit"][:9] + r" [0-9]{4}-[0-9]{2}-[0-9]{2}\)"
    if not re.fullmatch(release_pattern, lock["release"]):
        raise ValueError("Rust release identity disagrees with source commit/pin")
    identity = {"version": lock["release"].encode(), "git-commit-hash": lock["source_commit"].encode()}
    source = verify_source(dist, lock, identity)
    toolchain = Path("rustup/toolchains") / f"{version}-{HOST}"
    rust.no_links(root, toolchain)
    components = {}
    notices = {}
    for component, target, folder in (("rustc", HOST, "share/doc/rust/"),
                                      ("rust-std", TARGET, f"lib/rustlib/{TARGET}/lib/")):
        locked = lock["components"][component]
        archive_name = f"{component}-{version}-{target}.tar.xz"
        if locked["target"] != target or locked["archive"] != archive_name:
            raise ValueError("unexpected Rust distribution component identity")
        archive = rust.no_links(dist, Path(archive_name))
        prefix = archive_name[:-7] + "/" + (component if component == "rustc" else f"rust-std-{TARGET}") + "/" + folder
        expected = read_component(archive, locked["sha256"], prefix, NOTICES if component == "rustc" else None,
                                  identity=identity)
        verified = {}
        for name, data in expected.items():
            relative = toolchain / folder / name
            installed = rust.no_links(root, relative)
            if not installed.is_file() or installed.read_bytes() != data:
                raise ValueError(f"installed Rust payload differs from locked archive: {relative}")
            sha256 = hashlib.sha256(data).hexdigest()
            verified[name] = sha256
            if component == "rustc":
                notices[relative.as_posix()] = {"member": prefix + name, "sha256": sha256,
                                               "archive_sha256": locked["sha256"]}
        if component == "rust-std":
            library = rust.no_links(root, toolchain / folder)
            for path in library.rglob("*"):
                if path.is_symlink():
                    raise ValueError("symlink in installed Rust standard library")
                if path.is_dir():
                    continue
                if not path.is_file() or path.relative_to(library).as_posix() not in expected:
                    raise ValueError("extra installed Rust standard library payload")
        components[component] = {"target": target, "archive": archive_name, "url": locked["url"],
                                 "archive_sha256": locked["sha256"], "files": verified}
    return {"schema": 4, "scope": "release notices, installed iOS libraries and published source inventory; not build derivation, linked-member, compiler or IPA provenance",
            "rust": version, "lock_sha256": rust.provenance.digest(lock_path),
            "manifest_url": lock["manifest_url"], "manifest_sha256": lock["manifest_sha256"],
            "components": components, "notices": notices, "source": source}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "root", "dist", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--collect-source-notices", type=Path,
                        help="copy discovered and declared source notice superset into an existing private output directory")
    args = parser.parse_args()
    origins = {}
    try:
        result = verify(args.repo.resolve(), args.root.absolute(), args.dist.absolute())
        if args.collect_source_notices is not None:
            origins = collect_source_notices(args.dist.absolute(), result, args.collect_source_notices.absolute())
            if args.output.absolute() in {args.collect_source_notices.absolute() / name for name in origins}:
                raise ValueError("provenance output collides with a source notice")
            result["source"]["collected_notices"] = origins
            result["source"]["scope"] = "published source/package inventory and collected notice superset; not applicability, header coverage, build derivation, linked members or complete Corresponding Source"
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    except (OSError, ValueError, KeyError, tarfile.TarError, EOFError) as exc:
        for name in origins:
            (args.collect_source_notices / name).unlink()
        parser.exit(1, f"Rust standard-library notice provenance: {exc}\n")


if __name__ == "__main__":
    main()

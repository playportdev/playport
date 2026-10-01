#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify idevice's generated crate list and registry bytes, not IPA provenance."""

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import tomllib


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


cargo = module("idevice_crates", "idevice-crates.py")
provenance = module("notices_provenance", "notices-provenance.py")
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"
NOTICE_PREFIXES = ("license", "licence", "copying", "copyright", "notice", "unlicense")
SCOPE = "normal target dependencies and notice/attribution evidence superset; not complete grants, copied-code origin, link-member, stdlib, StikJIT or IPA provenance"


def registry_license_file_path(declaration):
    """Resolve against the crate-root Cargo.toml, without filesystem access."""
    if (not isinstance(declaration, str) or not declaration
            or declaration.startswith("/") or "\\" in declaration or ":" in declaration
            or declaration.split("/")[-1] in ("", ".", "..")
            or any(ord(char) < 32 or ord(char) == 127 for char in declaration)):
        raise ValueError("invalid/unsupported registry license-file declaration")
    parts = []
    for part in declaration.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise ValueError("registry license-file escapes crate archive")
            parts.pop()
        else:
            parts.append(part)
    return "/".join(parts)


def attribution_catalog():
    """Reviewed whole-file evidence, not newly invented licence grants."""
    path = Path(__file__).with_name("rust-attribution.lock.json")
    if path.is_symlink() or not path.is_file():
        raise ValueError("Rust attribution catalog must be a regular file")
    data = json.loads(path.read_text())
    if data["schema"] != 1:
        raise ValueError("unsupported Rust attribution catalog schema")
    entries = {(c["name"], c["version"]): c for c in data["crates"]}
    if len(entries) != len(data["crates"]):
        raise ValueError("duplicate Rust attribution catalog crate")
    return provenance.digest(path), entries


def attribution_sources(name, version, archive_sha256):
    _, entries = attribution_catalog()
    entry = entries.get((name, version))
    if entry is None:
        return {}
    if archive_sha256 != entry["archive_sha256"]:
        raise ValueError("Rust attribution archive differs from reviewed catalog")
    for path, candidate in entry["sources"].items():
        safe_relative(path)
        if (not re.fullmatch(r"[0-9a-f]{64}", candidate["sha256"])
                or not isinstance(candidate["size"], int) or candidate["size"] < 0):
            raise ValueError("invalid Rust attribution source hash/size")
    return entry["sources"]


def registry_notice_candidates(files):
    """Select native recursive notice candidates plus direct license-file."""
    package = tomllib.loads(files["Cargo.toml"].decode())["package"]
    candidates = {path: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                  for path, data in files.items() if Path(path).name.lower().startswith(NOTICE_PREFIXES)}
    declaration = package.get("license-file")
    declared_source = None
    if "license-file" in package:
        declared_source = registry_license_file_path(declaration)
        if declared_source not in files:
            raise ValueError("registry license-file lacks regular archive payload")
        data = files[declared_source]
        candidates.setdefault(declared_source, {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
        candidates[declared_source]["declared_by"] = ["Cargo.toml"]
    return declaration, declared_source, candidates


def registry_collection_candidates(files, archive_sha256):
    """Add reviewed attribution evidence without relabelling it as licence files."""
    declaration, declared_source, candidates = registry_notice_candidates(files)
    package = tomllib.loads(files["Cargo.toml"].decode())["package"]
    evidence = attribution_sources(package["name"], package["version"], archive_sha256)
    for path, candidate in evidence.items():
        if (path not in files or hashlib.sha256(files[path]).hexdigest() != candidate["sha256"]
                or len(files[path]) != candidate["size"]):
            raise ValueError("Rust attribution source differs from reviewed catalog")
        candidates.setdefault(path, dict(candidate))["attribution_superset"] = True
    return declaration, declared_source, candidates


def safe_relative(name):
    if (not name or name.startswith("/") or "\\" in name or ":" in name
            or any(ord(char) < 32 or ord(char) == 127 for char in name)
            or any(p in ("", ".", "..") for p in name.split("/"))):
        raise ValueError(f"unsafe crate path: {name}")
    return Path(name)


def no_links(root, relative):
    safe_relative(relative.as_posix())
    if root.is_symlink():
        raise ValueError("symlink in crate cache root")
    path = root
    for part in relative.parts:
        path = path / part
        if path.is_symlink():
            raise ValueError(f"symlink in crate path: {relative}")
    return path


def locked_archive(archive, lock):
    """Read validated regular payloads only; never let tar extract paths or links."""
    name, version = lock["name"], lock["version"]
    if not all(re.fullmatch(r"[A-Za-z0-9_.+-]+", item) for item in (name, version)):
        raise ValueError("invalid crate identity")
    if lock.get("source") != REGISTRY:
        raise ValueError(f"unsupported crate source: {name}")
    checksum = lock.get("checksum", "")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError(f"missing locked archive checksum: {name}")
    if archive.is_symlink() or not archive.is_file() or provenance.digest(archive) != checksum:
        raise ValueError(f"crate archive differs from Cargo.lock: {name}-{version}")
    files = {}
    with tarfile.open(archive, "r:gz") as tar:
        seen = {}
        for member in tar.getmembers():
            path = safe_relative(member.name)
            if path.parts[0] != f"{name}-{version}" or member.name in seen:
                raise ValueError(f"invalid/duplicate crate archive member: {member.name}")
            seen[member.name] = member.isdir()
            if member.isdir():
                continue
            if not member.isfile() or len(path.parts) < 2:
                raise ValueError(f"non-regular crate archive member: {member.name}")
            files[Path(*path.parts[1:]).as_posix()] = tar.extractfile(member).read()
        for name in seen:
            if any(seen.get(parent.as_posix()) is False for parent in Path(name).parents):
                raise ValueError(f"file/directory collision in crate archive: {name}")
    if "Cargo.toml" not in files:
        raise ValueError(f"crate archive lacks Cargo.toml: {lock['name']}")
    return files


def verify_crate(package, lock, rust, home=None):
    name, version = package["name"], package["version"]
    if package.get("source") != REGISTRY:
        raise ValueError(f"unsupported crate source: {name}")
    home = home or rust / "cargo"
    source = Path(package["manifest_path"]).parent
    try:
        relative = source.relative_to(home)
    except ValueError:
        raise ValueError(f"crate source outside Cargo registry: {name}") from None
    parts = relative.parts
    if len(parts) != 4 or parts[:2] != ("registry", "src") or parts[3] != f"{name}-{version}":
        raise ValueError(f"invalid registry source directory: {name}")
    source = no_links(home, relative)
    archive_relative = Path("registry/cache") / parts[2] / f"{name}-{version}.crate"
    archive = no_links(home, archive_relative)
    files = locked_archive(archive, lock)
    declaration, declared_source, candidates = registry_collection_candidates(files, lock["checksum"])
    expected = {}
    for filename, data in files.items():
        actual = no_links(source, Path(filename))
        if not actual.is_file() or actual.read_bytes() != data:
            raise ValueError(f"crate source differs from locked archive: {name}/{filename}")
        expected[filename] = hashlib.sha256(data).hexdigest()
    # Cargo adds these cache markers. They are not trusted as source/checksums.
    for file in source.rglob("*"):
        relative_file = file.relative_to(source).as_posix()
        if file.is_symlink():
            raise ValueError(f"symlink in crate source: {name}/{relative_file}")
        if file.is_dir():
            continue
        if not file.is_file() or (relative_file not in expected and relative_file not in (".cargo-ok", ".cargo-checksum.json")):
            raise ValueError(f"extra crate source file: {name}/{relative_file}")
    manifest = tomllib.loads((source / "Cargo.toml").read_text())["package"]
    if (manifest["name"], manifest["version"], manifest.get("license") or "-") != (name, version, package.get("license") or "-"):
        raise ValueError(f"crate metadata differs from locked manifest: {name}")
    return {"name": name, "version": version, "license": package.get("license") or "-",
            "source": relative.as_posix(), "archive": archive_relative.as_posix(),
            "archive_sha256": lock["checksum"], "files": expected,
            "license_file": declaration, "license_file_source": declared_source,
            "notice_candidates": candidates,
            "verification": "locked-registry-archive-bytes"}


def canonical_rows(rows, local):
    result = []
    for row in rows:
        if len(row) != 4:
            raise ValueError("invalid generated crate inventory row")
        name, version, license_text, directory = row
        if directory.startswith("$CARGO_HOME/"):
            safe_relative(directory[len("$CARGO_HOME/"):])
        else:
            try:
                relative = Path(directory).relative_to(local)
            except ValueError:
                raise ValueError(f"unexpected local crate directory: {name}") from None
            if (name, relative.as_posix()) not in (("idevice", "idevice"), ("idevice-ffi", "ffi")):
                raise ValueError(f"unsupported local crate: {name}")
            directory = "$IDEVICE" + ("/" + relative.as_posix() if relative.parts else "")
        result.append((name, version, license_text, directory))
    if not result or len({(r[0], r[1]) for r in result}) != len(result):
        raise ValueError("empty or duplicate generated crate inventory")
    return sorted(result)


def verify(repo, idevice, run, rust, scratch, registry_home=None):
    pins = {p[0]: p[1] for line in (repo / "pins.lock").read_text().splitlines()
            if (p := line.split()) and not line.startswith("#")}
    tree = provenance.verify_tree(idevice, pins["idevice"], [], scratch)
    provenance.tracked_file(idevice, idevice / "Cargo.lock")
    patches = (provenance.series(repo, "idevice")
               if (repo / "patches" / "idevice").exists() else [])
    locked = tomllib.loads((idevice / "Cargo.lock").read_text())["package"]
    locks = {}
    for package in locked:
        key = (package["name"], package["version"], package.get("source"))
        if key in locks:
            raise ValueError("duplicate Cargo.lock package")
        locks[key] = package
    inventory = run / "crates.tsv"
    if inventory.is_symlink() or not inventory.is_file():
        raise ValueError("generated crates.tsv must be a regular file")
    supplied = canonical_rows([line.split("\t") for line in inventory.read_text().splitlines()], run / "src")
    with tempfile.TemporaryDirectory(dir=scratch) as temp:
        src = Path(temp) / "src"
        src.mkdir()
        # Resolve from committed files plus patches/idevice (the tree the stage
        # builds), never the build copy with generated headers.
        resolved_tree, data = provenance.series_tree(idevice, "HEAD", patches, scratch, archive=True)
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            # The pin has an internal README symlink. The data filter refuses
            # links escaping scratch; no hardlinks or special files are needed.
            if any(not (m.isfile() or m.isdir() or m.issym()) for m in archive.getmembers()):
                raise ValueError("unsupported idevice source archive member")
            archive.extractall(src, filter="data")
        # Cargo metadata/tree maintain locks and cache bookkeeping even offline.
        # Give them a disposable copy, preserving links so validation rejects
        # aliases rather than silently importing bytes from outside the cache.
        cache_rust = Path(temp) / "rust"
        home = registry_home or rust / "cargo"
        registry = home / "registry"
        if home.is_symlink() or registry.is_symlink():
            raise ValueError("symlink in Cargo registry root")
        shutil.copytree(registry, cache_rust / "cargo/registry", symlinks=True)
        if any(path.is_symlink() for path in (cache_rust / "cargo/registry").rglob("*")):
            raise ValueError("symlink in disposable Cargo registry")
        packages, selected = cargo.resolve(src, rust, pins["rust"], cache=cache_rust / "cargo")
        records = {}
        for package in packages:
            key = (package["name"], package["version"], package.get("source"))
            if key not in locks:
                raise ValueError(f"resolved crate missing from Cargo.lock: {key[0]}")
            if package.get("source") is None:
                manifest = Path(package["manifest_path"])
                if not manifest.resolve().is_relative_to(src) or not manifest.is_file():
                    raise ValueError(f"local Cargo manifest escapes committed source: {key[0]}")
                continue
            records[key] = verify_crate(package, locks[key], cache_rust)
        expected = canonical_rows(cargo.rows(selected, cache_rust), src)
        if supplied != expected:
            raise ValueError("generated crates.tsv differs from pinned offline Cargo resolution")
        crates = [records[(p["name"], p["version"], p.get("source"))]
                  for p in selected if p.get("source") is not None]
    return {"schema": 3, "scope": SCOPE,
            "attribution_catalog_sha256": attribution_catalog()[0],
            "target": cargo.TARGET, "features": cargo.FEATURES, "rust": pins["rust"],
            "idevice_tree": tree["tree"],
            "idevice_series": [{"name": p.name, "sha256": provenance.digest(p)} for p in patches],
            "idevice_resolved_tree": resolved_tree, "cargo_lock_sha256": provenance.digest(idevice / "Cargo.lock"),
            "inventory": [dict(zip(("name", "version", "license", "source"), row)) for row in expected],
            "inventory_sha256": hashlib.sha256(("\n".join("\t".join(r) for r in expected) + "\n").encode()).hexdigest(),
            "crates": sorted(crates, key=lambda p: (p["name"], p["version"]))}


def registry_notice_payloads(record):
    """Derive output names/origins and summaries from the verified inventory."""
    if record["schema"] != 3 or record["scope"] != SCOPE:
        raise ValueError("unsupported Rust registry notice schema/scope")
    if record["attribution_catalog_sha256"] != attribution_catalog()[0]:
        raise ValueError("Rust attribution catalog differs from collection")
    origins = {}
    missing = []
    selected = {(p["name"], p["version"]): p for p in record["inventory"]
                if p["source"].startswith("$CARGO_HOME/")}
    identities = [(c["name"], c["version"]) for c in record["crates"]]
    if len(set(identities)) != len(identities) or set(identities) != set(selected):
        raise ValueError("registry crate set differs from normal dependency inventory")
    for crate in record["crates"]:
        inventory_crate = selected[(crate["name"], crate["version"])]
        if (inventory_crate["source"] != "$CARGO_HOME/" + crate["source"]
                or inventory_crate["license"] != crate["license"]):
            raise ValueError("registry crate differs from normal dependency inventory")
        candidates = crate["notice_candidates"]
        declaration = crate["license_file"]
        declared_source = crate["license_file_source"]
        resolved = registry_license_file_path(declaration) if declaration is not None else None
        if (declared_source != resolved
                or (declaration is not None and declared_source not in candidates)):
            raise ValueError("registry declared license-file lacks notice candidate")
        native_notices = {path for path in crate["files"] if Path(path).name.lower().startswith(NOTICE_PREFIXES)}
        if declared_source is not None:
            native_notices.add(declared_source)
        evidence = attribution_sources(crate["name"], crate["version"], crate["archive_sha256"])
        expected = native_notices | set(evidence)
        if set(candidates) != expected:
            raise ValueError("registry notice candidates omit/add source files")
        # Evidence copies do not repair missing copyright/permission notices.
        if not native_notices:
            missing.append(f'{crate["name"]} {crate["version"]} ({crate["license"]})\n')
        for path, candidate in sorted(candidates.items()):
            safe_relative(path)
            if (candidate["sha256"] != crate["files"].get(path)
                    or candidate.get("declared_by", []) != (["Cargo.toml"] if path == declared_source else [])
                    or candidate.get("attribution_superset", False) != (path in evidence)):
                raise ValueError("registry notice candidate differs from file/declaration inventory")
            if path in evidence and any(candidate[key] != evidence[path][key] for key in ("sha256", "size")):
                raise ValueError("Rust attribution candidate differs from reviewed catalog")
            name = f'rust-{crate["name"]}-{crate["version"]}-' + path.replace("/", "-")
            safe_relative(name)
            if name in origins or len(name.encode()) > 255:
                raise ValueError(f"colliding/invalid registry notice output: {name}")
            origins[name] = {"crate": crate["name"], "version": crate["version"], "source": path,
                             "member": f'{crate["name"]}-{crate["version"]}/{path}',
                             "archive": crate["archive"], "archive_sha256": crate["archive_sha256"], **candidate}
    summaries = {
        "rust-crates.tsv": "".join(f'{p["name"]}\t{p["version"]}\t{p["license"]}\n' for p in record["inventory"]).encode(),
        "rust-crates-without-licence-files.txt": "".join(missing).encode(),
    }
    return origins, summaries


def collect_registry_notices(home, record, out):
    """Reopen locked archives; write notices only, never extract source paths."""
    origins, payloads = registry_notice_payloads(record)
    for crate in record["crates"]:
        files = locked_archive(no_links(home, Path(crate["archive"])),
                               {"name": crate["name"], "version": crate["version"],
                                "source": REGISTRY, "checksum": crate["archive_sha256"]})
        declaration, declared_source, candidates = registry_collection_candidates(files, crate["archive_sha256"])
        if (candidates != crate["notice_candidates"] or declaration != crate["license_file"]
                or declared_source != crate["license_file_source"]):
            raise ValueError("registry notices changed after archive verification")
        for name, origin in origins.items():
            if (origin["crate"], origin["version"]) == (crate["name"], crate["version"]):
                payloads[name] = files[origin["source"]]
    out = out.absolute()
    no_links(Path(out.anchor), out.relative_to(out.anchor))
    if not out.is_dir():
        raise ValueError("registry notice output must be an existing directory")
    for name in payloads:
        if (out / name).exists() or (out / name).is_symlink():
            raise ValueError(f"registry notice output already exists: {name}")
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "idevice", "run", "rust", "scratch", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--cargo-home", type=Path, help="separate pristine notice registry (not the toolchain)")
    parser.add_argument("--collect-notices", type=Path, help="collect verified registry notice superset into an existing directory")
    args = parser.parse_args()
    origins = None
    try:
        args.scratch.mkdir(parents=True, exist_ok=True)
        data = verify(*(getattr(args, name).resolve() for name in ("repo", "idevice", "run", "rust", "scratch")),
                      registry_home=args.cargo_home.absolute() if args.cargo_home else None)
        if args.collect_notices is not None:
            origins = collect_registry_notices(args.cargo_home.absolute() if args.cargo_home else args.rust.absolute() / "cargo",
                                               data, args.collect_notices)
            if args.output.absolute() in {args.collect_notices.absolute() / name for name in (*origins, "rust-crates.tsv", "rust-crates-without-licence-files.txt")}:
                raise ValueError("Rust provenance output collides with collected payload")
            data["collected_notices"] = origins
        args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    except (OSError, ValueError, KeyError, tarfile.TarError, EOFError) as exc:
        if origins is not None:
            for name in (*origins, "rust-crates.tsv", "rust-crates-without-licence-files.txt"):
                (args.collect_notices / name).unlink()
        parser.exit(1, f"Rust notice provenance: {exc}\n")


if __name__ == "__main__":
    main()

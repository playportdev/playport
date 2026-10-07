#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only verification of notice source trees; not binary-release clearance."""

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile


def git(tree, *args, env=None):
    result = subprocess.run(["git", "-C", str(tree), *args], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"git {' '.join(args)} failed in {tree}: "
                         + result.stderr.decode(errors="replace").strip())
    return result.stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def series_tree(tree, pin, patches, scratch, archive=False):
    """The Git tree of pin plus patches, built in scratch objects, never in the
    input repo; with archive, also that tree as a tar (for a pristine checkout
    whose build applies a series to a copy)."""
    base = git(tree, "rev-parse", f"{pin}^{{commit}}").decode().strip()
    with tempfile.TemporaryDirectory(dir=scratch) as temporary:
        temp = Path(temporary)
        objects = temp / "objects"
        objects.mkdir()
        source_objects = git(tree, "rev-parse", "--git-path", "objects").decode().strip()
        source_objects = (tree / source_objects).resolve()
        env = dict(os.environ, GIT_INDEX_FILE=str(temp / "index"),
                   GIT_OBJECT_DIRECTORY=str(objects),
                   GIT_ALTERNATE_OBJECT_DIRECTORIES=str(source_objects),
                   GIT_OPTIONAL_LOCKS="0")
        git(tree, "read-tree", base, env=env)
        for patch in patches:
            git(tree, "apply", "--cached", "--3way", str(patch.resolve()), env=env)
        result = git(tree, "write-tree", env=env).decode().strip()
        data = git(tree, "archive", result, env=env) if archive else None
    return result, data


def verify_tree(tree, pin, patches, scratch, overrides=None, required=(), omitted=()):
    """Reconstruct the expected Git tree in scratch, never in the input repo.

    Submodules that the build deliberately does not initialise are inventoried
    as absent. They are NOT verified source and must not be used by a packager.
    """
    tree = tree.resolve(strict=True)
    if Path(git(tree, "rev-parse", "--show-toplevel").decode().strip()).resolve() != tree:
        raise ValueError(f"not a repository root: {tree}")
    base = git(tree, "rev-parse", f"{pin}^{{commit}}").decode().strip()
    head = git(tree, "rev-parse", "HEAD").decode().strip()
    expected, _ = series_tree(tree, base, patches, scratch)
    actual = git(tree, "rev-parse", "HEAD^{tree}").decode().strip()
    if actual != expected:
        raise ValueError(f"{tree} is not the exact pin plus declared patch series")

    links = {}
    for entry in git(tree, "ls-tree", "-rz", "HEAD").split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, _, oid = metadata.decode().split()
        if mode == "160000":
            links[path.decode()] = oid
    # The real index must be clean, including gitlinks. Only worktree gitlinks
    # are handled separately (rpmalloc's series and Madeira's Wine symlink).
    git(tree, "diff", "--cached", "--exit-code", "--ignore-submodules=none", "HEAD")
    git(tree, "diff", "--exit-code", "--ignore-submodules=all", "HEAD", "--", ".",
        *(f":(exclude){path}" for path in links))
    for wanted in required:
        if not any(wanted == path or wanted.startswith(path + "/") for path in links):
            raise ValueError(f"required notice submodule is not declared: {wanted}")
    children = []
    overrides = overrides or {}
    for path, oid in sorted(links.items()):
        child = tree / path
        if path in omitted:
            children.append({"path": path, "pin": oid, "status": "not-collected"})
            continue
        if child.is_symlink():
            raise ValueError(f"submodule is a symlink: {child}")
        if not (child / ".git").exists():
            if any(wanted == path or wanted.startswith(path + "/") for wanted in required):
                raise ValueError(f"required notice submodule is absent: {child}")
            children.append({"path": path, "pin": oid, "status": "absent-not-verified"})
            continue
        child_pin, child_patches = overrides.get(path, (oid, []))
        if path in overrides and git(child, "rev-parse", f"{child_pin}^{{commit}}").decode().strip() != oid:
            raise ValueError(f"submodule pin disagrees with parent gitlink: {child}")
        nested_required = tuple(wanted[len(path) + 1:] for wanted in required if wanted.startswith(path + "/"))
        record = verify_tree(child, child_pin, child_patches, scratch, required=nested_required)
        children.append({"path": path, "status": "verified", **record})
    return {"pin": pin, "base_commit": base, "head_commit": head,
            "tree": actual, "patches": [{"name": p.name, "sha256": digest(p)} for p in patches],
            "submodules": children}


def tracked_file(tree, source):
    """Require a regular, non-symlink file with the bytes committed at HEAD."""
    tree = tree.resolve(strict=True)
    if source.is_symlink():
        raise ValueError(f"notice source is a symlink: {source}")
    source = source.resolve(strict=True)
    if not source.is_relative_to(tree) or not source.is_file():
        raise ValueError(f"notice source is outside its tree: {source}")
    relative = source.relative_to(tree).as_posix()
    entry = git(tree, "ls-tree", "-z", "HEAD", "--", relative)
    if not entry:
        raise ValueError(f"untracked notice source: {relative}")
    metadata, _ = entry.rstrip(b"\0").split(b"\t", 1)
    mode, kind, oid = metadata.decode().split()
    if mode not in ("100644", "100755") or kind != "blob":
        raise ValueError(f"notice source is not a committed regular file: {relative}")
    if git(tree, "hash-object", "--no-filters", str(source)).decode().strip() != oid:
        raise ValueError(f"notice bytes differ from HEAD: {relative}")
    return relative


def source_roots(repo):
    roots = {"playport": repo, **{key.lower(): Path(os.environ[key]) for key in
             ("WINE", "FEX", "MYTHIC", "DXMT", "LLVM", "FREETYPE", "MESA", "DXVK", "VKD3D", "GBE", "ABSL", "STIKJIT", "IDEVICE")}}
    # Resolve each source's actual Git root too: notices in initialized
    # submodules must be checked against that child, not the parent gitlink.
    return sorted(((name, root.resolve()) for name, root in roots.items()),
                  key=lambda pair: len(pair[1].parts), reverse=True)


def committed_origin(source, allowed):
    if source.is_symlink():
        raise ValueError(f"notice source is a symlink: {source}")
    resolved = source.resolve(strict=True)

    def submodule_root(parent, wanted):
        if parent == wanted:
            return True
        for entry in git(parent, "ls-tree", "-rz", "HEAD").split(b"\0"):
            if entry.startswith(b"160000 commit "):
                child = parent / entry.split(b"\t", 1)[1].decode()
                if wanted.is_relative_to(child):
                    return submodule_root(child, wanted)
        return False

    for component, root in allowed:
        if resolved.is_relative_to(root):
            actual_root = Path(git(resolved.parent, "rev-parse", "--show-toplevel").decode().strip()).resolve()
            if not actual_root.is_relative_to(root) or not submodule_root(root, actual_root):
                raise ValueError(f"notice Git root escapes component: {source}")
            tracked_file(actual_root, source)
            return {"component": component, "source": resolved.relative_to(root).as_posix(),
                    "verification": "committed-bytes"}
    raise ValueError(f"notice source outside declared roots: {source}")


def notice_payload(out, name):
    if not name or Path(name).name != name or name in (".", ".."):
        raise ValueError(f"invalid notice output name: {name}")
    payload = out / name
    if payload.is_symlink() or not payload.is_file():
        raise ValueError(f"not a regular notice payload: {name}")
    return payload


def validate_copies(repo, log):
    allowed = source_roots(repo)
    rust = Path(os.environ["RUST_ROOT"]).resolve()
    cargo_home = Path(os.environ.get("RUST_NOTICE_CARGO_HOME", str(rust / "cargo")))
    if cargo_home.is_symlink() or (cargo_home / "registry").is_symlink():
        raise ValueError("symlink in notice Cargo home")
    cargo_home = cargo_home.resolve()
    rust_manifest = log.parent / "rust-provenance.json"
    verified_rust = {}
    if rust_manifest.exists():
        for crate in json.loads(rust_manifest.read_text())["crates"]:
            for path, sha256 in crate["files"].items():
                key = "cargo/" + crate["source"] + "/" + path
                if key in verified_rust:
                    raise ValueError(f"duplicate verified Rust source: {key}")
                verified_rust[key] = (sha256, crate["archive_sha256"])
    stdlib_manifest = log.parent / "rust-stdlib-provenance.json"
    verified_stdlib = (json.loads(stdlib_manifest.read_text())["notices"]
                       if stdlib_manifest.exists() else {})
    records = []
    for line in log.read_text().splitlines():
        name, path = line.split("\t")
        source = Path(path)
        if source.is_symlink():
            raise ValueError(f"notice source is a symlink: {source}")
        resolved = source.resolve(strict=True)
        if digest(notice_payload(log.parent, name)) != digest(resolved):
            raise ValueError(f"copied notice differs from its source: {name}")
        if resolved.is_relative_to(cargo_home / "registry") or resolved.is_relative_to(rust):
            relative = ("cargo/" + resolved.relative_to(cargo_home).as_posix()
                        if resolved.is_relative_to(cargo_home / "registry")
                        else resolved.relative_to(rust).as_posix())
            origin = {"name": name, "component": "rust-cache", "source": relative}
            if relative.startswith("cargo/registry/"):
                if relative not in verified_rust:
                    raise ValueError(f"Rust notice lacks locked archive verification: {name}")
                sha256, archive_sha256 = verified_rust[relative]
                if digest(resolved) != sha256:
                    raise ValueError(f"Rust notice changed after archive verification: {name}")
                origin.update(verification="locked-registry-archive-bytes",
                              source_sha256=sha256, archive_sha256=archive_sha256)
            else:
                if relative not in verified_stdlib:
                    raise ValueError(f"Rust notice lacks locked release archive verification: {name}")
                verified = verified_stdlib[relative]
                if digest(resolved) != verified["sha256"]:
                    raise ValueError(f"Rust notice changed after release archive verification: {name}")
                origin.update(verification="locked-release-archive-bytes",
                              source_sha256=verified["sha256"],
                              archive_sha256=verified["archive_sha256"], member=verified["member"])
            records.append(origin)
            continue
        records.append({"name": name, **committed_origin(source, allowed)})
    return {"schema": 1, "scope": "direct copies (including recursive Wine notices)",
            "files": records}


def validate_derived(repo, log):
    """Recompute extracts from committed bytes, never extracting paths to disk."""
    allowed = source_roots(repo)
    records = []
    seen = set()
    for line in log.read_text().splitlines():
        kind, name, path, *selector = line.split("\t")
        if name in seen:
            raise ValueError(f"duplicate derived notice: {name}")
        seen.add(name)
        source = Path(path)
        origin = committed_origin(source, allowed)
        data = source.read_bytes()
        selection = {}
        if kind == "archive-member" and len(selector) == 1:
            member_name = selector[0]
            if (member_name.startswith("/") or
                    any(part in ("", ".", "..") for part in member_name.split("/"))):
                raise ValueError(f"unsafe archive member: {member_name}")
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
                matches = [m for m in archive.getmembers() if m.name == member_name]
                if len(matches) != 1 or not matches[0].isfile():
                    raise ValueError(f"archive notice must be one regular member: {member_name}")
                expected = archive.extractfile(matches[0]).read()
            selection = {"member": member_name}
        elif kind == "line-excerpt" and len(selector) == 2:
            first, last = map(int, selector)
            lines = io.BytesIO(data).readlines()  # LF only, like head/sed; retain bytes.
            if first < 1 or last < first or last > len(lines):
                raise ValueError(f"invalid notice line range: {name}")
            expected = b"".join(lines[first - 1:last])
            selection = {"first_line": first, "last_line": last}
        else:
            raise ValueError(f"invalid derived notice selector: {name}")
        if notice_payload(log.parent, name).read_bytes() != expected:
            raise ValueError(f"derived notice differs from its source: {name}")
        records.append({"name": name, **origin, "kind": kind, **selection,
                        "source_sha256": hashlib.sha256(data).hexdigest(),
                        "sha256": hashlib.sha256(expected).hexdigest(), "size": len(expected)})
    return {"schema": 1, "scope": "archive extracts and source-header excerpts; not licence completeness",
            "files": records}


def series(repo, targets):
    result = []
    for target in targets.split():
        folder = repo / "patches" / target
        for line in (folder / "series").read_text().splitlines():
            if line and not line.startswith("#"):
                patch = folder / line
                if not patch.resolve().is_relative_to(folder.resolve()) or not patch.is_file():
                    raise ValueError(f"invalid series entry: {target}/{line}")
                result.append(patch)
    return result


def collect(repo, scratch):
    pins = {}
    for line in (repo / "pins.lock").read_text().splitlines():
        if line and not line.startswith("#"):
            name, pin, *_ = line.split()
            pins[name] = pin
    specs = [
        ("WINE", "wine", "wine-port wine-valve wine-pe"),
        ("FEX", "fex", "fex-port fex"),
        ("MYTHIC", "madeira", "madeira-unix"),
        ("DXMT", "dxmt", "dxmt-port dxmt"),
        ("LLVM", "llvm-project", ""), ("FREETYPE", "freetype", ""),
        ("MESA", "mesa", "mesa"), ("DXVK", "dxvk", "dxvk"),
        ("VKD3D", "vkd3d-proton", "vkd3d-proton"), ("GBE", "gbe", "gbe"),
        ("ABSL", "abseil-cpp", ""), ("STIKJIT", "stikjit", ""),
        ("IDEVICE", "idevice", ""),
    ]
    required = {"fex": ("External/rpmalloc", "External/fmt", "External/xxhash", "External/unordered_dense"),
                "dxmt": ("include/native/directx",),
                "dxvk": ("include/native/directx", "subprojects/libdisplay-info", "include/vulkan", "include/spirv",
                         "subprojects/dxbc-spirv/submodules/spirv_headers"),
                "vkd3d-proton": ("khronos/Vulkan-Headers", "khronos/SPIRV-Headers",
                                 "subprojects/dxil-spirv/third_party/spirv-headers",
                                 "subprojects/dxil-spirv/subprojects/dxbc-spirv/submodules/spirv_headers"),
                "gbe": ("third-party/deps/common",)}
    records = {}
    for variable, name, targets in specs:
        overrides = {"External/rpmalloc": (pins["rpmalloc"], series(repo, "rpmalloc-port rpmalloc"))} if name == "fex" else {}
        records[name] = verify_tree(Path(os.environ[variable]), pins[name], series(repo, targets), scratch,
                                    overrides, required.get(name, ()), ("wine",) if name == "madeira" else ())
    return {"schema": 1, "scope": "notice-source-trees-only; not verified IPA provenance",
            "pins_sha256": digest(repo / "pins.lock"), "trees": records,
            "required_collections": ["gstreamer", "llvm-runtime"]}


def validate_rust_source_notices(out):
    """Recheck archive-origin source notice copies before inventory publication."""
    actual = {p.name for p in out.iterdir() if p.name.startswith("rust-source-")}
    manifest = out / "rust-stdlib-provenance.json"
    if not manifest.exists():
        if actual:
            raise ValueError("Rust source notices lack release provenance")
        return
    record = json.loads(manifest.read_text())
    source = record.get("source", {})
    collected = source.get("collected_notices")
    if collected is None:
        if actual:
            raise ValueError("Rust source notices lack collection provenance")
        return
    candidates = source["notice_candidates"]
    if record["schema"] != 4 or not collected or actual != set(collected):
        raise ValueError("Rust source notice payload set differs from provenance")
    declarations = {}
    for package in source["packages"]:
        if package.get("license_file") is not None:
            path = package.get("license_file_source")
            if path not in candidates:
                raise ValueError("Rust declared license-file lacks collected candidate")
            declarations.setdefault(path, []).append(package["manifest"])
    for path, candidate in candidates.items():
        if (candidate.get("declared_by", []) != declarations.get(path, [])
                or any(candidate[key] != source["files"][path][key] for key in ("sha256", "size"))):
            raise ValueError("Rust source notice declaration/file inventory differs")
    if {origin["source"] for origin in collected.values()} != set(candidates) or len(collected) != len(candidates):
        raise ValueError("Rust source notice collection omits/duplicates candidates")
    for name, origin in collected.items():
        path = origin["source"]
        candidate = candidates[path]
        if (name != "rust-source-" + path.replace("/", "-")
                or origin["archive_sha256"] != source["archive_sha256"]
                or origin.get("declared_by", []) != candidate.get("declared_by", [])
                or any(origin[key] != candidate[key] for key in ("member", "sha256", "size"))):
            raise ValueError("Rust source notice origin differs from source inventory")
        payload = notice_payload(out, name)
        if digest(payload) != origin["sha256"] or payload.stat().st_size != origin["size"]:
            raise ValueError(f"Rust source notice changed after collection: {name}")


def validate_rust_registry_notices(out):
    """Require the full registry notice/attribution evidence set and summaries."""
    summaries = {"rust-crates.tsv", "rust-crates-without-licence-files.txt"}
    actual = {p.name for p in out.iterdir() if p.name.startswith("rust-")
              and not p.name.startswith(("rust-source-", "rust-licenses-"))
              and p.name not in summaries | {"rust-provenance.json", "rust-stdlib-provenance.json", "rust-COPYRIGHT-library.html"}}
    manifest = out / "rust-provenance.json"
    if not manifest.exists():
        if actual or any((out / name).exists() for name in summaries):
            raise ValueError("Rust registry notices lack archive provenance")
        return
    record = json.loads(manifest.read_text())
    if "collected_notices" not in record:
        raise ValueError("Rust registry notices lack collection provenance")
    spec = importlib.util.spec_from_file_location("registry_notices", Path(__file__).with_name("notices-rust.py"))
    rust = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rust)
    origins, expected_summaries = rust.registry_notice_payloads(record)
    if record["collected_notices"] != origins or actual != set(origins):
        raise ValueError("Rust registry notice payload/origin set differs from provenance")
    for name, origin in origins.items():
        payload = notice_payload(out, name)
        if digest(payload) != origin["sha256"] or payload.stat().st_size != origin["size"]:
            raise ValueError(f"Rust registry notice changed after collection: {name}")
    for name, expected in expected_summaries.items():
        if notice_payload(out, name).read_bytes() != expected:
            raise ValueError(f"Rust registry summary differs from provenance: {name}")


def validate_mingw_notices(out):
    actual = {p.name for p in out.iterdir() if p.name.startswith("mingw-source-")}
    manifest = out / "mingw-provenance.json"
    if not manifest.exists():
        if actual:
            raise ValueError("mingw notices lack source provenance")
        return
    spec = importlib.util.spec_from_file_location("mingw_notices", Path(__file__).with_name("notices-mingw.py"))
    mingw = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mingw)
    record = json.loads(notice_payload(out, manifest.name).read_text())
    expected = mingw.payloads(record)
    if actual != set(expected):
        raise ValueError("mingw notice payload set differs from provenance")
    for name, origin in expected.items():
        payload = notice_payload(out, name)
        if digest(payload) != origin["sha256"] or payload.stat().st_size != origin["size"]:
            raise ValueError(f"mingw notice changed after collection: {name}")


def validate_mesa_notices(out):
    actual = any(p.name.startswith("mesa-header-superset-") for p in out.iterdir())
    manifest = out / "mesa-provenance.json"
    gate = out / "tree-provenance.json"
    required = (gate.exists() and "mesa" in json.loads(notice_payload(out, gate.name).read_text()).get("trees", {}))
    if not manifest.exists():
        if actual or required or manifest.is_symlink():
            raise ValueError("Mesa notices lack committed source provenance")
        return
    if "MESA" not in os.environ:
        raise ValueError("Mesa notice revalidation requires MESA source input")
    spec = importlib.util.spec_from_file_location("mesa_notices", Path(__file__).with_name("notices-mesa.py"))
    mesa = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mesa)
    mesa.validate(Path(os.environ["MESA"]), out)


def validate_gstreamer_notices(out, repo=None):
    manifest = out / "gstreamer-provenance.json"
    actual = any(p.name.startswith("gstreamer-source-") for p in out.iterdir())
    gate = out / "tree-provenance.json"
    required = (gate.exists() and "gstreamer" in json.loads(
        notice_payload(out, gate.name).read_text()).get("required_collections", []))
    if not manifest.exists():
        if actual or required or manifest.is_symlink():
            raise ValueError("GStreamer notices lack preparatory source provenance")
        return
    if not all(key in os.environ for key in ("GST_NOTICE_CERBERO", "GST_NOTICE_SOURCES")):
        raise ValueError("GStreamer notice revalidation requires source archive inputs")
    spec = importlib.util.spec_from_file_location("gstreamer_notices", Path(__file__).with_name("notices-gstreamer.py"))
    gst = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gst)
    gst.validate(repo or Path(__file__).resolve().parent.parent,
                 Path(os.environ["GST_NOTICE_CERBERO"]), Path(os.environ["GST_NOTICE_SOURCES"]), out)


def validate_llvm_runtime_notices(out, repo=None):
    folder = out / "llvm-runtime"
    gate = out / "tree-provenance.json"
    required = (gate.exists() and "llvm-runtime" in json.loads(
        notice_payload(out, gate.name).read_text()).get("required_collections", []))
    if any(p.name.startswith("llvm-runtime-") for p in out.iterdir()):
        raise ValueError("LLVM runtime superset must retain its separate directory")
    if not folder.exists():
        if required or folder.is_symlink():
            raise ValueError("LLVM runtime notices lack separate verified collection")
        return
    if not all(key in os.environ for key in ("LLVM_RUNTIME_SOURCE", "LLVM_MINGW_SOURCE")):
        raise ValueError("LLVM runtime notice revalidation requires exact source inputs")
    spec = importlib.util.spec_from_file_location("llvm_runtime_notices", Path(__file__).with_name("notices-llvm-runtime.py"))
    llvm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(llvm)
    llvm.verify(repo or Path(__file__).resolve().parent.parent,
                Path(os.environ["LLVM_RUNTIME_SOURCE"]), Path(os.environ["LLVM_MINGW_SOURCE"]), folder)


def inventory(out):
    """Record every collected payload, excluding the manifests themselves."""
    validate_rust_source_notices(out)
    validate_rust_registry_notices(out)
    validate_mingw_notices(out)
    validate_mesa_notices(out)
    validate_gstreamer_notices(out)
    validate_llvm_runtime_notices(out)
    files = []
    for file in sorted(out.iterdir()):
        if file.name in ("inventory.json", "SHA256SUMS"):
            continue
        # Only the explicitly verified LLVM standalone collection may be nested.
        # Its verifier has already checked every entry, scope, origin and checksum.
        payloads = sorted(file.iterdir()) if file.name == "llvm-runtime" and not file.is_symlink() else [file]
        for payload in payloads:
            if payload.is_symlink() or not payload.is_file():
                raise ValueError(f"not a regular notice payload: {payload.name}")
            files.append({"name": payload.relative_to(out).as_posix(),
                          "size": payload.stat().st_size, "sha256": digest(payload)})
    return {"schema": 1, "status": "incomplete-inventory", "files": files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    trees = sub.add_parser("trees")
    trees.add_argument("repo", type=Path)
    trees.add_argument("scratch", type=Path)
    trees.add_argument("output", type=Path)
    copies = sub.add_parser("copies")
    copies.add_argument("repo", type=Path)
    copies.add_argument("log", type=Path)
    copies.add_argument("output", type=Path)
    derived = sub.add_parser("derived")
    derived.add_argument("repo", type=Path)
    derived.add_argument("log", type=Path)
    derived.add_argument("output", type=Path)
    payload = sub.add_parser("inventory")
    payload.add_argument("out", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "trees":
            args.scratch.mkdir(parents=True, exist_ok=True)
            data = collect(args.repo, args.scratch)
            output = args.output
        elif args.command == "copies":
            data = validate_copies(args.repo, args.log)
            output = args.output
        elif args.command == "derived":
            data = validate_derived(args.repo, args.log)
            output = args.output
        else:
            data = inventory(args.out)
            output = args.out / "inventory.json"
        output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    except (OSError, ValueError, KeyError, tarfile.TarError, EOFError) as exc:
        parser.exit(1, f"Notice provenance: {exc}\n")


if __name__ == "__main__":
    main()

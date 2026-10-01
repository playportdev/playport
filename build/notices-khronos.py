#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Collect Khronos header notice supersets, not linked/header applicability.

The assembly's tree gate verifies exact pins/series and required submodules.
This helper requires declared Git roots and committed bytes, including every
tracked LICENSES/ text (whose basename need not say 'license').
"""

import argparse
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("notice_provenance", Path(__file__).with_name("notices-provenance.py"))
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)

# Component-relative roots. Do not merge identical texts across revisions.
ROOTS = {
    "dxvk": {
        "include/vulkan": ("LICENSE.md", "LICENSES/Apache-2.0.txt", "LICENSES/MIT.txt"),
        "include/spirv": ("LICENSE", "LICENSES/CC-BY-4.0.txt", "LICENSES/MIT.txt"),
        "subprojects/dxbc-spirv/submodules/spirv_headers": ("LICENSE", "LICENSES/CC-BY-4.0.txt", "LICENSES/MIT.txt"),
    },
    "vkd3d": {
        "khronos/Vulkan-Headers": ("LICENSE.md", "LICENSES/Apache-2.0.txt", "LICENSES/MIT.txt"),
        "khronos/SPIRV-Headers": ("LICENSE", "LICENSES/CC-BY-4.0.txt", "LICENSES/MIT.txt"),
        "subprojects/dxil-spirv/third_party/spirv-headers": ("LICENSE", "LICENSES/CC-BY-4.0.txt", "LICENSES/MIT.txt"),
        "subprojects/dxil-spirv/subprojects/dxbc-spirv/submodules/spirv_headers": ("LICENSE", "LICENSES/CC-BY-4.0.txt", "LICENSES/MIT.txt"),
    },
}
PREFIXES = ("license", "licence", "copying", "copyright", "notice", "unlicense")


def regular(path):
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError(f"symlink in Khronos notice path: {path}")
    if not path.is_file():
        raise ValueError(f"missing regular Khronos notice: {path}")


def collect(components, out, origins_log=None):
    if out.is_symlink() or not out.is_dir():
        raise ValueError("notice output must be an existing regular directory")
    files = {}
    allowed = [(name, tree.resolve(strict=True)) for name, tree in components.items()]
    for component, roots in ROOTS.items():
        tree = components[component]
        if any(p.is_symlink() for p in (tree, *tree.parents)):
            raise ValueError("symlink in Khronos component root")
        if out.resolve().is_relative_to(tree.resolve()):
            raise ValueError("Khronos notice output overlaps source tree")
        for relative, required in roots.items():
            root = tree / relative
            if any(p.is_symlink() for p in (root, *root.parents)):
                raise ValueError(f"symlink in Khronos header root: {relative}")
            actual = Path(provenance.git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()
            if actual != root.resolve():
                raise ValueError(f"Khronos header root is not a populated repository: {relative}")
            sources = {root / name for name in required}
            for source in root.rglob("*"):
                path = source.relative_to(root)
                if source.name.lower().startswith(PREFIXES) or "LICENSES" in path.parts:
                    if source.is_dir() and not source.is_symlink():
                        continue
                    sources.add(source)
            for source in sorted(sources):
                if any(ord(c) < 32 or ord(c) == 127 for c in str(source)):
                    raise ValueError("control character in Khronos notice path")
                regular(source)
                provenance.committed_origin(source, allowed)
                name = "khronos-" + component + "-" + source.relative_to(tree).as_posix().replace("/", "-")
                if name in files or (out / name).exists() or (out / name).is_symlink():
                    raise ValueError(f"duplicate Khronos notice output: {name}")
                files[name] = (source, source.read_bytes())
    if origins_log is not None:
        if origins_log.parent.resolve() != out.resolve() or origins_log.is_symlink():
            raise ValueError("Khronos origins log must be inside output and not a symlink")
        if origins_log.exists() and not origins_log.is_file():
            raise ValueError("Khronos origins log must be a regular file")
        if origins_log.name in files:
            raise ValueError("Khronos origins log collides with notice output")
    created = []
    try:
        for name, (_, data) in files.items():
            with (out / name).open("xb") as output:
                created.append(out / name)
                output.write(data)
        if origins_log is not None:
            with origins_log.open("a") as log:
                log.write("".join(f"{name}\t{source}\n" for name, (source, _) in files.items()))
    except Exception:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    return list(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dxvk", type=Path)
    parser.add_argument("vkd3d", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--origins-log", type=Path)
    args = parser.parse_args()
    try:
        names = collect({"dxvk": args.dxvk, "vkd3d": args.vkd3d}, args.out, args.origins_log)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Khronos notice collection: {exc}\n")
    print(f"{len(names)} Khronos header notice files (superset, not applicability audit)")


if __name__ == "__main__":
    main()

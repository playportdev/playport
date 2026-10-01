#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Collect Wine's licence/notice inventory; this is not a linked-code audit.

The Wine pin has NOTICES.md rather than LICENSE.OLD, and its bundled libraries
change over time. Collect their notice files instead of keeping a stale list.
Used by notices-assemble.sh; OUT already exists and must not contain these names.
"""

import argparse
import importlib.util
from pathlib import Path
import shutil


REQUIRED = ("LICENSE", "COPYING.LIB", "LICENSE-MADEIRA.md", "NOTICES.md")
NOTICE_PREFIXES = ("license", "licence", "copying", "copyright", "notice")


def collect(wine: Path, out: Path, tracked: bool = False, origins_log: Path | None = None) -> list[str]:
    wine = wine.resolve(strict=True)
    verifier = None
    if tracked:
        spec = importlib.util.spec_from_file_location("notices_provenance", Path(__file__).with_name("notices-provenance.py"))
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
    if not out.is_dir():
        raise ValueError("notice output directory must already exist")
    files = {}

    def add(source: Path, name: str) -> None:
        resolved = source.resolve(strict=True)
        if not resolved.is_relative_to(wine) or not resolved.is_file():
            raise ValueError(f"notice is not a regular file inside the Wine tree: {source}")
        if name in files or (out / name).exists() or (out / name).is_symlink():
            raise ValueError(f"duplicate notice output: {name}")
        if verifier:
            verifier.tracked_file(wine, source)
        files[name] = source

    for name in REQUIRED:
        add(wine / name, "wine-" + (name if name.endswith(".md") else name + ".txt"))
    # Preserve the old licence too if a tree carries it, but do not require a
    # file absent at the current pin. Required files above must never be skipped.
    if (wine / "LICENSE.OLD").exists():
        add(wine / "LICENSE.OLD", "wine-LICENSE.OLD.txt")
    libs = wine / "libs"
    if not libs.is_dir():
        raise ValueError("Wine tree has no libs directory")
    for source in sorted(libs.rglob("*")):
        if source.is_dir() or not source.name.lower().startswith(NOTICE_PREFIXES):
            continue
        relative = source.relative_to(libs).as_posix()
        add(source, "wine-libs-" + relative.replace("/", "-"))

    # Validate all inputs and destination names before writing any of this set.
    for name, source in files.items():
        shutil.copyfile(source, out / name)
    if origins_log is not None:
        with origins_log.open("a") as log:
            for name, source in files.items():
                log.write(f"{name}\t{source}\n")
    return list(files)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wine", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--tracked", action="store_true", help="require committed HEAD bytes")
    parser.add_argument("--origins-log", type=Path, help="append copied-file origins for later verification")
    args = parser.parse_args()
    try:
        names = collect(args.wine, args.out, args.tracked, args.origins_log)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Wine notice collection: {exc}\n")
    print(f"{len(names)} Wine notice files (inventory, not proof of linked-code coverage)")


if __name__ == "__main__":
    main()

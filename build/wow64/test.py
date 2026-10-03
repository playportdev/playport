#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the actual patch's arithmetic header, not a parallel implementation."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("PLAYPORT_BUILD", REPO / ".work"))
HEADER = "build/ntdll-unix/wow64_window.h"


def main():
    scratch = BUILD / "c-test"
    scratch.mkdir(parents=True, exist_ok=True)
    # A separate scratch index prevents git apply from discovering the enclosing
    # superproject and writing into it. No Madeira checkout needed on CI.
    with tempfile.TemporaryDirectory(prefix="wow64-window-", dir=scratch) as tmp:
        root = Path(tmp)
        subprocess.run(["git", "init", "-q", tmp], check=True)
        subprocess.run(["git", "-C", tmp, "apply", f"--include={HEADER}",
                        str(REPO / "patches/madeira-unix/0049-ntdll-reserve-an-owned-i386-address-window.patch")], check=True)
        exe = root / "window-test"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=undefined", "-fno-sanitize-recover=all",
                        "-I", str((root / HEADER).parent),
                        str(REPO / "build/wow64/window_test.c"), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

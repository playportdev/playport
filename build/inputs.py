# SPDX-License-Identifier: GPL-3.0-or-later
"""This machine's inputs: where the system tools the project uses are installed.

The repository names no path outside itself. What differs per workstation is
recorded once, by `pp setup`, in $PLAYPORT_BUILD/inputs.local (gitignored;
build/env.sh sources the same file):

  LLVM_MINGW              llvm-mingw 20260922 UCRT with the arm64ec CRT rebuilt
  DARWIN_SDK              xtool's darwin SDK bundle
  PLAYPORT_USBMUX_SOCKET  netmuxd's socket

An environment variable of the same name wins over the file.

The phone is the machine's too. Its lock, holder and install record live in
DEVICE_DIR: $PLAYPORT_DEVICE_DIR, default the build area (build/env.sh
computes the same).
"""

import os
import shlex
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ.get("PLAYPORT_BUILD") or REPO / ".work")
FILE = BUILD / "inputs.local"
KEYS = ("LLVM_MINGW", "DARWIN_SDK", "PLAYPORT_USBMUX_SOCKET")


DEVICE_DIR = Path(os.environ.get("PLAYPORT_DEVICE_DIR") or BUILD)


def read(path=None):
    """The KEY=VALUE assignments of an inputs.local (shell syntax, one per line);
    by default the build area's."""
    out = {}
    if path is None:
        path = FILE
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return out
    for line in lines:
        words = shlex.split(line, comments=True)
        if len(words) == 1 and "=" in words[0]:
            k, v = words[0].split("=", 1)
            out[k] = v
    return out


def get(name):
    """NAME from the environment, else inputs.local, else None."""
    return os.environ.get(name) or read().get(name) or None


def need(name):
    """NAME, or SystemExit saying how to record it."""
    v = get(name)
    if not v:
        raise SystemExit(f"{name} is not set: run ./pp setup (it records {FILE.relative_to(REPO) if FILE.is_relative_to(REPO) else FILE})")
    return v


def write(values, path=FILE):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = ["# This machine's inputs (pp setup; build/inputs.py). Not committed.\n"]
    text += [f"{k}={shlex.quote(str(values[k]))}\n" for k in KEYS if values.get(k)]
    text += [f"{k}={shlex.quote(str(v))}\n" for k, v in values.items() if k not in KEYS and v]
    path.write_text("".join(text))


def rel(path):
    """PATH relative to the repository when it is inside it; for output that may be committed."""
    p = Path(path)
    try:
        return str(p.resolve().relative_to(REPO))
    except ValueError:
        return str(p)

# SPDX-License-Identifier: GPL-3.0-or-later
"""Read the shipped new-file patches, not a mutable build tree."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PATCH = ROOT / "patches/madeira-unix/0190-ntdll-dev-single-process-social-club.patch"


def added_file(name):
    part = PATCH.read_text().split(f"+++ b/build/ntdll-unix/{name}\n", 1)[1].split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in part.splitlines() if line.startswith("+")) + "\n"


NATIVE = added_file("pp_sc_single.h")
SCRATCH = ROOT / ".work/tmp"
SCRATCH.mkdir(parents=True, exist_ok=True)

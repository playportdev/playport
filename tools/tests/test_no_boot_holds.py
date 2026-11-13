# SPDX-License-Identifier: GPL-3.0-or-later
"""No boot hold for one large reservation or for V8's cage (madeira-unix 0016, PLA-843, decision 0183).

Madeira's loader_ios.c and virtual_ios.c held, from boot, the largest free hole for one large
reservation (ml996, served by ml997 and ml1029) and [0x7200000000, 0x7400000000) for V8's 8 GB cage
(ml433). The madeira-unix series applied over the Madeira pin leaves neither, nor anything that read
their sizes: each name is in the pin (the positive control) and in no file the series leaves."""

import os
import subprocess
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FILES = ("build/ntdll-unix/loader_ios.c", "build/ntdll-unix/virtual_ios.c")
# The holds' entry points and state, and the madeira.cfg files that sized the large-reservation hold.
NAMES = ("ios_jumbo_holdback_init", "ios_jumbo_holdback_take", "ios_jumbo_holdback_carve",
         "ios_jumbo_hold_base", "ios_jumbo_hold_size", "ios_jumbo_hold_keep",
         "IOS_CAGE_BASE", "IOS_CAGE_REAL_SIZE", "ios_cage_holdback_live",
         "madeira-jumbo-mb.txt", "madeira-jumbo-keep-mb.txt")


def text(d):
    out = ""
    for name in FILES:
        with open(os.path.join(d, name), errors="replace") as f:
            out += f.read()
    return out


def series(target):
    d = os.path.join(ROOT, "patches", target)
    with open(os.path.join(d, "series")) as f:
        return [os.path.join(d, x.strip()) for x in f if x.strip() and not x.startswith("#")]


class NoBootHolds(unittest.TestCase):
    def test_the_series_leaves_no_boot_hold(self):
        pin = os.path.join(ROOT, "upstream", "madeira")
        if not os.path.exists(os.path.join(pin, FILES[1])):
            self.skipTest("upstream/madeira is not checked out")
        with tempfile.TemporaryDirectory() as d:
            for name in FILES:
                os.makedirs(os.path.join(d, os.path.dirname(name)), exist_ok=True)
                with open(os.path.join(pin, name), "rb") as src, open(os.path.join(d, name), "wb") as dst:
                    dst.write(src.read())
            pinned = text(d)
            # A repository of its own: under one (pp test's TMPDIR is in the build area), git apply
            # would skip every path outside the directory it runs in, applying nothing.
            subprocess.run(["git", "init", "-q"], cwd=d, check=True)
            include = [f"--include={name}" for name in FILES]
            for patch in series("madeira-unix"):
                subprocess.run(["git", "apply", *include, patch], cwd=d, check=True, capture_output=True)
            left = text(d)
        for name in NAMES:
            self.assertIn(name, pinned)
            self.assertNotIn(name, left)


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""The JIT pool's two image tables stay in step (PLA-373).

Wine's ntdll-unix pushes every live image copy in its table
(IOS_JIT_MAX_MAPPINGS, build/ntdll-unix/virtual_ios.c) to every process's
emulator, whose own alias table (kMaxEntries, FEX's IosJitAlias.cpp) must
therefore hold at least as many. Both values are read as the series set them:
the last added definition in series order, over the upstream file for Wine."""

import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FEX_ALIAS = re.compile(r"^\+constexpr int kMaxEntries = (\d+);$", re.M)
UNIX_MAPPINGS = re.compile(r"^\+?#define IOS_JIT_MAX_MAPPINGS (\d+)\b", re.M)


def series_value(targets, pattern):
    value = None
    for target in targets:
        directory = os.path.join(ROOT, "patches", target)
        with open(os.path.join(directory, "series")) as series:
            names = [line.strip() for line in series if line.strip() and not line.startswith("#")]
        for name in names:
            with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as patch:
                found = pattern.findall(patch.read())
            if found:
                value = int(found[-1])
    return value


class AliasTableCaps(unittest.TestCase):
    def test_fex_alias_table_holds_every_wine_image(self):
        fex = series_value(["fex-port", "fex"], FEX_ALIAS)
        upstream = os.path.join(ROOT, "upstream", "madeira", "build", "ntdll-unix", "virtual_ios.c")
        unix = series_value(["madeira-unix"], UNIX_MAPPINGS)
        if unix is None and os.path.exists(upstream):
            with open(upstream, encoding="utf-8", errors="replace") as source:
                unix = int(UNIX_MAPPINGS.findall(source.read())[-1])
        self.assertIsNotNone(fex, "no kMaxEntries in patches/fex-port or patches/fex")
        self.assertIsNotNone(unix, "no IOS_JIT_MAX_MAPPINGS in patches/madeira-unix or upstream")
        self.assertGreaterEqual(fex, unix)


if __name__ == "__main__":
    unittest.main()

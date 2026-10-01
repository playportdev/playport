# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/sampleprof.py: the runtime's [wprof] bursts summed by sample count,
and the C++ name shortening. Symbolisation against the staged DLLs is left
out: those are build outputs."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import sampleprof  # noqa: E402


class Parse(unittest.TestCase):
    def test_bursts_weigh_by_their_sample_count(self):
        lines = [
            "[wprof] ml1129 burst: 100 running samples over 2 busiest thread(s), 90 with a frame chain",
            "[wprof] ml1129 class: x64-JIT=50.0% PE-other=50.0%",
            "[wprof] ml1129 leaf: foo.dylib`bar=10.0%",
            "[wprof] ml1129 burst: 300 running samples over 2 busiest thread(s), 280 with a frame chain",
            "[wprof] ml1129 class: x64-JIT=100.0%",
            "[wprof] ml1129 leaf: foo.dylib`bar=20.0%",
            "[wprof] ml1129 leaf (cont): x64:game.exe+1200=5.0%",
        ]
        tables, total = sampleprof.parse(lines)
        self.assertEqual(total, 400)
        self.assertAlmostEqual(tables["class"]["x64-JIT"], 350)
        self.assertAlmostEqual(tables["class"]["PE-other"], 50)
        self.assertAlmostEqual(tables["leaf"]["foo.dylib`bar"], 70)
        self.assertAlmostEqual(tables["leaf"]["x64:game.exe+1200"], 15)
        text = sampleprof.report(lines)
        self.assertIn("  87.5  x64-JIT", text)
        self.assertIn("  17.5  foo.dylib`bar", text)

    def test_no_burst_no_report(self):
        self.assertIsNone(sampleprof.report(["[wprof] ml1129 class: x64-JIT=50.0%"]))

    def test_short_drops_templates_and_parameters(self):
        self.assertEqual(sampleprof.short("void dxmt::str::format1<char [21], int>(std::a&, int const&)"),
                         "dxmt::str::format1<>()")
        self.assertEqual(sampleprof.short("ExitFunctionEC"), "ExitFunctionEC")


if __name__ == "__main__":
    unittest.main()

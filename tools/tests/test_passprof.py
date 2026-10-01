# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/passprof.py: winemetal's [pass-prof] lines (DXMT_PASS_PROF=1) as
sampled frames and alike passes."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import passprof  # noqa: E402

LINES = [
    "[pass-prof] armed: 2 frames every 1200 presents",
    "[pass-prof] report 1 at present 614: 3 encoders in 1 frames, 1 command buffers, 1 waitUntilCompleted, "
    "sampleTimestamps ratio 41.667",
    "[pass-prof]  f0 p0 cb1 2736x1260 x1 c0=70/LS d=260/LS st draws=9 prims=1314 vtx=0.100 frag=2.800 "
    "v@0.000 f@0.528..3.327",
    "[pass-prof]  f0 p1 cb1 blit gpu=0.200 at=3.3..3.5",
    "[pass-prof]  f0 p2 cb1 2736x1260 x1 c0=70/LS d=260/LS st draws=3 prims=6 vtx=0.050 frag=0.950 "
    "v@0.105 f@3.5..4.4",
    "[pass-prof] frame 0: 3 passes, 12 draws, sum vtx 0.150 ms, sum frag 3.750 ms, span 4.400 ms",
]


class Parse(unittest.TestCase):
    def test_frames_and_passes(self):
        frames = passprof.parse(LINES)
        self.assertEqual(len(frames), 1)
        f = frames[0]
        self.assertEqual((f["report"], f["present"], f["draws"]), (1, 614, 12))
        self.assertEqual([p["kind"] for p in f["passes"]], ["render", "blit", "render"])
        self.assertAlmostEqual(f["passes"][0]["ms"], 2.9)

    def test_alike_passes_group_by_size_and_attachments(self):
        text = passprof.report(LINES)
        row = next(l for l in text.splitlines() if l.endswith("2736x1260 x1 c0=70/LS d=260/LS st"))
        self.assertTrue(row.split()[0] == "3.900", row)   # 2.9 + 1.0 in one frame
        self.assertIn("4.100 total a frame", text)

    def test_no_lines_no_report(self):
        self.assertEqual(passprof.report(["other"]), "")


if __name__ == "__main__":
    unittest.main()

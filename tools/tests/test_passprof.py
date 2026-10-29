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

    def test_recorded_kosmickrisp_phone_frame(self):
        path = os.path.join(os.path.dirname(__file__), "fixtures", "passprof-kosmickrisp.log")
        with open(path) as log:
            frames = passprof.parse(log)
        f, = frames
        self.assertEqual((f["present"], f["draws"], len(f["passes"])), (600, 12, 5))
        self.assertAlmostEqual(sum(p["ms"] for p in f["passes"]), f["gpu"])
        self.assertEqual(f["passes"][2]["pipeline"]["msl"], "bd8d4d7323248236")
        self.assertEqual(f["passes"][0]["pipeline"], None)  # mixed, not the last bind
        self.assertAlmostEqual(f["span"], 1.7735)

    def test_recorded_witcher_frame_and_shader_identity(self):
        path = os.path.join(os.path.dirname(__file__), "fixtures", "passprof-kosmickrisp-w3.log")
        with open(path) as log:
            lines = log.readlines()
        f, = passprof.parse(lines)
        self.assertEqual((f["present"], f["draws"], len(f["passes"])), (3000, 1837, 200))
        self.assertEqual(f["untimed"], 65)
        lighting = f["passes"][47]
        self.assertEqual((lighting["kind"], lighting["index"]), ("compute", 47))
        self.assertAlmostEqual(lighting["ms"], 10.212667)
        self.assertEqual(lighting["pipeline"], {"kind": "compute", "msl": "98cdc0471b1365e7",
                         "max_threads": 256, "static_tg_bytes": 2064, "requested_threads": 256})
        # Wine writes to the fd directly, bypassing a stdio stream lock. A
        # damaged pass must exclude the frame, not undercount its GPU time.
        damaged = [l.replace("gpu=", "wine: interrupted\n gpu=", 1)
                   if " f0 p0 " in l else l for l in lines]
        self.assertEqual(passprof.report(damaged), "")

    def test_kosmickrisp_elapsed_and_limits(self):
        lines = [
            "[pass-prof] pipeline 0x1 kind=compute msl=0123456789abcdef max_threads=256 "
            "static_tg_bytes=1024 requested_threads=256",
            "[pass-prof] report 2 at present 600: KosmicKrisp, 2 encoders",
            "[pass-prof]  f0 p0 cb1 compute gpu=6.734567 at=0.0..6.734567 pipeline=0x1",
            "[pass-prof]  f0 p1 cb2 render 1300x600 x1 c0=70/1:1 d=260/1:1 draws=1 "
            "gpu=0.010123 at=6.74..6.750123 pipeline=mixed",
            "[pass-prof] frame 0: 2 passes, 1 draws, sum gpu 6.744690 ms, span 6.750123 ms",
        ]
        f, = passprof.parse(lines)
        self.assertEqual((f["present"], f["gpu"], f["vtx"], f["frag"]), (600, 6.74469, None, None))
        self.assertEqual((f["passes"][1]["index"], f["passes"][1]["cb"]), (1, 2))
        p = f["passes"][0]
        self.assertEqual(p["pipeline"]["requested_threads"], 256)
        self.assertEqual(p["key"], "compute pipeline=0123456789abcdef")
        text = passprof.report(lines)
        self.assertIn("6.750123", text)
        self.assertIn("NOT register/spill counts", text)
        self.assertIn("pipeline=mixed", text)
        self.assertIn("6.745 total a frame", text)
        self.assertNotIn("pipeline=0x1", text)

    def test_unavailable_costs_are_not_zero_and_totals_are_partial(self):
        lines = [
            "[pass-prof] pipeline 0x1 kind=compute msl=0123456789abcdef max_threads=256 "
            "static_tg_bytes=2064 requested_threads=256",
            "[pass-prof] report 1 at present 1800: KosmicKrisp",
            "[pass-prof]  f0 p0 cb1 compute gpu=5.2 at=0..5.2 pipeline=0x1",
            "[pass-prof]  f0 p1 cb1 compute gpu=NA reason=native-copy pipeline=0x1",
            "[pass-prof]  f0 p2 cb2 compute gpu=NA reason=no-dispatch pipeline=0x0",
            "[pass-prof] frame 0: 3 passes, 0 draws, sum gpu 5.2 ms, span 6 ms, untimed 2",
        ]
        f, = passprof.parse(lines)
        self.assertEqual(f["untimed"], 2)
        self.assertIsNone(f["passes"][1]["ms"])
        self.assertIsNone(f["passes"][2]["ms"])
        text = passprof.report(lines)
        self.assertIn("5.200 total a frame (PARTIAL", text)
        self.assertIn("NOT zero GPU cost", text)
        self.assertIn("unavailable=native-copy", text)
        self.assertIn("unavailable=no-dispatch", text)
        self.assertEqual(passprof.parse(lines[:-1] + [lines[-1].replace("untimed 2", "untimed 1")]), [])

    def test_unavailable_timestamp_span(self):
        lines = ["[pass-prof] report 1 at present 600: KosmicKrisp",
                 "[pass-prof]  f0 p0 cb1 compute gpu=NA reason=no-dispatch pipeline=0x0",
                 "[pass-prof] frame 0: 1 passes, 0 draws, sum gpu 0 ms, span NA ms, untimed 1"]
        f, = passprof.parse(lines)
        self.assertIsNone(f["span"])
        self.assertIn("PARTIAL", passprof.report(lines))

    def test_truncated_and_discarded_frames_excluded(self):
        self.assertEqual(passprof.report(LINES[:-1]), "")
        self.assertEqual(passprof.report(LINES[:4] + LINES[-1:]), "")
        self.assertEqual(passprof.report(["[pass-prof] discarded KosmicKrisp present 600: overflow"]), "")

    def test_multiple_reports_and_pointer_reuse(self):
        lines = []
        for report_id, shader in enumerate(("aaaa", "bbbb"), 1):
            lines += [f"[pass-prof] pipeline 0x1 kind=compute msl={shader} max_threads=256 "
                      "static_tg_bytes=0 requested_threads=256",
                      f"[pass-prof] report {report_id} at present {599 + report_id}: KosmicKrisp",
                      "[pass-prof]  f0 p0 cb1 compute gpu=1.0 at=0..1 pipeline=0x1",
                      "[pass-prof] frame 0: 1 passes, 0 draws, sum gpu 1.0 ms, span 1.0 ms"]
        frames = passprof.parse(lines)
        self.assertEqual([f["passes"][0]["pipeline"]["msl"] for f in frames], ["aaaa", "bbbb"])
        self.assertIn("over the 2 sampled frames", passprof.report(lines))

    def test_dxmt_compute_and_multiple_frames(self):
        lines = LINES[:2] + ["[pass-prof]  f1 p0 cb2 compute gpu=0.025 at=0..0.025"] + LINES[2:]
        lines += ["[pass-prof] frame 1: 1 passes, 0 draws, sum vtx 0 ms, sum frag 0 ms, span 0.025 ms"]
        self.assertEqual(len(passprof.parse(lines)), 2)
        self.assertIn("2.062 total a frame", passprof.report(lines))

    def test_no_lines_no_report(self):
        self.assertEqual(passprof.report(["other"]), "")


if __name__ == "__main__":
    unittest.main()

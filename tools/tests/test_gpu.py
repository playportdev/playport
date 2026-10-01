# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/gpu.py (pp gpu): the play's pad times, and validation.txt from a play's
log, device log and crash report."""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gpu  # noqa: E402


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class When(unittest.TestCase):
    def test_pad_times(self):
        self.assertEqual(gpu.when_of("35"), (False, 35.0))
        self.assertEqual(gpu.when_of("first-frame+90"), (True, 90.0))
        self.assertIsNone(gpu.when_of("ff+90"))


class Validation(unittest.TestCase):
    def test_report_groups_findings(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "run", "pull", "s1-host.log")
            write(log, "title: diagnostics: Metal validation (API and shaders); device class MTLDebugDevice\n"
                       "2026-09-29 18:54:37.499 S1Probe[1323:143149] Set Stencil Reference Value Validation\n"
                       "redundant setStencilReferenceValue.\n"
                       "previous setStencilReferenceValue was unused.\n"
                       "2026-09-29 18:54:37.499 S1Probe[1323:143149] End Encoding Validation\n"
                       "unused vertex binding in render encoder at Buffer index 1.\n"
                       "info:  [FRAME_STATS] #64 cmdbufs=2\n"
                       "err:   Frame 3: INF or NAN detected in interpolant 'reg2_0'\n"
                       "err:   vertex function: \"vs_756ae290_5b6d\"\n"
                       "err:   \n"
                       "err:   pipeline: \"(null)\", pipeline UID: \"20AA\"\n"
                       "err:   Error detected in drawIndexedPrimitives: in encoder with label \"<no label>\"\n"
                       "err:   Frame 4: INF or NAN detected in interpolant 'reg2_0'\n"
                       "err:   vertex function: \"vs_756ae290_5b6d\"\n"
                       "err:   Device error at frame 9: Invalid Resource\n"
                       "err:   [mem-census] unrelated\n")
            write(os.path.join(d, "device-log.txt"),
                  "2026-09-29 18:42:16.711542 S1Probe{Metal}[1238] <NOTICE>: Metal API Validation Enabled\n"
                  "2026-09-29 18:42:29.392369 S1Probe{Metal}[1238] <ERROR>: <private>\n")
            r = gpu.validation_report(d, log, "shaders")
            text = open(os.path.join(d, "validation.txt")).read()
        self.assertTrue(r["armed"])
        self.assertEqual((r["shader_findings"], r["api_findings"], r["cmdbuf_errors"]), (2, 3, 1))
        self.assertIn("in 2 frames", text)
        self.assertIn("2  INF or NAN detected in interpolant 'reg2_0'  [vertex vs_756ae290_5b6d]", text)
        self.assertIn("Set Stencil Reference Value Validation: previous setStencilReferenceValue was unused.", text)
        self.assertIn("End Encoding Validation: unused vertex binding in render encoder at Buffer index 1.", text)
        self.assertIn("Device error at frame N: Invalid Resource", text)
        self.assertIn("device log: 1 Metal ERROR lines", text)

    def test_stop_quotes_the_crash_reports_assertion(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "run", "pull", "s1-host.log")
            write(log, "title: diagnostics: Metal validation (API, ending at the first error); device class MTLDebugDevice\n")
            doc = {"asi": {"libsystem_c.dylib": ["-[MTLDebugRenderCommandEncoder validateCommonDrawErrors:]:5970: "
                                                 "failed assertion `Draw Errors Validation'"]}}
            write(os.path.join(d, "run", "crashes", "S1Probe-2026-09-29-184500.ips"),
                  json.dumps({"app_name": "S1Probe"}) + "\n" + json.dumps(doc))
            r = gpu.validation_report(d, log, "stop")
        self.assertEqual(len(r["stopped_at"]), 1)
        self.assertIn("validateCommonDrawErrors", r["stopped_at"][0])


if __name__ == "__main__":
    unittest.main()

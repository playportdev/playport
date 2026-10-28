# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/apple.py: reading gpucapture's device, process and boundary tables, choosing a
boundary, and gpudebug's JSON replies (recorded from Xcode 27.1's tools, 2026-10-28)."""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import apple  # noqa: E402
import phonelib  # noqa: E402

DEVICES = """  ID                Name           Model          OS  
   0  kamils-macbook-pro  MacBookPro18,1  macOS 27.2  
   1    Kamil\u2019s iPhone      iPhone Air  iOS 27.0.1  
"""
LIST = """  PID  Device     Name  GPU(ms)  
  600       1  S1Probe     2.10  
"""
BOUNDARIES = """boundaries for 600 (S1Probe)
  ID    Type              Label  GPU(ms)  Count
   1  Device  Apple A19 Pro GPU     2.10    133
   4   Queue          RenderBox     2.10    133
   5   Scope          RenderBox     0.00      0
   7   Layer      CAMetalLayer    30.20     61
   8   Queue        kk-queue-0    28.00    122
"""


class Tables(unittest.TestCase):
    def test_devices_and_the_phone(self):
        with mock.patch.object(apple, "run", return_value=DEVICES):
            self.assertEqual(apple.devices()[1], (1, "Kamil\u2019s iPhone", "iPhone Air", "27.0.1"))
            self.assertEqual(apple.phone_device(), (1, "Kamil\u2019s iPhone"))

    def test_capturable_pid_on_the_device(self):
        with mock.patch.object(apple, "run", return_value=LIST):
            self.assertEqual(apple.capturable(1), 600)
            self.assertIsNone(apple.capturable(2))
        with mock.patch.object(apple, "run", return_value="error: no capturable processes available\n"):
            self.assertIsNone(apple.capturable(1))

    def test_boundaries_and_the_choice(self):
        with mock.patch.object(apple, "run", return_value=BOUNDARIES):
            rows = apple.boundaries(600, 1)
        self.assertEqual(len(rows), 5)
        self.assertEqual(apple.pick_boundary(rows, "layer")["id"], 7)
        self.assertEqual(apple.pick_boundary(rows, "queue")["id"], 8)   # the busiest queue
        self.assertEqual(apple.pick_boundary(rows, "4")["label"], "RenderBox")
        with self.assertRaises(phonelib.PhoneError):
            apple.pick_boundary(rows[:3], "layer")

    def test_json_replies_after_prompts(self):
        text = 'gpudebug> {"a": 1}\nnoise\ngpudebug performance> {"children": [], "totalCount": 0}\n'
        self.assertEqual(apple.json_lines(text), [{"a": 1}, {"children": [], "totalCount": 0}])


class Profile(unittest.TestCase):
    ENC = [{"name": "asc0", "label": "a", "start": 0, "end": 100, "dur": 100},
           {"name": "asc1", "label": "b", "start": 0, "end": 1000, "dur": 1000},   # whole-frame placeholder
           {"name": "asc2", "label": "c", "start": 200, "end": 1000, "dur": 800},
           {"name": "asc3", "label": "d", "start": 500, "end": 600, "dur": 100}]

    def test_placeholders_left_out_and_busy_is_the_union(self):
        series = {"alu_utilization": ([(50, 10.0), (300, 40.0), (550, 60.0), (900, 20.0)], "%", 30.0)}
        rows, span = apple.per_encoder(self.ENC, series)
        self.assertEqual(span, 1000)
        self.assertEqual([r["name"] for r in rows], ["asc2", "asc0", "asc3"])
        self.assertEqual(rows[0]["alu_utilization"], 40.0)   # mean of 40, 60, 20
        self.assertEqual(apple.busy_ns(self.ENC, span), 900)

    def test_a_short_window_takes_the_nearest_sample(self):
        self.assertEqual(apple.window_mean([(0, 1.0), (100, 5.0)], 60, 70), 5.0)
        self.assertIsNone(apple.window_mean([], 0, 1))

    def test_report_names_the_columns(self):
        series = {"alu_utilization": ([(50, 10.0)], "%", 10.0)}
        text, rows = apple.profile_report("x.gputrace", self.ENC, series)
        self.assertIn("GPU busy (union) 0.00 ms", text)
        self.assertIn("alu", text.splitlines()[-4])


if __name__ == "__main__":
    unittest.main()

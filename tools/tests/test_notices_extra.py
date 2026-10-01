# SPDX-License-Identifier: GPL-3.0-or-later
"""build/notices-extra: each committed licence text is the recorded upstream bytes."""

import hashlib
import json
from pathlib import Path
import unittest

EXTRA = Path(__file__).resolve().parents[2] / "build/notices-extra"


class NoticesExtra(unittest.TestCase):
    def test_bytes_match_the_recorded_upstream(self):
        files = json.loads((EXTRA / "sources.json").read_text())["files"]
        self.assertEqual(sorted(files), sorted(p.name for p in EXTRA.iterdir() if p.name != "sources.json"))
        for name, record in files.items():
            self.assertEqual(hashlib.sha256((EXTRA / name).read_bytes()).hexdigest(), record["sha256"], name)
            if "derived_from" in record:
                self.assertIn("written by Playport", (EXTRA / name).read_text())
            else:
                self.assertRegex(record["commit"], r"^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()

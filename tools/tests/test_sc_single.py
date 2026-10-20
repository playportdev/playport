# SPDX-License-Identifier: GPL-3.0-or-later
"""Execute the shipped Social Club page-bridge thunks on synthetic Win64 ABIs.

Ported from willfaust/Madeira's six sc-rph host tests. No proprietary helper
code, credentials, network or Wine session is needed.
"""
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name("sc_single")


class ScSingleTests(unittest.TestCase):
    def test_page_bridge_fixtures(self):
        scratch = ROOT / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        for script in sorted(FIXTURES.glob("check-*.py")):
            with self.subTest(source=script.name):
                result = subprocess.run([sys.executable, str(script)], cwd=ROOT,
                                        env={**os.environ, "TMPDIR": str(scratch)},
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()

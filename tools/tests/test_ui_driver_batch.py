# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the actual dev-only queue seam; UIKit wiring is separately inspected."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("swiftc"), "Swift compiler not installed (source-only CI)")
class UIDriverBatchTests(unittest.TestCase):
    def test_production_game_section_mapping(self):
        scratch = REPO / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            main = root / "main.swift"
            main.write_text('''
let expected = ["runtime": "opt:runtime", "graphicsoptions": "opt:graphicsOptions",
                "graphics": "opt:aspect", "controls": "opt:layout", "game": "opt:version",
                "files": "opt:files", "developer": "opt:ordering-first", "ordering": "opt:ordering-first",
                "steam": "opt:steamAPI"]
for (section, row) in expected {
    precondition(UIDriverGameSection(rawValue: section)?.row(firstOrdering: "first") == row, section)
}
for panel in ["gyro", "controller"] { precondition(UIDriverGameSection(rawValue: panel) != nil) }
for bad in ["nope", "Runtime", "", "graphicsOptions"] { precondition(UIDriverGameSection(rawValue: bad) == nil) }
print("UIDriverGameSection: exact rows, retained sections/panels, unknown rejection pass")
''')
            env = dict(os.environ, TMPDIR=str(root))
            result = subprocess.run(["swiftc", "-module-cache-path", str(root / "modules"),
                str(REPO / "app/Sources/S1Probe/Dev/UIDriverGameSection.swift"), str(main),
                "-o", str(root / "test")], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_production_queue(self):
        scratch = REPO / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            env = dict(os.environ, TMPDIR=str(root), DRIVER_TEST_DIR=str(root),
                       S1_MODE="ui", TITLE_NONCE="ab12cd34")
            result = subprocess.run([
                "swiftc", "-parse-as-library", "-module-cache-path", str(root / "modules"),
                str(REPO / "app/Sources/S1Probe/Dev/UIDriverBatch.swift"),
                str(REPO / "app/Sources/S1Probe/Dev/DriverContinuation.swift"),
                str(REPO / "tools/tests/fixtures/UIDriverBatchTests.swift"),
                "-o", str(root / "test"),
            ], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

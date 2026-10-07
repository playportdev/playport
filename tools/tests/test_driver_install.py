# SPDX-License-Identifier: GPL-3.0-or-later
"""Host tests of the dev driver's actual Swift GOG install postcondition."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("swiftc"), "Swift compiler not installed (source-only CI)")
class DriverInstallTest(unittest.TestCase):
    def test_gog_waits_for_adoption_not_a_version_change(self):
        scratch = REPO / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            root = Path(directory)
            main = root / "main.swift"
            main.write_text('''
func ready(_ version: String?, _ requested: String? = nil, scanning: Bool = false) -> Bool {
    DriverInstallCheck.gogReady(version: version, requestedBuild: requested, scanning: scanning)
}
// Fresh install of latest: nil request must not bypass adoption (PLA-57).
precondition(!ready(nil))
precondition(!ready(nil, scanning: true))
precondition(!ready("100", scanning: true))
precondition(ready("100"))
// Latest already installed: no version change is needed, but wait for its scan.
precondition(!ready("100", scanning: true))
precondition(ready("100"))
// An explicit build, including a deliberate downgrade, must match exactly.
precondition(!ready(nil, "100"))
precondition(!ready("200", "100"))
precondition(!ready("100", "100", scanning: true))
precondition(ready("100", "100"))
// Reinstalling the same explicit build also waits for adoption.
precondition(!ready("200", "200", scanning: true))
precondition(ready("200", "200"))
''')
            executable = root / "driver-install-test"
            env = dict(os.environ, TMPDIR=str(root))
            subprocess.run([
                "swiftc", "-module-cache-path", str(root / "modules"),
                str(REPO / "app/Sources/S1Probe/Dev/DriverInstallCheck.swift"),
                str(main), "-o", str(executable),
            ], check=True, capture_output=True, env=env)
            subprocess.run([str(executable)], check=True, capture_output=True, env=env)


if __name__ == "__main__":
    unittest.main()

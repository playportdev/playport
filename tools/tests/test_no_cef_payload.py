# SPDX-License-Identifier: GPL-3.0-or-later
"""pp verify fails any IPA, dev or release, that carries a CEF payload (decision 0169)."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_no_cef', REPO / 'build/verify-ipa.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class NoCEFPayload(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.app = Path(tmp.name) / 'S1Probe.app'
        for rel in ('S1Probe', 'artifacts.tsv', 'steamapi/steam_api64.dll', 'mono/lib/mono.dll'):
            (self.app / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.app / rel).write_bytes(b'x')
        verify.failures.clear()
        self.addCleanup(verify.failures.clear)

    def failures(self):
        with contextlib.redirect_stdout(io.StringIO()):
            verify.cef_checks(self.app)
        return list(verify.failures)

    def add(self, rel):
        (self.app / rel).parent.mkdir(parents=True, exist_ok=True)
        (self.app / rel).write_bytes(b'MZ')

    def test_an_app_without_cef_passes(self):
        self.assertEqual(self.failures(), [])

    def test_the_old_dev_payload_fails(self):
        self.add('cef/143.0.14/libcef.dll')
        self.add('cef/143.0.14/chrome_elf.dll')
        self.assertEqual(len(self.failures()), 1)

    def test_a_renamed_payload_directory_fails(self):
        for name in ('hidden/libcef.dll', 'hidden/LIBCEF.DLL', 'hidden/Chrome_Elf.dll'):
            with self.subTest(name=name):
                verify.failures.clear()
                self.add(name)
                self.assertEqual(len(self.failures()), 1)
                (self.app / name).unlink()

    def test_an_empty_cef_directory_fails(self):
        (self.app / 'Cef').mkdir()
        self.assertEqual(len(self.failures()), 1)


if __name__ == '__main__':
    unittest.main()

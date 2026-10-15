# SPDX-License-Identifier: GPL-3.0-or-later
"""pp phone put: tools/afc.py's import_refusal and phonelib.Phone.put_import write only
Documents/Import/NAME/FILE, the app's import inbox. No phone is touched."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools"))
import phonelib  # noqa: E402

BAD = ("Documents/protect.exe", "Documents/Import/protect.exe", "Documents/Import/protect/",
       "Documents/Import//protect.exe", "Documents/Import/../s1-host.log", "Documents/Import/protect/..",
       "Documents/Import/./protect.exe", "Documents/Import/protect/sub/protect.exe",
       "Documents/prefix/drive_c/protect.exe", "Import/protect/protect.exe", "/Documents/Import/a/b",
       "Documents/Import/pro\\tect/a.exe", "Documents/Import/protect/a;b", "Library/Import/protect/a")


class ImportRefusal(unittest.TestCase):
    def test_only_a_file_in_a_folder_of_the_import_inbox(self):
        refuse = phonelib.afc_tool().import_refusal
        for ok in ("Documents/Import/protect/protect.exe", "Documents/Import/dir protect (2)/a.b+c-d_e.dll"):
            self.assertIsNone(refuse(ok), ok)
        for bad in BAD:
            self.assertIsNotNone(refuse(bad), bad)


class PutImport(unittest.TestCase):
    """Phone.put_import with afc.py's call recorded, not run (as test_pad's Phone fakes put)."""

    def setUp(self):
        self.d = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        self.local = os.path.join(self.d, "protect.exe")
        with open(self.local, "wb") as f:
            f.write(b"MZ\x90\x00")
        self.phone = phonelib.Phone(out=self.d)
        self.calls = []
        self.phone.afc = lambda name, *args, data=None, secs=120, check=True: (
            self.calls.append((name, args, data)) or "Documents/Import/protect/protect.exe: 4 bytes\n")

    def tearDown(self):
        shutil.rmtree(self.d)

    def test_sends_the_file_whole_to_put_import(self):
        said = self.phone.put_import(self.local, "Documents/Import/protect/protect.exe")
        self.assertEqual(self.calls, [("put-import", ("put-import", "Documents/Import/protect/protect.exe"),
                                       b"MZ\x90\x00")])
        self.assertIn("4 bytes", said)

    def test_refuses_before_the_phone_is_asked(self):
        for bad in BAD:
            with self.assertRaises(phonelib.PhoneError, msg=bad):
                self.phone.put_import(self.local, bad)
        with self.assertRaises(phonelib.PhoneError):
            self.phone.put_import(self.d, "Documents/Import/protect/protect.exe")   # a directory
        self.assertEqual(self.calls, [])


class PpPhonePut(unittest.TestCase):
    def test_refuses_a_path_outside_the_inbox_without_the_lock(self):
        for args in (["put", os.path.join(REPO, "pp"), "Documents/s1-host.log"],
                     ["put", os.path.join(REPO, "pp"), "Documents/Import/../x/pp"],
                     ["put", os.path.join(REPO, "no-such-file"), "Documents/Import/protect/protect.exe"],
                     ["put", os.path.join(REPO, "pp")]):
            r = subprocess.run([sys.executable, os.path.join(REPO, "pp"), "phone", *args], capture_output=True,
                               text=True, timeout=60)
            self.assertEqual(r.returncode, 2, args)
            self.assertNotIn("lock", r.stdout + r.stderr, args)


if __name__ == "__main__":
    unittest.main()

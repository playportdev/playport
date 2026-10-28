# SPDX-License-Identifier: GPL-3.0-or-later
"""Repeated queries use the NSI fallback without reprobes of its absent device."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NSIDevice(unittest.TestCase):
    def test_device_transport(self):
        patches = list((ROOT / "patches/wine-pe").glob("*-nsi-remember-a-missing-device-when-the-in-process-fa*.patch"))
        self.assertEqual(len(patches), 1)
        # Compile the helper's context + added lines, not a reimplementation
        # or just the cache. Its final closing brace is outside the diff's
        # standard three-line context; only that delimiter is supplied here.
        diff = patches[0].read_text().split("\n+++ b/dlls/nsi/nsi.c\n", 1)[1]
        postimage = "\n".join(line[1:] for line in diff.splitlines()
                              if line.startswith(("+", " ")))
        start = postimage.index("static inline HANDLE get_nsi_device(")
        last = "    return *cached_device;"
        end = postimage.index(last, start) + len(last)
        helper = postimage[start:end] + "\n}\n"
        work = ROOT / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="nsi-device-", dir=work) as tmp:
            directory = Path(tmp)
            (directory / "nsi_device.h").write_text(helper)
            binary = directory / "test"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                            "-pthread", "-fsanitize=address,undefined", "-I", str(directory),
                            str(Path(__file__).with_name("nsi_device_test.c")), "-o", str(binary)], check=True)
            for case in ("missing", "path_missing", "no_fallback", "transient", "modes", "present", "parallel"):
                with self.subTest(case=case):
                    subprocess.run([str(binary), case], check=True)

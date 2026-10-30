# SPDX-License-Identifier: GPL-3.0-or-later
"""build/verify-ipa.py's release variant: an executable with an Xbox surface fails
(decision 0166: the Xbox store is in the dev app only), one with only the store's
identity (ContentKit's Store.xbox, PlayportKit's LibraryFilter.xbox) passes."""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


verify = load("verify_ipa_xbox", "build/verify-ipa.py")

# A release executable's own: the quiet-runtime switch, its log, the donor pool, and the
# Xbox store's identity as data (its label, its title prefix, its enum cases, lower-case).
CLEAN_BODY = b"\0MADEIRA_NO_DIAGNOSTICS\0playport.log\0Xbox\0xbox-\0Games from \0"
CLEAN_SYMS = ["_pp_guest_pool_install", "_playport_guest_memory_backing",
              "_$s10ContentKit5StoreO4xboxyA2CmF", "_$s11PlayportKit13LibraryFilterO4xboxyA2CmF",
              "_$s10ContentKit12StoreGameKeyV11isProductIDySbSSFZ", "_$s8Playport11LibraryGridC7filtersSay11PlayportKit0C6FilterOGvgZ",
              "_XboxNotSwift", "_$s8Playport12addXboxStoreyyF"]
# Sources/S1Probe/Dev/XboxLibrary.swift compiled into the Playport module.
PLANTED_SYMS = ["_$s8Playport11XboxLibraryO9emptyTextSSvpZ", "_$s8Playport11XboxLibraryOMn"]
PLANTED_BODY = CLEAN_BODY + b"Games you own on Xbox and PC Game Pass titles appear here. Xbox is in the dev app only.\0"


class ReleaseXboxGate(unittest.TestCase):
    def test_the_marker_is_the_dev_apps_empty_xbox_library_text(self):
        source = (REPO / "app/Sources/S1Probe/Dev/XboxLibrary.swift").read_text()
        for marker in verify.XBOX_STRINGS:
            self.assertIn(marker.decode(), source)
        self.assertIn("enum XboxLibrary", source)

    def test_identity_alone_is_not_a_surface(self):
        self.assertEqual(verify.xbox_surfaces(CLEAN_BODY, CLEAN_SYMS), [])

    def test_a_planted_type_or_text_is_found(self):
        self.assertEqual(verify.xbox_surfaces(CLEAN_BODY, CLEAN_SYMS + PLANTED_SYMS), ["XboxLibrary"])
        self.assertEqual(verify.xbox_surfaces(PLANTED_BODY, CLEAN_SYMS), ["Xbox is in the dev app only"])
        self.assertEqual(verify.xbox_surfaces(PLANTED_BODY, PLANTED_SYMS),
                         ["Xbox is in the dev app only", "XboxLibrary"])

    def release_failures(self, body, syms):
        """release_checks on an executable with these bytes and llvm-nm symbols: its failures."""
        nm = subprocess.CompletedProcess(["llvm-nm"], 0, "".join(f"0000000000000000 T {s}\n" for s in syms), "")
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "Playport"
            exe.write_bytes(body)
            verify.failures.clear()
            with mock.patch.object(verify.subprocess, "run", return_value=nm), \
                    mock.patch("builtins.print"):
                verify.release_checks(exe, {})
            return list(verify.failures)

    def test_release_checks_fail_a_planted_executable_and_pass_a_clean_one(self):
        self.assertEqual(self.release_failures(CLEAN_BODY, CLEAN_SYMS), [])
        for body, syms in ((PLANTED_BODY, CLEAN_SYMS), (CLEAN_BODY, CLEAN_SYMS + PLANTED_SYMS)):
            failed = self.release_failures(body, syms)
            self.assertEqual(len(failed), 1, failed)
            self.assertIn("Xbox", failed[0])


if __name__ == "__main__":
    unittest.main()

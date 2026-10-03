# SPDX-License-Identifier: GPL-3.0-or-later
"""WoW64 build scaffolding: strip discovery, packaging and IPA machine gates."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import yaml

REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


strip = load("wow64_strip", "build/stages/wine-pe-strip.py")
verify = load("wow64_verify", "build/verify-ipa.py")
stage = load("wow64_stage", "build/stages/stage-artifacts.py")


def pe(machine=0x14c, magic=0x10b):
    body = bytearray(256)
    body[:2] = b"MZ"
    struct.pack_into("<I", body, 0x3c, 0x80)
    body[0x40:0x50] = b"Wine builtin DLL"
    body[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", body, 0x84, machine)
    struct.pack_into("<H", body, 0x98, magic)
    return bytes(body)


class WoW64Build(unittest.TestCase):
    def test_strip_discovers_all_three_sets(self):
        with tempfile.TemporaryDirectory() as tmp:
            for tree, arches in strip.TREES.items():
                for arch in arches:
                    d = Path(tmp) / tree / "dlls/ntdll" / arch
                    d.mkdir(parents=True)
                    (d / "ntdll.dll").write_bytes(pe())
                    (d / "signal.o").write_bytes(b"intermediate")
            found = list(strip.sources(tmp))
            self.assertEqual(len(found), 3)
            self.assertTrue(any("i386-windows" in name for name in found))
            self.assertTrue(all(name.endswith("ntdll.dll") for name in found))

    def test_both_variants_package_i386(self):
        text = (REPO / "app/xtool.yml").read_text()
        self.assertIn("Sources/S1Probe/Runtime/i386-windows", yaml.safe_load(text)["resources"])
        self.assertIn("Runtime/i386-windows", yaml.safe_load(stage.release_xtool_yml(text))["resources"])
        self.assertIn("wow64.dll", stage.EXTRA_PE["aarch64"])
        self.assertIn("wow64win.dll", stage.EXTRA_PE["aarch64"])

    def test_machine_parser_rejects_truncated_and_non_pe(self):
        self.assertEqual(verify.pe_machine_magic(pe()), (0x14c, 0x10b))
        for body in (b"", b"not PE", pe()[:0x99], pe()[:0x80]):
            self.assertIsNone(verify.pe_machine_magic(body))

    def test_wow64_gate_rejects_wrong_machine_magic_and_missing_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            guest = [f"Runtime/i386-windows/{n}.dll" for n in ("ntdll", "kernel32")]
            host = [f"Runtime/aarch64-windows/{n}.dll" for n in ("wow64", "wow64win", "xtajit")]
            for name in guest + host:
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(pe() if name in guest else pe(0xaa64, 0x20b))
            rows = [("resource", name) for name in guest + host]
            exports = {"BTCpuProcessInit", "BTCpuThreadInit", "BTCpuSimulate"}

            def run():
                checks = []
                with patch.object(verify, "check", side_effect=lambda ok, _: checks.append(bool(ok))), \
                     patch.object(verify, "pe_table", return_value=exports):
                    verify.wow64_checks(lambda name: root / name, rows)
                return checks

            self.assertTrue(all(run()))
            for wrong in (pe(0x8664, 0x20b), pe(0x14c, 0x20b)):
                (root / guest[0]).write_bytes(wrong)
                self.assertFalse(all(run()))
            (root / guest[0]).write_bytes(pe())
            (root / host[2]).unlink()
            self.assertFalse(all(run()))
            rows.clear()
            self.assertFalse(all(run()))


if __name__ == "__main__":
    unittest.main()

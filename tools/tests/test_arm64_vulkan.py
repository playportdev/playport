# SPDX-License-Identifier: GPL-3.0-or-later
"""The aarch64 Vulkan backend a native ARM64 child loads (PLA-513, decision 0170): staged rows
and the IPA gate on presence and PE machine."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify = load("arm64_vulkan_verify", "build/verify-ipa.py")


def committed_rows():
    return [l.split("\t") for l in (REPO / "app/artifacts.tsv").read_text().splitlines()
            if l and not l.startswith("#")]


DLLS = ["Runtime/vulkan/aarch64-windows/d3d12.dll", "Runtime/vulkan/aarch64-windows/d3d12core.dll",
        "Runtime/vulkan/aarch64-windows/dxgi.dll", "Runtime/vulkan-loader/aarch64-windows/vulkan-1.dll"]
MANIFEST = "Runtime/vulkan-loader/aarch64-windows/winevulkan.json"


def pe(machine=0xaa64, magic=0x20b, builtin=True):
    body = bytearray(256)
    body[:2] = b"MZ"
    struct.pack_into("<I", body, 0x3c, 0x80)
    if builtin:
        body[0x40:0x50] = b"Wine builtin DLL"
    body[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", body, 0x84, machine)
    struct.pack_into("<H", body, 0x98, magic)
    return bytes(body)


class Arm64Vulkan(unittest.TestCase):
    def test_records_list_the_aarch64_set(self):
        rows = {r[1]: (r[4], r[5], r[6]) for r in committed_rows() if r[0] == "resource"}
        for dest in DLLS + [MANIFEST]:
            root = "vulkan-loader" if "/vulkan-loader/" in dest else "vulkan-pe"
            name = dest.rsplit("/", 1)[1]
            prov = "P6-vulkan-loader" if root == "vulkan-loader" else "P6-vulkan-pe"
            self.assertEqual(rows.get(dest), (root, f"aarch64-windows/{name}", prov), dest)

    def test_gate_fails_a_missing_or_wrong_machine_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in DLLS + [MANIFEST]:
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b"{}" if name == MANIFEST else pe())
            rows = [("resource", name) for name in DLLS + [MANIFEST]]

            def run():
                checks = []
                with patch.object(verify, "check", side_effect=lambda ok, _: checks.append(bool(ok))):
                    verify.arm64_vulkan_checks(lambda name: root / name, rows)
                return checks

            self.assertTrue(run())
            self.assertTrue(all(run()))
            for name in DLLS:
                good = (root / name).read_bytes()
                # arm64ec builtins report AMD64; i386 is PE32; a native (unmarked) DLL is not found
                for wrong in (pe(0x8664, 0x20b), pe(0x14c, 0x10b), pe(0xaa64, 0x10b), pe(builtin=False), b""):
                    (root / name).write_bytes(wrong)
                    self.assertFalse(all(run()), (name, wrong[:0x9a]))
                (root / name).write_bytes(good)
                (root / name).unlink()
                self.assertFalse(all(run()), name)
                (root / name).write_bytes(good)
                rows.remove(("resource", name))
                self.assertFalse(all(run()), name)
                rows.append(("resource", name))
            self.assertTrue(all(run()))
            rows.remove(("resource", MANIFEST))
            self.assertFalse(all(run()))


if __name__ == "__main__":
    unittest.main()

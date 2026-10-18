# SPDX-License-Identifier: GPL-3.0-or-later
"""The x64<->EC call ring (patches/fex 0051, PLA-401): Module.S's two writers and
Module.cpp's reader agree on its layout, and an unarmed process pays one load and a
branch per transition."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCH = REPO / "patches/fex/0051-ARM64EC-log-the-faulting-thread-s-last-x64-EC-calls-.patch"


def added(patch: str, path: str) -> str:
    """The lines the patch adds to one file."""
    out, inside = [], False
    for line in patch.splitlines():
        if line.startswith("diff --git"):
            inside = line.endswith(f" b/{path}")
        elif inside and line.startswith("+") and not line.startswith("+++"):
            out.append(line[1:])
    return "\n".join(out) + "\n"


class ECCallRing(unittest.TestCase):
    def setUp(self):
        patch = PATCH.read_text()
        self.asm = added(patch, "Source/Windows/ARM64EC/Module.S")
        self.cpp = added(patch, "Source/Windows/ARM64EC/Module.cpp")

    def test_layout_agrees(self):
        rings = int(re.search(r"IosEcRingRings = (\d+)", self.cpp).group(1))
        entries = int(re.search(r"IosEcRingEntries = (\d+)", self.cpp).group(1))
        self.assertIn("4096 + IosEcRingRings * IosEcRingEntries * 64", self.cpp)
        self.assertIn("reinterpret_cast<const uint64_t*>(IosEcRing + 4096)", self.cpp)
        self.assertIn("(Teb >> 13) & (IosEcRingRings - 1)", self.cpp)
        # Both writers: ring = TEB bits 13.., index masked to the entries, 64-byte entries.
        self.assertEqual(len(re.findall(r"ubfx x\d+, x17, #13, #(\d+)", self.asm)), 2)
        for bits in re.findall(r"ubfx x\d+, x17, #13, #(\d+)", self.asm):
            self.assertEqual(1 << int(bits), rings)
        for mask in re.findall(r"and x\d+, x\d+, #(\d+)", self.asm):
            self.assertEqual(int(mask) + 1, entries)
        for shift in re.findall(r"add x16, x16, x\d+, lsl #(\d+)\s+// ring base", self.asm):
            self.assertEqual(1 << int(shift), entries * 64)
        self.assertEqual(self.asm.count("add x16, x16, #4096"), 2)
        self.assertEqual(len(re.findall(r", lsl #6\n", self.asm)), 2)

    def test_fields_agree(self):
        # The reader's fields: E[0] TEB, E[1] target, E[2] return address or rax,
        # E[3] rcx, E[4] rdx, E[5] time, E[6] kind (1 call, 2 return).
        self.assertIn("stp x17, x9, [x16]", self.asm)
        self.assertIn("stp x4, x0, [x16, #16]", self.asm)
        self.assertIn("stp x1, x4, [x16, #32]", self.asm)
        self.assertIn("str x8, [x16, #16]", self.asm)
        self.assertIn("str x4, [x16, #40]", self.asm)
        self.assertEqual(self.asm.count("str x4, [x16, #48]"), 2)
        self.assertIn("E[6] == 1", self.cpp)
        self.assertIn("E[6] != 2", self.cpp)

    def test_unarmed_is_one_load_and_a_branch(self):
        self.assertEqual(self.asm.count("ldr x16, [x16, #:lo12:IosEcRing]"), 2)
        self.assertIn("cbz x16, 3f", self.asm)
        self.assertIn("cbz x16, 31f", self.asm)
        self.assertIn("uint64_t IosEcRing = 0;", self.cpp)
        self.assertIn('getenv("FEX_EC_CALL_RING")', self.cpp)


if __name__ == "__main__":
    unittest.main()

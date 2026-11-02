# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the JIT tail's code-buffer cap shipped in madeira-unix 0233 (decision 0116 as amended
2026-10-30, PLA-476): at most 64 MiB, the room rule of 0157 unchanged."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0233-ntdll-cap-a-JIT-code-buffer-grant-at-64-MiB-not-128.patch"


def added_header():
    section = PATCH.read_text().split("diff --git a/build/ntdll-unix/pp_jit_tail_cap.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_jit_tail_cap.h"
#include <assert.h>

#define MiB(n) ((size_t)(n) << 20)

int main(void) {
    /* A lone game in an 896 MiB pool: room for 128 MiB, granted 64 (it was 128). */
    assert(pp_jit_tail_cap(MiB(896), MiB(300), MiB(64), 0) == MiB(64));
    /* Hollow Knight's grant with 3 other processes, 512 MiB pool: 64, not 128. */
    assert(pp_jit_tail_cap(MiB(512), MiB(48), MiB(64), 3) == MiB(64));
    /* l11's two refusals of RDR2's asks, 8 other processes (head 250 MiB): 64 at
     * tail_resv 0x17024000, 32 at 0x1b024000, as before the change. */
    assert(pp_jit_tail_cap(MiB(896), MiB(250), 0x17024000, 8) == MiB(64));
    assert(pp_jit_tail_cap(MiB(896), MiB(250), 0x1b024000, 8) == MiB(32));
    /* No room at all: still one initial-size buffer (FEX's own floor). */
    assert(pp_jit_tail_cap(MiB(896), MiB(500), MiB(400), 8) == MiB(16));
    assert(pp_jit_tail_cap(MiB(64), MiB(100), MiB(100), 0) == MiB(16));
    /* Each other process keeps 16 MiB of the room. */
    assert(pp_jit_tail_cap(MiB(896), MiB(700), 0, 0) == MiB(64));    /* room 148 */
    assert(pp_jit_tail_cap(MiB(896), MiB(700), 0, 6) == MiB(32));    /* room 52 */
    return 0;
}
'''


class JitTailCapTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            (d / "pp_jit_tail_cap.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)


if __name__ == "__main__":
    unittest.main()

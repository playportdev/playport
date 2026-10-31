# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0253's pp_single_step.h (PLA-514): a native ARM64 thread that continues
with Cpsr.SS steps one instruction. One that reads or writes the pc is carried out on the context; any other
is left to run out of line. The words are World of Warcraft's own where it has them (its stepped import
resolver at 0xd6cc..0xd89c)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0253-ntdll-single-step-a-native-ARM64-thread-that-continu.patch"
HEADER = "build/ntdll-unix/pp_single_step.h"

TEST_C = r'''
#include "pp_single_step.h"
#include <assert.h>
#include <stdio.h>

static uint64_t x[31];
static unsigned char v[32][16];

static uint64_t step(uint64_t pc, uint32_t cpsr, uint32_t insn, int *in_place)
{
    *in_place = ppss_step_in_place(x, &pc, cpsr, v, insn);
    return pc;
}

int main(void)
{
    const uint64_t at = 0x10866e000ull;
    int done;
    static const uint64_t literal[2] = { 0x1122334455667788ull, 0x99aabbccddeeff00ull };

    /* Data processing and memory access run out of line, unchanged. */
    assert(step(at, 0, 0xd283b7e8, &done) == at && !done);          /* mov x8, #0x1dbf */
    assert(step(at, 0, 0xf9000be8, &done) == at && !done);          /* str x8, [sp, #0x10] */
    assert(step(at, 0, 0x00009720, &done) == at && !done);          /* udf: raises in its slot */

    /* b, bl */
    x[30] = 0;
    assert(step(at, 0, 0x17ffffef, &done) == at - 0x44 && done);   /* b .-0x44 */
    assert(step(at, 0, 0x94003e31, &done) == at + 0xf8c4 && done && x[30] == at + 4);

    /* b.lo: taken with C clear, not with C set */
    assert(step(at, 0x00000000, 0x54000043, &done) == at + 8 && done);
    assert(step(at, 0x20000000, 0x54000043, &done) == at + 4 && done);
    /* b.eq on Z */
    assert(step(at, 0x40000000, 0x5400c7a0, &done) == at + 0x18f4);
    assert(step(at, 0x00000000, 0x5400c7a0, &done) == at + 4);

    /* cbz x19 / cbnz w6, tbz w9 #3 */
    x[19] = 0;  assert(step(at, 0, 0xb40011f3, &done) == at + 0x23c && done);
    x[19] = 7;  assert(step(at, 0, 0xb40011f3, &done) == at + 4);
    x[6] = 0x100000000ull;                                          /* w6 is 0 */
    assert(step(at, 0, 0x35000226, &done) == at + 4);
    x[9] = 8;   assert(step(at, 0, 0x36180049, &done) == at + 4);   /* tbz w9, #3, .+8: bit set */
    x[9] = 0;   assert(step(at, 0, 0x36180049, &done) == at + 8);

    /* blr x8, ret, br x16 */
    x[8] = 0x7000001000ull; x[30] = 0;
    assert(step(at, 0, 0xd63f0100, &done) == 0x7000001000ull && done && x[30] == at + 4);
    assert(step(at, 0, 0xd65f03c0, &done) == at + 4);
    x[16] = 0x123450ull;
    assert(step(at, 0, 0xd61f0200, &done) == 0x123450ull);

    /* adrp x8, page +0x3873000; adr x0, .+0x20 */
    assert(step(at, 0, 0xf001c388, &done) == at + 4 && done && x[8] == (at & ~0xfffull) + 0x3873000ull);
    assert(step(at, 0, 0x10000100, &done) == at + 4 && x[0] == at + 0x20);

    /* ldr x1, ldr w2, ldrsw x3, ldr d4, ldr q5 from a literal; prfm loads nothing */
    {
        uint64_t lit = (uint64_t)(uintptr_t)literal;
        uint64_t pc = lit - 8;
        assert(ppss_step_in_place(x, &pc, 0, v, 0x58000041) && pc == lit - 4 && x[1] == literal[0]);
        pc = lit - 8;
        assert(ppss_step_in_place(x, &pc, 0, v, 0x18000042) && x[2] == 0x55667788ull);
        pc = lit - 8; x[3] = 0;
        assert(ppss_step_in_place(x, &pc, 0, v, 0x98000043) && x[3] == 0x55667788ull);
        pc = lit + 4 - 8;
        assert(ppss_step_in_place(x, &pc, 0, v, 0x98000043) && x[3] == 0x1122334455667788ull >> 32);
        pc = lit + 12 - 8;
        assert(ppss_step_in_place(x, &pc, 0, v, 0x98000043) && x[3] == 0xffffffff99aabbccull);
        pc = lit - 8;
        assert(ppss_step_in_place(x, &pc, 0, v, 0x5c000044) && !memcmp(v[4], literal, 8) && !v[4][8]);
        pc = lit - 8;
        assert(ppss_step_in_place(x, &pc, 0, v, 0x9c000045) && !memcmp(v[5], literal, 16));
        pc = lit - 8; x[7] = 5;
        assert(ppss_step_in_place(x, &pc, 0, v, 0xd8000047) && pc == lit - 4 && x[7] == 5);
    }
    puts("single step: ok");
    return 0;
}
'''


class SingleStepTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            subprocess.run(["git", "apply", f"--include={HEADER}", str(PATCH)], cwd=d, check=True)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            out = subprocess.run([str(d / "t")], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertIn("single step: ok", out.stdout)


if __name__ == "__main__":
    unittest.main()

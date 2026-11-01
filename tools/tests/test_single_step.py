# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0253's pp_single_step.h (PLA-514): a native ARM64 thread that continues
with Cpsr.SS steps one instruction. One that reads or writes the pc is carried out on the context; any other
is left to run out of line. The words are World of Warcraft's own where it has them (its stepped import
resolver at 0xd6cc..0xd89c). A step at a site the x18 patcher branched to a trampoline (0259, 0263) is the
patched instruction: a CBZ/CBNZ/TBZ/TBNZ on x18 goes to its target or on, by the TEB."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCHES = [ROOT / "patches/madeira-unix/0253-ntdll-single-step-a-native-ARM64-thread-that-continu.patch",
           ROOT / "patches/madeira-unix/0259-ntdll-step-an-x18-patched-instruction-as-one-instruc.patch",
           ROOT / "patches/madeira-unix/0263-virtual-x18-patch-every-instruction-that-reads-x18.patch"]
HEADER = "build/ntdll-unix/pp_single_step.h"

TEST_C = r'''
#include "pp_single_step.h"
#include <assert.h>
#include <stdio.h>

/* B from one address to another */
#define B_TO(from, to) (0x14000000u | (uint32_t)((((to) - (from)) >> 2) & 0x3ffffff))

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
    /* The x18 patcher's trampolines: cmp w9, w18, asr #5 at pc, and mov x8, x18 */
    {
        uint64_t pc = 0x10a44d000ull, tramp = 0x11017cce8ull, to = 0;
        uint32_t t[9] = { 0xf81f0ff1, 0xd53bd071, 0x927df231, 0xf944a231, 0x4b91153f, 0xf84107f1, 0,
                          0xd503201f, 0xd503201f };
        uint32_t m[4] = { 0xd53bd068, 0x927df108, 0xf944a108, 0 };
        unsigned reg = 0; uint32_t op = 0;
        t[6] = B_TO(tramp + 24, pc + 4);
        assert(ppss_x18_tramp(t, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_OP && reg == 17 && op == 0x4b91153f);
        assert(ppss_x18_tramp(t, tramp, pc + 8, &reg, &op, &to) == PPSS_TRAMP_NONE);   /* returns elsewhere */
        m[3] = B_TO(tramp + 12, pc + 4);
        assert(ppss_x18_tramp(m, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_MOV && reg == 8);
        t[1] = 0xd503201f;
        assert(ppss_x18_tramp(t, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_NONE);
        /* subs x17, x18, x16, lsr #28 names x16 and x17: its scratch register is x15 (0263) */
        {
            uint32_t u[7] = { 0xf81f0fef, 0xd53bd06f, 0x927df1ef, 0xf944a1ef, 0xeb5071f1, 0xf84107ef, 0 };
            u[6] = B_TO(tramp + 24, pc + 4);
            assert(ppss_x18_tramp(u, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_OP && reg == 15 && op == 0xeb5071f1);
        }
    }
    /* A branch's (0263), for cbz x18, target at pc: str; mrs; and; ldr; cbz x17, #12;
       ldr x17, [sp], #16; b pc+4; ldr x17, [sp], #16; b target. Words 0-6 look like an
       ordinary site's, whose instruction would be cbz x17, #12: a step there took the
       guest's x17 for the TEB and went to pc+12. */
    {
        uint64_t pc = 0x10a44d000ull, tramp = 0x11017cce8ull, target = pc - 0x1230, to = 0;
        uint32_t t[9] = { 0xf81f0ff1, 0xd53bd071, 0x927df231, 0xf944a231, 0xb4000071, 0xf84107f1, 0,
                          0xf84107f1, 0 };
        unsigned reg = 0; uint32_t op = 0;
        t[6] = B_TO(tramp + 24, pc + 4);
        t[8] = B_TO(tramp + 32, target);
        assert(ppss_x18_tramp(t, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_BRANCH && reg == 17 &&
               op == 0xb4000071 && to == target);
        assert(ppss_x18_branch_next(0x7000ull, op, pc, to) == pc + 4);              /* cbz x17: the TEB is not 0 */
        assert(ppss_x18_branch_next(0, op, pc, to) == target);
        assert(ppss_x18_branch_next(0x7000ull, 0xb5000071, pc, to) == target);     /* cbnz x17 */
        assert(ppss_x18_branch_next(0x100000000ull, 0x34000071, pc, to) == target); /* cbz w17: w is 0 */
        assert(ppss_x18_branch_next(0x100000000ull, 0x35000071, pc, to) == pc + 4); /* cbnz w17 */
        assert(ppss_x18_branch_next(0x8ull, 0x36180071, pc, to) == pc + 4);         /* tbz x17, #3 */
        assert(ppss_x18_branch_next(0x7ull, 0x36180071, pc, to) == target);
        assert(ppss_x18_branch_next(1ull << 40, 0xb7400071, pc, to) == target);     /* tbnz x17, #40 */
        assert(ppss_x18_branch_next(0x8ull, 0xb7400071, pc, to) == pc + 4);
        t[0] = 0xf81f0ff0; t[1] = 0xd53bd070; t[2] = 0x927df210; t[3] = 0xf944a210;   /* x16 */
        t[4] = 0x36180070; t[5] = t[7] = 0xf84107f0;
        assert(ppss_x18_tramp(t, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_BRANCH && reg == 16 && op == 0x36180070);
        t[4] = 0x36180090;                                       /* tbz x16, #3, #16: no trampoline's */
        assert(ppss_x18_tramp(t, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_NONE);
        t[4] = 0x36180070; t[7] = 0xd503201f;
        assert(ppss_x18_tramp(t, tramp, pc, &reg, &op, &to) == PPSS_TRAMP_NONE);
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
            for patch in PATCHES:
                subprocess.run(["git", "apply", f"--include={HEADER}", str(patch)], cwd=d, check=True)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            out = subprocess.run([str(d / "t")], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertIn("single step: ok", out.stdout)


if __name__ == "__main__":
    unittest.main()

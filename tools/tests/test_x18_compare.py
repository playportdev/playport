# SPDX-License-Identifier: GPL-3.0-or-later
"""The x18 patcher sends every instruction that reads x18 to a trampoline (SUB, SUBS, CMP, TST, EOR, CBZ ...),
a compare even where a literal load points (madeira-unix 0252, 0260, 0263, PLA-514).

World of Warcraft's ARM64 client guards its code with `cmp x18, #imm; b.lo <loop>`. The role
classifier matched ADD and ADDS only, so with x18 zeroed by iOS the compare saw 0 and the game's
exception handler parked in its loop. The words below are the client's own: its handler's
`cmp x18, #0x38` and an opaque predicate's `cmp x18, xzr, asr #5`. The test runs the patcher, as
the series leaves build/ntdll-unix/virtual_ios.c, over a .text of them and checks each became a
branch to a trampoline that does the same compare on the TEB in x17; that a CBZ's offset bits are
not taken for registers and an access relative to SP is left alone; that an LDP/STP of SIMD and FP
registers (q18, s18) and a load into x18 keep their word while an STP of x18 is patched; that an
instruction naming x16 and x17 gets x15; and that the patcher knows each word it patched from its
original (a re-flush of decrypted code leaves those)."""
import pathlib
import subprocess
import tempfile
import unittest

from test_x18_x64_code import ROOT, UPSTREAM, patched_source


def patcher(source):
    """The role classifier, the scan and ios_jit_patch_x18."""
    start = source.index("#define X18_ROLE_NONE")
    end = source.index("struct preload_info")
    return source[start:source.rindex("#endif", start, end)]


TEST_C = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define ERR(...) ((void)0)
int ios_teb_tls_slot_offset = 0x940;
long ios_limit_x18_images, ios_limit_x18_sites;
#include "patcher.c"

static uint32_t text[13], tramp[1024], text2[4], tramp2[256], text3[5], tramp3[256];

/* The word the patcher put in the trampoline it branched word i to. */
static uint32_t tramp_insn(int i)
{
    uint32_t b = text[i];
    int32_t imm26 = (int32_t)(b << 6) >> 6;
    uint32_t *t = (uint32_t *)((char *)&text[i] + (intptr_t)imm26 * 4);
    assert((b >> 26) == 5 && t >= tramp && t < tramp + 1024);
    assert(t[0] == 0xf81f0ff1 && t[1] == 0xd53bd071);     /* str x17, [sp, #-16]!; mrs x17, tpidrro_el0 */
    return t[4];
}

int main(void)
{
    text[0] = 0xf100e25f;   /* cmp x18, #0x38 (WoW's handler) */
    text[1] = 0xeb9f165f;   /* cmp x18, xzr, asr #5 */
    text[2] = 0xd1002240;   /* sub x0, x18, #8 */
    text[3] = 0x8b120000;   /* add x0, x0, x18: patched before */
    text[4] = 0xd100025f;   /* sub sp, x18, #0: SP in the trampoline, left */
    text[5] = 0xeb3263ff;   /* cmp sp, x18 (extended): SP in the trampoline, left */
    text[6] = 0xd503201f;   /* nop */
    text[7] = 0xd65f03c0;   /* ret */
    text[8] = 0x1800001c;   /* ldr w28, .+0: a junk literal load at the next word */
    text[9] = 0xf1030e5f;   /* cmp x18, #0xc3: patched all the same (0260) */
    text[8] = 0x1800003c;   /* ldr w28, .+4 */
    text[10] = 0xf240065f;  /* tst x18, #0x3 (0263) */
    text[11] = 0xca120129;  /* eor x9, x9, x18 (0263) */
    text[12] = 0xb4000052;  /* cbz x18, .+8 (0263): a branch trampoline */

    assert(ios_jit_x18_tramp_need((char *)text, sizeof(text), 0x1000, NULL, 1) == 7 * 32 + 40 + 0x1000);
    assert(ios_jit_patch_x18((char *)text, (char *)text, sizeof(text), 0x1000,
                             (char *)tramp, (char *)tramp, sizeof(tramp), 1, NULL) == 8);
    assert(tramp_insn(0) == 0xf100e23f);   /* cmp x17, #0x38 */
    assert(tramp_insn(1) == 0xeb9f163f);   /* cmp x17, xzr, asr #5 */
    assert(tramp_insn(2) == 0xd1002220);   /* sub x0, x17, #8 */
    assert(tramp_insn(3) == 0x8b110000);   /* add x0, x0, x17 */
    assert(text[4] == 0xd100025f && text[5] == 0xeb3263ff);
    assert(tramp_insn(9) == 0xf1030e3f);   /* cmp x17, #0xc3 */
    assert(tramp_insn(10) == 0xf240063f);  /* tst x17, #0x3 */
    assert(tramp_insn(11) == 0xca110129);  /* eor x9, x9, x17 */
    {   /* cbz x17, +12; ldr x17, [sp], #16; b back; ldr x17, [sp], #16; b target */
        uint32_t b = text[12];
        int32_t imm26 = (int32_t)(b << 6) >> 6;
        uint32_t *t = (uint32_t *)((char *)&text[12] + (intptr_t)imm26 * 4);
        int32_t back, to;
        assert(t[4] == 0xb4000071 && t[5] == 0xf84107f1 && t[7] == 0xf84107f1);
        back = (int32_t)(t[6] << 6) >> 6; to = (int32_t)(t[8] << 6) >> 6;
        assert((char *)&t[6] + back * 4 == (char *)&text[13]);
        assert((char *)&t[8] + to * 4 == (char *)&text[12] + 8);
    }
    /* The patcher knows each word it patched from its original (a re-flush leaves those) */
    assert(ios_x18_patched_site(text[0], 0xf100e25f, (char *)&text[0], (char *)tramp, sizeof(tramp)));
    assert(!ios_x18_patched_site(text[0], 0xf100e65f, (char *)&text[0], (char *)tramp, sizeof(tramp)));
    assert(ios_x18_patched_site(text[11], 0xca120129, (char *)&text[11], (char *)tramp, sizeof(tramp)));
    assert(!ios_x18_patched_site(text[11], 0xca120129, (char *)&text[11], (char *)tramp2, sizeof(tramp2)));
    assert(!ios_x18_patched_site(text[4], 0xd100025f, (char *)&text[4], (char *)tramp, sizeof(tramp)));

    /* A CBZ's offset bits are no registers: these read as x16 (Rn) and x17 (Rm), and the site
       was left. An STP of x18 or an LDR with x18 as the offset relative to SP is left alone, as
       the trampoline moves SP; MOV xzr, x18 becomes a NOP. */
    {
        size_t used = 0;
        uint32_t *t;
        int32_t to;

        text2[0] = 0xb4110212;   /* cbz x18, .+0x22040 */
        text2[1] = 0xa9014be0;   /* stp x0, x18, [sp, #16] */
        text2[2] = 0xf8726be0;   /* ldr x0, [sp, x18] */
        text2[3] = 0xaa1203ff;   /* mov xzr, x18 */
        assert(ios_jit_x18_tramp_need((char *)text2, sizeof(text2), 0x1000, NULL, 1) == 40 + 32 + 0x1000);
        assert(ios_jit_patch_x18((char *)text2, (char *)text2, sizeof(text2), 0x1000,
                                 (char *)tramp2, (char *)tramp2, sizeof(tramp2), 1, &used) == 1);
        assert(used == 36 && text2[1] == 0xa9014be0 && text2[2] == 0xf8726be0 && text2[3] == 0xd503201f);
        t = (uint32_t *)((char *)&text2[0] + (intptr_t)((int32_t)(text2[0] << 6) >> 6) * 4);
        assert(t == tramp2 && t[0] == 0xf81f0ff1 && t[4] == 0xb4000071);
        to = (int32_t)(t[8] << 6) >> 6;
        assert((char *)&t[8] + to * 4 == (char *)&text2[0] + 0x22040);
        assert(ios_x18_patched_site(text2[0], 0xb4110212, (char *)&text2[0], (char *)tramp2, used));
        assert(!ios_x18_patched_site(text2[0], 0xb4110232, (char *)&text2[0], (char *)tramp2, used));
        assert(!ios_x18_patched_site(text2[0], 0xb5110212, (char *)&text2[0], (char *)tramp2, used));
        assert(!ios_x18_patched_site(text2[0], 0xb4110212, (char *)&text2[0], (char *)tramp2, 16));
        assert(ios_x18_patched_site(text2[3], 0xaa1203ff, (char *)&text2[3], (char *)tramp2, used));
    }
    /* In an LDP/STP of SIMD and FP registers field 18 is q18/s18, and a load into x18 writes it:
       those are left (WoW's `ldp q19, q18, [x8], #0x20` loaded q17). An STP of x18 is patched. An
       instruction naming x16 and x17 gets x15. */
    {
        size_t used = 0;
        uint32_t *t;

        text3[0] = 0xacc14913;   /* ldp q19, q18, [x8], #0x20 */
        text3[1] = 0x2d0a4953;   /* stp s19, s18, [x10, #0x50] */
        text3[2] = 0xa9404820;   /* ldp x0, x18, [x1] */
        text3[3] = 0xa9004820;   /* stp x0, x18, [x1] */
        text3[4] = 0xeb507251;   /* subs x17, x18, x16, lsr #28 */
        assert(ios_jit_x18_tramp_need((char *)text3, sizeof(text3), 0x1000, NULL, 1) == 2 * 32 + 0x1000);
        assert(ios_jit_patch_x18((char *)text3, (char *)text3, sizeof(text3), 0x1000,
                                 (char *)tramp3, (char *)tramp3, sizeof(tramp3), 1, &used) == 2);
        assert(used == 56 && text3[0] == 0xacc14913 && text3[1] == 0x2d0a4953 && text3[2] == 0xa9404820);
        t = (uint32_t *)((char *)&text3[3] + (intptr_t)((int32_t)(text3[3] << 6) >> 6) * 4);
        assert(t[0] == 0xf81f0ff1 && t[4] == 0xa9004420);      /* stp x0, x17, [x1] */
        t = (uint32_t *)((char *)&text3[4] + (intptr_t)((int32_t)(text3[4] << 6) >> 6) * 4);
        assert(t[0] == 0xf81f0fef && t[1] == 0xd53bd06f && t[4] == 0xeb5071f1 && t[5] == 0xf84107ef);
        assert(ios_x18_patched_site(text3[4], 0xeb507251, (char *)&text3[4], (char *)tramp3, used));
        assert(!ios_x18_patched_site(text3[4], 0xeb507231, (char *)&text3[4], (char *)tramp3, used));
    }
    puts("x18 compare: ok");
    return 0;
}
'''


@unittest.skipUnless(UPSTREAM.exists(), "upstream/madeira is not checked out")
class X18PatcherCompare(unittest.TestCase):
    def test_sub_subs_and_cmp_of_x18_are_patched(self):
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "patcher.c").write_text(patcher(patched_source(tmp / "tree")))
            (tmp / "test.c").write_text(TEST_C)
            exe = tmp / "test"
            subprocess.run(["clang", "-std=gnu11", "-O1", "-w", "-o", str(exe), str(tmp / "test.c")], check=True)
            out = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertIn("x18 compare: ok", out.stdout)


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""The x18 patcher sends SUB, SUBS and CMP of x18 to a trampoline, a CMP even where a literal load points
(madeira-unix 0252, 0260, PLA-514).

World of Warcraft's ARM64 client guards its code with `cmp x18, #imm; b.lo <loop>`. The role
classifier matched ADD and ADDS only, so with x18 zeroed by iOS the compare saw 0 and the game's
exception handler parked in its loop. The words below are the client's own: its handler's
`cmp x18, #0x38` and an opaque predicate's `cmp x18, xzr, asr #5`. The test runs the patcher, as
the series leaves build/ntdll-unix/virtual_ios.c, over a .text of them and checks each became a
branch to a trampoline that does the same compare on the TEB in x17."""
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

static uint32_t text[10], tramp[1024];

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

    assert(ios_jit_x18_tramp_need((char *)text, sizeof(text), 0x1000, NULL) == 5 * 32 + 0x1000);
    assert(ios_jit_patch_x18((char *)text, (char *)text, sizeof(text), 0x1000,
                             (char *)tramp, (char *)tramp, sizeof(tramp)) == 5);
    assert(tramp_insn(0) == 0xf100e23f);   /* cmp x17, #0x38 */
    assert(tramp_insn(1) == 0xeb9f163f);   /* cmp x17, xzr, asr #5 */
    assert(tramp_insn(2) == 0xd1002220);   /* sub x0, x17, #8 */
    assert(tramp_insn(3) == 0x8b110000);   /* add x0, x0, x17 */
    assert(text[4] == 0xd100025f && text[5] == 0xeb3263ff);
    assert(tramp_insn(9) == 0xf1030e3f);   /* cmp x17, #0xc3 */
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

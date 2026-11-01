# SPDX-License-Identifier: GPL-3.0-or-later
"""The x18 patcher passes over encrypted .text and patches it once it is decrypted (madeira-unix 0264, PLA-514).

World of Warcraft's ARM64 client ships most of its .text encrypted and decrypts it at run time from
the bytes at its image. Encrypted words read as x18 instructions at random (196,547 of them in the
Classic Era client), and a patched one decrypted to garbage. A 1 KB window of .text in which more
than 8 of its 256 words fall in the unallocated encoding groups (op0 0b0001, 0b0011), which no
compiler emits, is now data to the patcher. The trampoline reservation still counts the window's
matches, and code decrypted there later is patched from what is left of it (cipher 2: only the
words its first word reaches, so neither junk after its branches nor the still encrypted rest is
touched). The test runs the patcher, as the series leaves build/ntdll-unix/virtual_ios.c, over a
code window, an encrypted one and the same window partly decrypted."""
import pathlib
import subprocess
import tempfile
import unittest

from test_x18_compare import patcher
from test_x18_x64_code import ROOT, UPSTREAM, patched_source

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

#define WORDS 256   /* one 1 KB window */
static uint32_t text[3 * WORDS], tramp[1024], saved[WORDS];

int main(void)
{
    uint32_t seed = 0x2545f491;
    size_t used = 0, more = 0;
    int i;

    for (i = 0; i < 3 * WORDS; i++) text[i] = 0xd503201f;   /* nop */
    text[5] = 0xf100e25f;                                   /* cmp x18, #0x38: code */
    for (i = WORDS; i < 2 * WORDS; i++)                     /* encrypted: op0 0b0001 or 0b0011 */
    {
        seed = seed * 1664525 + 1013904223;
        text[i] = (seed & ~0x1e000000u) | ((seed & 1) ? 0x06000000u : 0x02000000u);
    }
    text[WORDS + 40] = 0xd1002240;                          /* sub x0, x18, #8 by chance */
    memcpy(saved, text + WORDS, sizeof(saved));

    /* The reservation counts both sites; the patch's budget only the code's. */
    assert(ios_jit_x18_tramp_need((char *)text, sizeof(text), 0x1000, NULL, 0) == 2 * 32 + 0x1000);
    assert(ios_jit_x18_tramp_need((char *)text, sizeof(text), 0x1000, NULL, 1) == 32 + 0x1000);
    assert(ios_jit_patch_x18((char *)text, (char *)text, sizeof(text), 0x1000,
                             (char *)tramp, (char *)tramp, sizeof(tramp), 1, &used) == 1);
    assert((text[5] >> 26) == 5 && used == 28);
    assert(!memcmp(saved, text + WORDS, sizeof(saved)));    /* the encrypted window is untouched */

    /* Decrypted: a function at the window's start, the rest still encrypted, with junk words
       after its branch and its RET. A re-patch of the flushed window patches what the function's
       first word reaches, from the rest of the reservation. */
    text[WORDS + 0] = 0xd503201f;                           /* nop */
    text[WORDS + 1] = 0x14000003;                           /* b .+12 */
    text[WORDS + 2] = 0xd1002240;                           /* junk: sub x0, x18, #8 */
    text[WORDS + 3] = 0xd1002240;
    text[WORDS + 4] = 0xaa1203e8;                           /* mov x8, x18 */
    text[WORDS + 5] = 0xd65f03c0;                           /* ret */
    text[WORDS + 6] = 0xd1002240;                           /* junk */
    assert(ios_jit_patch_x18((char *)(text + WORDS), (char *)(text + WORDS), WORDS * 4, 0x1400,
                             (char *)tramp + used, (char *)tramp + used, sizeof(tramp) - used, 2, &more) == 1);
    assert((text[WORDS + 4] >> 26) == 5 && more == 16);
    assert(text[WORDS + 2] == 0xd1002240 && text[WORDS + 3] == 0xd1002240 && text[WORDS + 6] == 0xd1002240);
    assert(!memcmp(saved + 7, text + WORDS + 7, sizeof(saved) - 7 * 4));   /* still encrypted, untouched */
    {   /* its trampoline: mrs x8, tpidrro_el0; and; ldr; b back */
        int32_t imm26 = (int32_t)(text[WORDS + 4] << 6) >> 6;
        uint32_t *t = (uint32_t *)((char *)&text[WORDS + 4] + (intptr_t)imm26 * 4);
        assert(t == (uint32_t *)((char *)tramp + used) && t[0] == 0xd53bd068);
    }
    puts("x18 encrypted: ok");
    return 0;
}
'''


@unittest.skipUnless(UPSTREAM.exists(), "upstream/madeira is not checked out")
class X18PatcherEncrypted(unittest.TestCase):
    def test_encrypted_windows_are_left_and_patched_once_decrypted(self):
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
            self.assertIn("x18 encrypted: ok", out.stdout)


if __name__ == "__main__":
    unittest.main()

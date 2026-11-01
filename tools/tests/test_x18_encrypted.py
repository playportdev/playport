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
code window, an encrypted one and the same window partly decrypted, and over flushed functions that
end in a UDF or a pointer-authenticated return or branch. Only a native ARM64 child loads its images
with the encrypted-window skip (0176: x86-64 and ARM64EC processes are unchanged), and a record of a
section view is never dropped for a new one. 0265: the client decrypts its whole .text in place and
flushes the image at once, so a flush also takes as code what the function starts of the image's
.pdata reach (with BL calls), inside the windows rewritten since the remap. 0270: and every word of
those functions (their length from the unwind data) but the jump tables and literals among them,
so a switch case reached only through a table and a BR is patched while the table is not; a word
that code falls through to is code even where an LDR (literal) loads it."""
import pathlib
import re
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
static uint32_t text[3 * WORDS], tramp[1024], saved[WORDS], fn[4], fn_tramp[64];

/* Patch a flushed function of four words, the last of them junk that reads as an x18 instruction. */
static int flush_patch(uint32_t a, uint32_t b, uint32_t c)
{
    size_t n = 0;
    fn[0] = a; fn[1] = b; fn[2] = c; fn[3] = 0xd1002240;   /* junk: sub x0, x18, #8 */
    return ios_jit_patch_x18((char *)fn, (char *)fn, sizeof(fn), 0x2000,
                             (char *)fn_tramp, (char *)fn_tramp, sizeof(fn_tramp), 2, &n);
}

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
    /* A flushed function ends at a UDF (which WoW executes on purpose), a RETAA/RETAB or a
       BRAA/BRAB/BRAAZ/BRABZ: the words after one are not reached, and stay as they are. */
    assert(flush_patch(0xaa1203e8, 0x00009720, 0xd1002240) == 1 && fn[2] == 0xd1002240 && fn[3] == 0xd1002240);
    assert(flush_patch(0xd503201f, 0xd65f0bff, 0xd1002240) == 0);   /* retaa */
    assert(flush_patch(0xd503201f, 0xd65f0fff, 0xd1002240) == 0);   /* retab */
    assert(flush_patch(0xd503201f, 0xd71f0a11, 0xd1002240) == 0);   /* braa x16, x17 */
    assert(flush_patch(0xd503201f, 0xd71f0e11, 0xd1002240) == 0);   /* brab x16, x17 */
    assert(flush_patch(0xd503201f, 0xd61f0a1f, 0xd1002240) == 0);   /* braaz x16 */
    assert(flush_patch(0xd503201f, 0xd61f0e1f, 0xd1002240) == 0);   /* brabz x16 */
    assert(flush_patch(0xd503201f, 0xd503201f, 0xd1002240) == 2);   /* control: falls through */

    /* A whole image decrypted in place, then flushed at once (0265): its first word is still
       encrypted, so only the code hint's function starts, and what they and their BL calls
       reach, are code, inside the windows rewritten since the remap. A function start in a
       window not rewritten (still encrypted), and junk after a RET, stay as they are. */
    {
        static uint32_t image[3 * WORDS], image_tramp[256];
        static const uint32_t pdata[] = { 0x1000 + 10 * 4, 0, 0x1000 + (WORDS + 3) * 4, 0 };
        static const unsigned char rewritten[] = { 0x05 };   /* windows 0 and 2 */
        struct ios_x18_code_hint hint = { NULL, 0, 0, 0, pdata, 2, rewritten, 0x1000, 3 };
        size_t hint_used = 0;

        for (i = 0; i < 3 * WORDS; i++) image[i] = 0xd503201f;
        image[0] = 0x06000000;                              /* encrypted: unallocated */
        image[10] = 0xd503201f;                             /* F: nop */
        image[11] = 0x94000009;                             /*    bl G */
        image[12] = 0xf100e25f;                             /*    cmp x18, #0x38 */
        image[13] = 0xd65f03c0;                             /*    ret */
        image[14] = 0xd1002240;                             /* junk: sub x0, x18, #8 */
        image[20] = 0xaa1203e8;                             /* G (not in .pdata): mov x8, x18 */
        image[21] = 0xd65f03c0;                             /*    ret */
        image[WORDS + 3] = 0xd1002240;                      /* a function still encrypted */
        assert(ios_jit_patch_x18((char *)image, (char *)image, sizeof(image), 0x1000, (char *)image_tramp,
                                 (char *)image_tramp, sizeof(image_tramp), 2, &hint_used) == 0);   /* no hint */
        ios_x18_code_hint = &hint;
        assert(ios_jit_patch_x18((char *)image, (char *)image, sizeof(image), 0x1000, (char *)image_tramp,
                                 (char *)image_tramp, sizeof(image_tramp), 2, &hint_used) == 2);
        ios_x18_code_hint = NULL;
        assert((image[12] >> 26) == 5 && (image[20] >> 26) == 5);
        assert(image[0] == 0x06000000 && image[14] == 0xd1002240 && image[WORDS + 3] == 0xd1002240);
    }
    /* Every word of a .pdata function is code but its inline data: a switch case reached only
       through a jump table and a BR is patched; the table's words, a literal after it, and a
       function's words past an unallocated word stay as they are. A word an LDR (literal)
       loads that code falls through to is code. */
    {
        static uint32_t image[0xc00], image_tramp[256];
        uint32_t *f = image + 0x440, *h = image + 0x480;   /* F at RVA 0x1100, H at 0x1200 */
        static const uint32_t pdata[] = { 0x1100, 1 | 20 << 2, 0x1200, 1 | 5 << 2 };   /* packed: length */
        static const unsigned char rewritten[] = { 0x0f };
        struct ios_x18_code_hint hint = { (char *)image, sizeof(image), 0x1000, 0x1000, pdata, 2, rewritten, 0x1000, 4 };
        size_t hint_used = 0;

        for (i = 0x400; i < 0x800; i++) image[i] = 0xd503201f;
        image[0x400] = 0x06000000;                          /* .text's first word: encrypted */
        f[0] = 0x7100081f;                                  /* cmp w0, #2 */
        f[1] = 0x54000128;                                  /* b.hi f+10 */
        f[2] = 0x10000149;                                  /* adr x9, f+12 (table) */
        f[3] = 0xb8a05928;                                  /* ldrsw x8, [x9, w0, uxtw #2] */
        f[4] = 0x10000009;                                  /* adr x9, f+4 (base) */
        f[5] = 0x8b080928;                                  /* add x8, x9, x8, lsl #2 */
        f[6] = 0xd61f0100;                                  /* br x8 */
        f[7] = 0xaa1203e8;                                  /* case 0: mov x8, x18 */
        f[8] = 0xf100225f;                                  /*         cmp x18, #8 */
        f[9] = 0xd65f03c0;                                  /*         ret */
        f[10] = 0xd65f03c0;                                 /* ret */
        f[11] = 0xd503201f;                                 /* nop (alignment) */
        f[12] = 3;                                          /* table: case 0 */
        f[13] = 0xf100225f;                                 /*   reads as cmp x18, #8 */
        f[14] = 0xd1002240;                                 /*   reads as sub x0, x18, #8 */
        f[15] = 0xaa1203e8;                                 /* a literal after it: mov x8, x18 */
        f[16] = 0x91000400;                                 /* add x0, x0, #1 */
        f[17] = 0xaa1203e8;                                 /* mov x8, x18, which f+18 loads too */
        f[18] = 0x58ffffe1;                                 /* ldr x1, f+17 */
        f[19] = 0x18ffff81;                                 /* ldr w1, f+15 */
        h[0] = 0xaa1203e8;                                  /* H: mov x8, x18 */
        h[1] = 0xd65f03c0;                                  /*    ret */
        h[2] = 0x06000000;                                  /*    unallocated */
        h[3] = 0xf100225f;                                  /*    cmp x18, #8 */
        h[4] = 0xd65f03c0;                                  /*    ret */
        ios_x18_code_hint = &hint;
        assert(ios_jit_patch_x18((char *)(image + 0x400), (char *)(image + 0x400), 0x1000, 0x1000,
                                 (char *)image_tramp, (char *)image_tramp, sizeof(image_tramp), 2, &hint_used) == 4);
        ios_x18_code_hint = NULL;
        assert((f[7] >> 26) == 5 && (f[8] >> 26) == 5 && (f[17] >> 26) == 5 && (h[0] >> 26) == 5);
        assert(f[12] == 3 && f[13] == 0xf100225f && f[14] == 0xd1002240 && f[15] == 0xaa1203e8);
        assert(h[3] == 0xf100225f && image[0x400] == 0x06000000);
    }
    puts("x18 encrypted: ok");
    return 0;
}
'''

SECTION_VIEWS_C = r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
typedef unsigned long long ULONGLONG;
#include "views.c"

int main(void)
{
    struct ios_section_view *first, *v;
    unsigned int i;

    /* 200 live views of plain sections (NLS and font files, game files ...): none drops another */
    for (i = 0; i < 200; i++)
    {
        assert((v = ios_section_view_slot()) && !v->peb);
        v->peb = (void *)(uintptr_t)(0x1000 + i);
        v->base = (char *)(uintptr_t)(0x10000 * (i + 1));
        if (i == 3) v->copy = (char *)0x7000;   /* the remap's record */
    }
    for (i = 0; i < 200; i++)
    {
        int found = 0;
        unsigned int k;
        for (k = 0; k < ios_section_view_count; k++)
            found += ios_section_views[k].peb == (void *)(uintptr_t)(0x1000 + i) &&
                     ios_section_views[k].base == (char *)(uintptr_t)(0x10000 * (i + 1));
        assert(found == 1);
    }
    /* an unmapped view's slot is taken again */
    first = &ios_section_views[5];
    first->peb = NULL;
    assert(ios_section_view_slot() == first);
    puts("section views: ok");
    return 0;
}
'''

# The cipher argument of each call: 0, 2 (a flush), the parameter passed on, or one that is 1 only
# in a native ARM64 child.
CIPHER_ARG = {"ios_jit_x18_tramp_need": 4, "ios_jit_patch_x18": 7, "ios_jit_repatch_x18": 3}


def cipher_calls(source):
    """(function, offset, cipher argument) of each call of the patcher's entry points."""
    for name, index in CIPHER_ARG.items():
        for match in re.finditer(r"\b%s\s*\(" % name, source):
            depth, args, cur = 0, [], ""
            for ch in source[match.end():]:
                if ch == ")" and depth == 0:
                    break
                depth += (ch == "(") - (ch == ")")
                if ch == "," and depth == 0:
                    args.append(cur)
                    cur = ""
                else:
                    cur += ch
            args.append(cur)
            if len(args) <= index:
                continue   # a comment's mention
            arg = " ".join(args[index].split())
            if arg == "int cipher":
                continue   # its declaration
            yield name, match.start(), arg




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

    def test_only_a_native_arm64_child_skips_encrypted_windows(self):
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as tmp:
            source = patched_source(pathlib.Path(tmp) / "tree")
        start = source.index("static BOOL ios_remap_presented(")
        end = source.index("\n}\n", start)
        self.assertIn("!ios_is_native_arm64_cur()", source[start:end])
        calls = list(cipher_calls(source))
        self.assertGreaterEqual(len(calls), 8)
        bad = [f"{name} at line {source.count(chr(10), 0, at) + 1}: cipher {arg}"
               for name, at, arg in calls
               if arg not in ("0", "2", "cipher") and "ios_is_native_arm64_cur()" not in arg
               and not (arg == "1" and start <= at < end)]
        self.assertEqual(bad, [])

    def test_section_view_records_are_never_dropped(self):
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as tmp:
            tmp = pathlib.Path(tmp)
            source = patched_source(tmp / "tree")
            start = source.index("struct ios_section_view\n{")
            (tmp / "views.c").write_text(source[start:source.index("/* Make the part of view s", start)])
            (tmp / "test.c").write_text(SECTION_VIEWS_C)
            exe = tmp / "views"
            subprocess.run(["clang", "-std=gnu11", "-O1", "-w", "-o", str(exe), str(tmp / "test.c")], check=True)
            out = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertIn("section views: ok", out.stdout)


if __name__ == "__main__":
    unittest.main()

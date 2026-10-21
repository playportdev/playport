# SPDX-License-Identifier: GPL-3.0-or-later
"""The x18 patcher leaves an ARM64EC image's x64 code alone (madeira-unix 0204, PLA-364).

ntdll's .text ends in x64 code (relay entry points, the x64 KiUserExceptionDispatcher). Read as
ARM64, a relay entry point's `lea rcx, [rip+disp]` word decoded as an LDR (literal) whose target,
with the InitOnceExecuteOnce stub in loader.c, was RtlProcessFlsData's `mov x8, x18`: the literal
guard left it unpatched and a RockstarLauncher thread with x18 = 0 faulted there. The image below
puts that build's words at that build's offsets (ntdll .text at RVA 0x4000, 0x8ad65 bytes, ARM64EC
code to 0x7ee50, x64 code from 0x7f000) and runs the patcher's scan functions, as the series leaves
build/ntdll-unix/virtual_ios.c, against it."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERIES = ROOT / "patches/madeira-unix"
UPSTREAM = ROOT / "upstream/madeira/build/ntdll-unix/virtual_ios.c"
SOURCE = "build/ntdll-unix/virtual_ios.c"


def patched_source(directory):
    """virtual_ios.c after every madeira-unix patch, in series order."""
    target = directory / SOURCE
    target.parent.mkdir(parents=True)
    shutil.copy(UPSTREAM, target)
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
    names = [n.strip() for n in (SERIES / "series").read_text().splitlines() if n.strip() and not n.startswith("#")]
    for name in names:
        subprocess.run(["git", "apply", f"--include={SOURCE}", str(SERIES / name)], cwd=directory, check=True)
    return target.read_text(encoding="utf-8", errors="replace")


def scan_functions(source):
    """From the x18 role classifier to the patcher itself: the scan the budget and the patcher share."""
    start = source.index("#define X18_ROLE_NONE")
    end = source.index("int ios_jit_patch_x18(")
    return source[start:end]


TEST_C = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "scan.c"

#define IMAGE_BASE  0x180000000ULL
#define SIZE        0xf5000u
#define TEXT_RVA    0x4000u
#define TEXT_SIZE   0x8ad65u
#define LOAD_CONFIG 0x94000u
#define METADATA    0x95000u
#define CODE_MAP    0x95100u
#define MOV_X8_X18  0x628bcu      /* RtlProcessFlsData's TEB read */
#define LEA_WORD    0x8670cu      /* a relay entry point's lea rcx, [rip+0x...] */
#define X64_X18_1   0x87488u      /* x64 words that decode as x18 instructions */
#define X64_X18_2   0x8ed4cu      /* inside the x64 KiUserExceptionDispatcher */
#define LDR_LIT     0x10000u      /* an ARM64EC ldr x16, <literal> 16 bytes on */
#define LITERAL     0x10010u      /* its literal, whose low word decodes as LDP with rt2 = x18 */

static unsigned char *image;

static void put32(uint32_t rva, uint32_t v) { memcpy(image + rva, &v, 4); }
static void put64(uint32_t rva, uint64_t v) { memcpy(image + rva, &v, 8); }

static void build(uint64_t header_base, uint64_t metadata_pointer)
{
    memset(image, 0, SIZE);
    image[0] = 'M'; image[1] = 'Z';
    put32(0x3c, 0x80);
    memcpy(image + 0x80, "PE\0\0", 4);
    put32(0x80 + 0x14, 0xf0);                        /* SizeOfOptionalHeader */
    put32(0x98, 0x20b);                              /* PE32+ */
    put64(0x98 + 0x18, header_base);
    put32(0x98 + 0x38, SIZE);
    put32(0x98 + 0x70 + 10 * 8, LOAD_CONFIG);
    put32(0x98 + 0x70 + 10 * 8 + 4, 0x140);
    put64(LOAD_CONFIG + 0xc8, metadata_pointer);
    put32(METADATA + 4, CODE_MAP);
    put32(METADATA + 8, 2);
    put32(CODE_MAP, TEXT_RVA | 1);  put32(CODE_MAP + 4, 0x7ae50);   /* ARM64EC */
    put32(CODE_MAP + 8, 0x7f000 | 2); put32(CODE_MAP + 12, 0x14540);  /* AMD64 */
    put32(MOV_X8_X18, 0xaa1203e8);
    put32(LEA_WORD, 0x18ee0d8d);
    put32(X64_X18_1, 0x0b720d8d);
    put32(X64_X18_2, 0xec834817);
    put32(LDR_LIT, 0x58000010 | (4 << 5));           /* ldr x16, #16 */
    put32(LITERAL, 0xa9004a40);                      /* stp x0, x18, [x18]: a literal, not code */
}

static int marked(const unsigned char *map, uint32_t rva)
{
    uint32_t i = rva - TEXT_RVA;
    return (map[(i / 4) >> 3] >> ((i / 4) & 7)) & 1;
}

int main(void)
{
    char *text;
    unsigned char *map;
    int x64;

    image = calloc(1, SIZE);
    text = (char *)image + TEXT_RVA;
    assert(ios_insn_x18_role(0x18ee0d8d) == X18_ROLE_NONE);
    assert(ios_insn_x18_role(0xaa1203e8) != X18_ROLE_NONE);
    assert(ios_insn_x18_role(0x0b720d8d) != X18_ROLE_NONE && ios_insn_x18_role(0xec834817) != X18_ROLE_NONE);
    assert(ios_insn_x18_role(0xa9004a40) != X18_ROLE_NONE);

    /* The source mapping: the metadata pointer relocated with the header's ImageBase. */
    build(IMAGE_BASE, IMAGE_BASE + METADATA);
    map = ios_x18_build_data_map(text, TEXT_SIZE, TEXT_RVA, NULL, &x64);
    assert(x64 == 2);
    assert(!marked(map, MOV_X8_X18));                 /* patched: the x64 lea is no LDR */
    assert(marked(map, X64_X18_1) && marked(map, X64_X18_2) && marked(map, LEA_WORD));
    assert(!marked(map, LDR_LIT) && marked(map, LITERAL));   /* the ARM64EC literal is still data */
    free(map);
    /* One site in the code (the mov), 32 bytes, plus a page of slack. */
    assert(ios_jit_x18_tramp_need(text, TEXT_SIZE, TEXT_RVA, NULL) == 32 + 0x1000);

    /* A child copy: the pointer rebased to the copy, the header's ImageBase not. */
    build(IMAGE_BASE, 0x10bf4c000ULL + METADATA);
    map = ios_x18_build_data_map(text, TEXT_SIZE, TEXT_RVA, (const char *)0x10bf4c000ULL, &x64);
    assert(x64 == 2 && !marked(map, MOV_X8_X18) && marked(map, X64_X18_2));
    free(map);
    assert(ios_jit_x18_tramp_need(text, TEXT_SIZE, TEXT_RVA, (const char *)0x10bf4c000ULL) == 32 + 0x1000);

    /* No code map to read: scanned as before 0204, and the x64 word hides the mov. */
    build(IMAGE_BASE, 0);
    map = ios_x18_build_data_map(text, TEXT_SIZE, TEXT_RVA, NULL, &x64);
    assert(x64 == -1 && marked(map, MOV_X8_X18) && !marked(map, X64_X18_2));
    free(map);

    puts("x18 x64 code: ok");
    return 0;
}
'''


@unittest.skipUnless(UPSTREAM.exists(), "upstream/madeira is not checked out")
class X18PatcherX64Code(unittest.TestCase):
    def test_x64_code_is_no_ldr_source_and_no_patch_site(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "scan.c").write_text(scan_functions(patched_source(tmp / "tree")))
            (tmp / "test.c").write_text(TEST_C)
            exe = tmp / "test"
            subprocess.run(["clang", "-std=c11", "-O1", "-w", "-o", str(exe), str(tmp / "test.c")], check=True)
            out = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
            self.assertIn("x18 x64 code: ok", out.stdout)


if __name__ == "__main__":
    unittest.main()

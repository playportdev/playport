# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0283's pp_split_stub.h (PLA-516): the read stubs the Mach handler patches over a
hot JIT site of the reads it completes for noaccess-split pages and KUSER_SHARED_DATA. Decodes the loads it takes,
checks the branch reach, and disassembles a stub (llvm-mc) to the instruction sequence the header documents."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0283-signal-virtual-read-stubs-for-the-hot-JIT-sites-of-t.patch"
HEADER = "build/ntdll-unix/pp_split_stub.h"

TEST_C = r'''
#include "pp_split_stub.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    struct ppss_load l;
    uint32_t out[PPSS_STUB_WORDS];
    unsigned n, slow, i;

    /* Run 20261101T200342's hot reads: LDAPUR w1, [x6]; LDAPUR x0, [x6]; LDAPURB w8, [x6, #255]. */
    assert(ppss_decode(0x994000c1u, &l) && l.rt == 1 && l.rn == 6 && l.size_lg2 == 2 && l.imm == 0 && l.tso);
    assert(ppss_decode(0xd94000c0u, &l) && l.rt == 0 && l.size_lg2 == 3 && l.tso);
    assert(ppss_decode(0x194ff0c8u, &l) && l.rt == 8 && l.size_lg2 == 0 && l.imm == 255);
    assert(ppss_decode(0x195ff0c8u, &l) && l.imm == -1);                        /* LDAPURB w8, [x6, #-1] */
    /* LDRB w10, [x8, #3]; LDR w0, [x8]; LDURB w0, [x8]: plain loads. */
    assert(ppss_decode(0x39400d0au, &l) && l.rt == 10 && l.rn == 8 && l.imm == 3 && !l.tso);
    assert(ppss_decode(0xb9400500u, &l) && l.imm == 4 && l.size_lg2 == 2);       /* LDR w0, [x8, #4] */
    assert(ppss_decode(0x38400100u, &l) && !l.tso);
    /* Not taken: LDRB post-index, LDAPURSW (sign-extending), stores, LDR q0, a base of sp or x18, NOP. */
    assert(!ppss_decode(0x3840150bu, &l) && !ppss_decode(0x998000c1u, &l) && !ppss_decode(0xb9000100u, &l));
    assert(!ppss_decode(0x3dc00000u, &l) && !ppss_decode(0xb94003e0u, &l) && !ppss_decode(0xb9400240u, &l));
    assert(!ppss_decode(0xd503201fu, &l));

    assert(ppss_branch(0x133f9452cull, 0x133000000ull) == (0x14000000u | (uint32_t)((-(int64_t)0xf9452c >> 2) & 0x3ffffff)));
    assert(!ppss_branch(0x140000000ull, 0x140000000ull + PPSS_REACH + 4));
    assert(!ppss_branch(0x140000002ull, 0x140000000ull));

    ppss_decode(0x994000c1u, &l);
    n = ppss_emit(out, 0x133000000ull, 0x133f9452cull, 0x994000c1u, &l, 0x140860000ull, 0x7354000ull,
                  0x7000001234ull, 0x147bb4000ull, &slow);
    assert(n && n <= PPSS_STUB_WORDS && slow == 100 && out[slow / 4] == 0x994000c1u);
    assert(out[n - 6] == 0x7354000u && out[n - 5] == 0);   /* the window size literal, which a retire zeroes */
    for (i = 0; i < n - 10; i++) printf("0x%02x 0x%02x 0x%02x 0x%02x\n", out[i] & 255, (out[i] >> 8) & 255,
                                         (out[i] >> 16) & 255, out[i] >> 24);
    /* Out of reach of the site: no stub. */
    assert(!ppss_emit(out, 0x100000000ull, 0x133f9452cull, 0x994000c1u, &l, 0x140860000ull, 0x7354000ull, 0, 0, &slow));
    /* KUSER_SHARED_DATA, an LDAPUR x0 at x6 = x0's base register: scratch avoids both, no vprot test. */
    ppss_decode(0xd94000c0u, &l);
    assert(ppss_emit(out, 0x133000000ull, 0x133000400ull, 0xd94000c0u, &l, 0x7ffe0000ull, 0x1000, 0,
                     0x7038000000ull, &slow) == 32);
    return 0;
}
'''

EXPECTED = """stp x9, x10, [sp, #-16]!
ldr x10, #108
add x9, x6, x10
ldr x10, #108
sub x9, x9, x10
lsr x10, x9, #40
cbnz x10, #72
ldr x10, #100
sub x10, x9, x10
tbz x10, #63, #60
and x10, x9, #0x3
cbnz x10, #52
ldr x10, #88
add x10, x10, x9, lsr #12
ldrb w10, [x10]
tbz w10, #5, #36
tbnz w10, #4, #32
and x10, x10, #0xf
cbz x10, #24
ldr x10, #68
add x9, x9, x10
ldapr w1, [x9]
ldp x9, x10, [sp], #16
b #16336084
ldp x9, x10, [sp], #16
ldapur w1, [x6]
nop
b #16336068""".splitlines()


class SplitStubTests(unittest.TestCase):
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
            words = subprocess.run([str(d / "t")], check=True, capture_output=True, text=True).stdout
            mc = shutil.which("llvm-mc")
            if not mc:
                self.skipTest("no llvm-mc to disassemble the stub")
            dis = subprocess.run([mc, "--disassemble", "-triple=aarch64", "-mattr=+rcpc,+rcpc-immo"], input=words,
                                 check=True, capture_output=True, text=True).stdout
            got = [" ".join(line.split()) for line in dis.splitlines() if line.startswith("\t")]
            got = [g.replace(", ", ",").replace(",", ", ") for g in got]
            self.assertEqual(got, EXPECTED)

    def test_the_handler_uses_it(self):
        """Both services count their completed reads per JIT site; a fault at a stub's original load the services do
        not complete goes on as the site's; a dropped view retires its stubs and keeps its alias."""
        patch = PATCH.read_text()
        self.assertIn("+    if (from_view) ios_split_stub_hot(", patch)
        self.assertIn("+        ios_split_stub_hot( (uint64_t)(uintptr_t)PC_sig(ctx), insn, addr, PPSS_KUSD, 0x1000,", patch)
        self.assertIn("+                uint64_t ss_site = ios_split_stub_site(", patch)
        self.assertIn("+        ios_split_stub_retire( (uintptr_t)view->base );", patch)


if __name__ == "__main__":
    unittest.main()

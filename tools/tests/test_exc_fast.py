# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0282's pp_exc_fast.h (PLA-516): the Mach handler reads the
faulting instruction of a JIT pool pc with a plain load, and defers the SIMD/FP state fetch for a general-register load or
store, on the sub-floor and noaccess-split reads it emulates (~17 M before World of Warcraft's first window)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0282-signal-the-Mach-handler-s-emulated-reads-skip-a-regi.patch"
HEADER = "build/ntdll-unix/pp_exc_fast.h"

TEST_C = r'''
#include "pp_exc_fast.h"
#include <assert.h>

int main(void) {
    /* The pool of run 20261101T200342: 0x109d00000 + 896 MiB. */
    const unsigned long long rx = 0x109d00000ull, size = 896ull << 20;
    assert(ppef_pool_word(rx, rx, size));
    assert(ppef_pool_word(0x13bd0072cull, rx, size));          /* the hot read's JIT pc */
    assert(ppef_pool_word(rx + size - 4, rx, size));
    assert(!ppef_pool_word(rx + size - 2, rx, size));          /* unaligned, and past the end */
    assert(!ppef_pool_word(rx + size, rx, size));
    assert(!ppef_pool_word(rx - 4, rx, size));
    assert(!ppef_pool_word(rx + 2, rx, size));
    assert(!ppef_pool_word(0x1a7d2b640ull, rx, size));          /* libsystem, outside the pool */
    assert(!ppef_pool_word(rx, 0, size) && !ppef_pool_word(rx, rx, 0) && !ppef_pool_word(rx, rx, 2));

    /* The emulated reads of that run: LDAPUR w1/w8 (4 bytes), LDAPURB, LDR x0, LDAPUR x0. */
    assert(ppef_gpr_ldst(0x994000c1u) && ppef_gpr_ldst(0x994000c8u) && ppef_gpr_ldst(0x3840150bu));
    assert(ppef_gpr_ldst(0xd94000c0u) && ppef_gpr_ldst(0xb9400100u));
    assert(ppef_gpr_ldst(0xf9000000u) && ppef_gpr_ldst(0xa9400000u));   /* STR x0; LDP x0, x0 */
    assert(ppef_gpr_ldst(0xc85f7c00u));                                 /* LDXR x0 (exclusives class) */
    /* SIMD/FP loads and stores: memcpy's LDP q0, q1; LDR q0; LDUR s0; STR d0. */
    assert(!ppef_gpr_ldst(0xad400420u) && !ppef_gpr_ldst(0x3dc00000u));
    assert(!ppef_gpr_ldst(0xbc400000u) && !ppef_gpr_ldst(0xfd000000u));
    /* Not loads or stores: ADD, AND (shifted register), B, BRK, NOP. */
    assert(!ppef_gpr_ldst(0x8b000000u) && !ppef_gpr_ldst(0x0a000000u) && !ppef_gpr_ldst(0x14000000u));
    assert(!ppef_gpr_ldst(0xd4200000u) && !ppef_gpr_ldst(0xd503201fu));
    return 0;
}
'''


class ExcFastTests(unittest.TestCase):
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
            subprocess.run([str(d / "t")], check=True)

    def test_the_handler_uses_it(self):
        """The services read the instruction through the pool shortcut; the SIMD/FP fetch waits for a GPR access and is
        made before every later stage when neither service completed it; the region snapshot skips a completed one."""
        patch = PATCH.read_text()
        self.assertEqual(patch.count("+    if (!ios_exc_read_insn( (uint64_t)(uintptr_t)PC_sig(ctx), &insn ))"), 2)
        self.assertIn("+                ppef_gpr_ldst( pre_insn ))", patch)
        self.assertIn("+            if (!handled && neon_deferred)", patch)
        self.assertIn("+                if (fault_addr && !handled &&", patch)
        self.assertIn("+                        if (have_neon && memcmp( &neon_state, &sf_mc.__ns, sizeof(neon_state) ))",
                      patch)


if __name__ == "__main__":
    unittest.main()

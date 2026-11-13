# SPDX-License-Identifier: GPL-3.0-or-later
"""LD1-LD4/ST1-ST4 (multiple structures) in the sub-floor service (patches/madeira-unix 0300, PLA-872).

The decoder, the register mover, the classifier's span and the post-index writeback are
taken from the patch and run against a reference of the architecture's element order."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCH = REPO / "patches/madeira-unix/0300-signal-emulate-LD1-LD4-and-ST1-ST4-multiple-structur.patch"


def function(added, signature):
    return signature + added.split(signature, 1)[1].split("\n}\n", 1)[0] + "\n}\n"


class SubfloorSimdMulti(unittest.TestCase):
    def test_emulation(self):
        added = "\n".join(line[1:] for line in PATCH.read_text().splitlines()
                          if line.startswith("+") and not line.startswith("+++"))
        code = (function(added, "static unsigned ios_simd_multi(") +
                function(added, "static void ios_simd_multi_move("))
        # The users: the mover, the load and release-store emulators, the classifier, the writeback.
        self.assertEqual(added.count("ios_simd_multi( insn, &nregs, &selem )"), 5)
        self.assertEqual(added.count("ios_simd_multi_move( (unsigned char *)ctx->uc_mcontext->__ns.__v, insn,"), 2)
        writeback = added.split("LDn/STn (multiple structures), post-index", 1)[1]
        self.assertIn("orig_addr + (rm == 31 ? bytes : REGn_sig(rm, ctx))", writeback)
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="subfloor-simd-multi-", dir=work) as tmp:
            root = Path(tmp)
            source = root / "test.c"
            source.write_text("#include <assert.h>\n#include <stdint.h>\n#include <string.h>\n" + code + r'''
static unsigned char vregs[32][16], want[32][16], mem[64], out[64];

static void fill(void)
{
    int i, j;
    for (i = 0; i < 64; i++) mem[i] = (unsigned char)(0x40 + i);
    for (i = 0; i < 32; i++) for (j = 0; j < 16; j++) vregs[i][j] = (unsigned char)(i * 16 + j);
    memcpy(want, vregs, sizeof(want));
}

/* The architecture's order (LD1-LD4/ST1-ST4 multiple structures, Arm ARM C7.2). */
static void reference(int t, int nregs, int selem, int q, int esize, int load)
{
    int rpt = nregs / selem, elems = (q ? 16 : 8) / esize, r, e, s, offs = 0;
    if (load && !q) for (r = 0; r < nregs; r++) memset(want[(t + r) & 31] + 8, 0, 8);
    for (r = 0; r < rpt; r++)
        for (e = 0; e < elems; e++)
            for (s = 0; s < selem; s++, offs += esize)
            {
                if (load) memcpy(want[(t + r + s) & 31] + e * esize, mem + offs, esize);
                else memcpy(out + offs, want[(t + r + s) & 31] + e * esize, esize);
            }
}

static uint32_t enc(int q, int load, int post, int rm, int opcode, int size, int rn, int rt)
{
    return (uint32_t)q << 30 | 0x0C000000u | (uint32_t)post << 23 | (uint32_t)load << 22 |
           (post ? (uint32_t)rm << 16 : 0) | (uint32_t)opcode << 12 | (uint32_t)size << 10 | (uint32_t)rn << 5 | (uint32_t)rt;
}

int main(void)
{
    static const int ops[][3] = { {0x0, 4, 4}, {0x2, 4, 1}, {0x4, 3, 3}, {0x6, 3, 1}, {0x7, 1, 1}, {0x8, 2, 2}, {0xA, 2, 1} };
    int nregs, selem, q, size, load, i, rt, post;

    /* FreeType's NPUSHW: ld2 {v0.8b, v1.8b}, [x13], #16 */
    assert(ios_simd_multi(0x0cdf81a0, &nregs, &selem) == 16 && nregs == 2 && selem == 2);
    fill();
    ios_simd_multi_move(&vregs[0][0], 0x0cdf81a0, mem, 1);
    for (i = 0; i < 8; i++) assert(vregs[0][i] == 0x40 + 2 * i && vregs[1][i] == 0x41 + 2 * i);
    for (i = 8; i < 16; i++) assert(!vregs[0][i] && !vregs[1][i]);
    assert(!memcmp(vregs[2], want[2], 16));

    for (i = 0; i < 7; i++)
        for (q = 0; q < 2; q++)
            for (size = 0; size < 4; size++)
                for (load = 0; load < 2; load++)
                    for (post = 0; post < 2; post++)
                        for (rt = 0; rt < 32; rt += 29)   /* v0 and v29 (wraps to v0) */
                        {
                            uint32_t insn = enc(q, load, post, 31, ops[i][0], size, 13, rt);
                            unsigned bytes = ios_simd_multi(insn, &nregs, &selem);
                            if (size == 3 && !q && ops[i][2] > 1) { assert(!bytes); continue; }
                            assert(bytes == (unsigned)ops[i][1] * (q ? 16u : 8u));
                            assert(nregs == ops[i][1] && selem == ops[i][2]);
                            fill();
                            memset(out, 0xEE, sizeof(out));
                            reference(rt, nregs, selem, q, 1 << size, load);
                            if (!load) memcpy(mem, out, sizeof(mem));   /* untouched tail stays 0xEE */
                            {
                                unsigned char got[64];
                                memset(got, 0xEE, sizeof(got));
                                ios_simd_multi_move(&vregs[0][0], insn, load ? mem : got, load);
                                if (load) assert(!memcmp(vregs, want, sizeof(want)));
                                else assert(!memcmp(got, mem, sizeof(got)) && !memcmp(vregs, want, sizeof(want)));
                            }
                        }

    /* Not this class: unallocated opcodes, a single structure (LD1 lane), LDR q, bit 21 set
     * in the post-index form, a nonzero Rm field in the no-offset form. */
    assert(!ios_simd_multi(0x0c401000, &nregs, &selem));   /* opcode 0001 */
    assert(!ios_simd_multi(0x0c40b000, &nregs, &selem));   /* opcode 1011 */
    assert(!ios_simd_multi(0x0d400000, &nregs, &selem));   /* ld1 {v0.b}[0], [x0] */
    assert(!ios_simd_multi(0x3dc00000, &nregs, &selem));   /* ldr q0, [x0] */
    assert(!ios_simd_multi(0x0ce07000, &nregs, &selem));   /* bit 21 */
    assert(!ios_simd_multi(0x0c417000, &nregs, &selem));   /* no offset, Rm 00001 */
    return 0;
}
''')
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=undefined,address", str(source), "-o", str(root / "test")], check=True)
            subprocess.run([str(root / "test")], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()

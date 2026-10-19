# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the memory-by-process table shipped in madeira-unix 0166 (PLA-414)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0166-virtual-log-memory-by-pseudo-process.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_proc_mem.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_proc_mem.h"
#include <assert.h>
#include <string.h>

static void put(struct ppm_owner *o, int kind, unsigned long long c, unsigned long long r, unsigned long long z) {
    o->bytes[kind][PPM_COMMITTED] += c; o->bytes[kind][PPM_RESIDENT] += r; o->bytes[kind][PPM_COMPRESSED] += z;
}

int main(void) {
    static struct ppm_table t, last;
    static int a, b;
    char row[320];
    const uint16_t path[] = u"C:\\Games\\Red Dead Redemption 2\\RDR2.exe";
    const uint16_t odd[] = { 'a', '/', 'x', 0xe9, ' ', 'y' };
    unsigned i;

    /* Owners: added once each, the runtime (NULL) too; a full table refuses. */
    assert(ppm_owner_for(&t, NULL) == &t.owner[0]);
    assert(ppm_owner_for(&t, &a) == &t.owner[1] && ppm_owner_for(&t, &a) == &t.owner[1] && t.count == 2);
    for (i = 2; i < PPM_OWNERS; i++) assert(ppm_owner_for(&t, (char *)&b + i));
    assert(!ppm_owner_for(&t, &b) && t.count == PPM_OWNERS);

    /* FEX's views by shape; kinds by place, the band before images. */
    assert(ppm_fex_shape(0x7c00100000ull, 0x100000) == PPM_FEX_SPAN);
    assert(ppm_fex_shape(0x7c00110000ull, 0x100000) == PPM_FEX_OTHER);
    assert(ppm_fex_shape(0x7c00000000ull, 0x400000 + 0x8000) == PPM_FEX_CALLRET);
    assert(ppm_fex_shape(0x7c00000000ull, 0x400000) == PPM_FEX_OTHER);
    assert(ppm_fex_shape(0x7c00000000ull, 0x200000) == PPM_FEX_L1);
    assert(ppm_kind(0x7c00000000ull, 0x7c00000000ull, 0x8000000000ull, 1) == PPM_FEX);
    assert(ppm_kind(0x7300000000ull, 0x7c00000000ull, 0x8000000000ull, 1) == PPM_IMAGE);
    assert(ppm_kind(0x7300000000ull, 0x7c00000000ull, 0x8000000000ull, 0) == PPM_PRIVATE);
    assert(ppm_kind(0x7c00000000ull, 0, 0, 0) == PPM_PRIVATE);

    /* Names: the file name only, ASCII, cut to the buffer. */
    char name[32];
    ppm_name(name, sizeof name, path, sizeof path / 2 - 1);
    assert(!strcmp(name, "RDR2.exe"));
    ppm_name(name, sizeof name, odd, 6);
    assert(!strcmp(name, "x??y"));
    ppm_name(name, 4, path, sizeof path / 2 - 1);
    assert(!strcmp(name, "RDR"));

    /* Change: the first table, an owner more or less, a pid change, or a 32 MiB move. */
    memset(&t, 0, sizeof t);
    ppm_owner_for(&t, NULL);
    struct ppm_owner *g = ppm_owner_for(&t, &a);
    g->pid = 0x74; g->threads = 62; strcpy(g->name, "RDR2.exe");
    put(g, PPM_IMAGE, 246ull << 20, 120ull << 20, 80ull << 20);
    put(g, PPM_FEX, 459ull << 20, 300ull << 20, 100ull << 20);
    g->fex_views[PPM_FEX_SPAN] = 208; g->fex_views[PPM_FEX_CALLRET] = 62; g->fex_views[PPM_FEX_L1] = 62;
    assert(ppm_moved(&t, NULL, 32ull << 20));
    last = t;
    assert(!ppm_moved(&t, &last, 32ull << 20));
    put(g, PPM_PRIVATE, 0, 0, (32ull << 20) - 1);
    assert(!ppm_moved(&t, &last, 32ull << 20));
    put(g, PPM_PRIVATE, 0, 0, 1);
    assert(ppm_moved(&t, &last, 32ull << 20));
    t = last;
    g->pid = 0x78;
    assert(ppm_moved(&t, &last, 32ull << 20));
    t = last;
    ppm_owner_for(&t, &b);
    assert(ppm_moved(&t, &last, 32ull << 20));

    /* Rows: MiB committed/resident/compressed per kind, then FEX's views. */
    t = last;
    ppm_row(&t.owner[1], row, sizeof row);
    assert(!strcmp(row, "pid=0074 RDR2.exe threads=62 image=246/120/80 private=0/0/0 fex=459/300/100 "
                        "spans=208 callret=62 l1=62"));
    ppm_row(&t.owner[0], row, sizeof row);
    assert(!strncmp(row, "runtime image=0/0/0 ", 20));
    t.owner[1].pid = 0;
    ppm_row(&t.owner[1], row, sizeof row);
    assert(!strncmp(row, "exited peb=", 11));
    assert(ppm_row(&t.owner[1], row, 8) > 8 && strlen(row) == 7);
    assert(ppm_sum(&last.owner[1], PPM_COMMITTED) == 705ull << 20);

    /* Readable guest ranges: none outside a view (a garbage pointer such as 0x3f3f...),
     * a runtime (VPROT_SYSTEM) view whole, another view only when every page is committed. */
    assert(!ppm_range_readable(PPM_RANGE_NO_VIEW, 1, 1));
    assert(ppm_range_readable(PPM_RANGE_SYSTEM_VIEW, 0, 0));
    assert(ppm_range_readable(PPM_RANGE_VIEW, 2, 2));
    assert(!ppm_range_readable(PPM_RANGE_VIEW, 2, 1));
    assert(!ppm_range_readable(PPM_RANGE_VIEW, 0, 0));
    return 0;
}
'''


class ProcessMemoryTableTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            (d / "pp_proc_mem.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)


if __name__ == "__main__":
    unittest.main()

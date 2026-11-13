# SPDX-License-Identifier: GPL-3.0-or-later
"""Social Club committed-extent census (PLA-841): compile pp_sc_census.h and pp_sc_layout.h as the
series leaves them (madeira-unix 0294, then 0299), and check its counting.

The census splits a page-protection change into the census ranges it touches (each layout slot's
real range, V8's code range among them once placed), keeps per kind the committed bytes, their peak and the
highest committed end offset, says when a line is due (a kind's first commit, then each 16 MiB of
peak or highest end), and keeps per kind the guest modules whose commits landed there. The runtime
glue in virtual_ios.c measures the pages and prints; the phone run reads its lines."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

from test_sc_layout import PATCH, ROOT, series_headers

UNIX = ROOT / 'patches/madeira-unix'

TEST_C = r'''
#include "pp_sc_census.h"
#include <assert.h>
#include <string.h>

#define MB(n) ((uint64_t)(n) << 20)
#define GB(n) ((uint64_t)(n) << 30)

static unsigned pieces(uint64_t a, uint64_t n, struct ppsc_census_piece *p)
{
    return ppsc_census_pieces(a, n, p, PPSC_CENSUS_PIECES);
}

int main(void)
{
    static struct ppsc_census_state s;
    struct ppsc_census_piece p[PPSC_CENSUS_PIECES];
    struct ppsc_census *c;
    unsigned i;
    int first;

    /* Kinds: the seven slots, V8's code range the last, then the JIT pool's RW alias. */
    assert(PPSC_CENSUS_JIT_RW == 8 && PPSC_CENSUS_KINDS == 9);
    assert(!strcmp(ppsc_census_name(PPSC_CEF), "CEF") && !strcmp(ppsc_census_id(PPSC_CEF), "2"));
    assert(!strcmp(ppsc_census_name(PPSC_ELF_META), "ELF_META") && !strcmp(ppsc_census_id(PPSC_ELF_META), "3"));
    assert(!strcmp(ppsc_census_name(PPSC_OILPAN), "OILPAN") && !strcmp(ppsc_census_id(PPSC_OILPAN), "5"));
    assert(!strcmp(ppsc_census_name(PPSC_CODE), "V8_CODE_RANGE") && !strcmp(ppsc_census_id(PPSC_CODE), "7"));
    assert(!strcmp(ppsc_census_name(PPSC_CENSUS_JIT_RW), "JIT_RW_ALIAS") && !strcmp(ppsc_census_id(PPSC_CENSUS_JIT_RW), "jit-rw"));

    /* helper-oom.md's l15 signature: libcef's PartitionAlloc slot span at 0x740844b000 is
     * ELF_META's page 0x844b000 into its real range. */
    assert(pieces(0x740844b000ULL, 0x1000, p) == 1);
    assert(p[0].kind == PPSC_ELF_META && p[0].base == 0x7400000000ULL);
    assert(p[0].a == 0x740844b000ULL && p[0].n == 0x1000);
    /* Oilpan's upper half: its real range starts 16 GiB above its reported base. */
    assert(pieces(0x7c00010000ULL, 0x4000, p) == 1 && p[0].kind == PPSC_OILPAN && p[0].base == 0x7c00000000ULL);
    /* Its lower half is chrome_elf's real range: only the address is known here. */
    assert(pieces(0x7800020000ULL, 0x4000, p) == 1 && p[0].kind == PPSC_ELF);
    /* Past a slot's real end: nothing (ELF_META's anchor ends at 0x7440000000). */
    assert(pieces(0x7440000000ULL - 0x1000, 0x2000, p) == 1);
    assert(p[0].kind == PPSC_ELF_META && p[0].a == 0x743ffff000ULL && p[0].n == 0x1000);
    assert(pieces(0x7440000000ULL, 0x1000, p) == 0);
    /* The RW alias at 0x7900000000 is no view: the JIT pool's figures come from the pool. */
    assert(pieces(0x7900000000ULL, 0x1000, p) == 0);

    /* An on-demand slot counts once an ask placed it: libcef's metadata, the
     * cage (adjacent to Oilpan's anchor; pieces come in kind order) and V8's code range. */
    assert(pieces(0x78c0001000ULL, 0x1000, p) == 0 && pieces(0x7700001000ULL, 0x1000, p) == 0);
    ppsc_placed[PPSC_CEF_META] = 0x78c0000000ULL;
    ppsc_placed[PPSC_CAGE] = 0x7a00000000ULL;
    ppsc_placed[PPSC_CODE] = 0x7700000000ULL;
    assert(pieces(0x78c0001000ULL, 0x1000, p) == 1 && p[0].kind == PPSC_CEF_META && p[0].base == 0x78c0000000ULL);
    assert(pieces(0x7bfffff000ULL, 0x2000, p) == 2 && p[0].kind == PPSC_OILPAN && p[1].kind == PPSC_CAGE);
    assert(p[0].a == 0x7c00000000ULL && p[0].n == 0x1000 && p[1].a == 0x7bfffff000ULL && p[1].n == 0x1000);
    assert(pieces(0x7700001000ULL, 0x1000, p) == 1);
    assert(p[0].kind == PPSC_CODE && p[0].base == 0x7700000000ULL && p[0].a == 0x7700001000ULL);
    assert(pieces(0x7700000000ULL + GB(1), 0x1000, p) == 0);

    /* Committed, peak and highest end (l5-diagnostics.md's kind 3 ended at
     * highest_end_off=0xaa82000). */
    c = &s.kind[PPSC_ELF_META];
    assert(ppsc_census_note(c, 0x4000, 0x14000) == 1);          /* the kind's first commit */
    assert(c->committed == 0x4000 && c->peak == 0x4000 && c->high_end_off == 0x14000);
    assert(ppsc_census_note(c, 0x4000, 0x24000) == 0);          /* under 16 MiB more: quiet */
    assert(c->committed == 0x8000 && c->high_end_off == 0x24000);
    assert(ppsc_census_note(c, 0, 0) == 0);                     /* a protection change */
    assert(ppsc_census_note(c, MB(16) - 0x8000, 0xaa82000) == 1);  /* the highest end grew 16 MiB */
    assert(c->peak == MB(16) && c->high_end_off == 0xaa82000);
    assert(ppsc_census_note(c, MB(8), 0x1000) == 0);            /* a lower commit: the high stays */
    assert(c->committed == MB(24) && c->peak == MB(24) && c->high_end_off == 0xaa82000);
    assert(ppsc_census_note(c, -(int64_t)MB(8), 0) == 0);       /* a decommit: the peak stays */
    assert(c->committed == MB(16) && c->peak == MB(24));
    assert(ppsc_census_note(c, MB(32), 0) == 1);                /* 48 MiB: 16 MiB past the last line's 16 */
    assert(c->committed == MB(48) && c->peak == MB(48));
    assert(ppsc_census_note(c, -(int64_t)GB(1), 0) == 0);       /* a view's release: never below 0 */
    assert(c->committed == 0 && c->peak == MB(48) && c->high_end_off == 0xaa82000);
    assert(ppsc_census_note(&s.kind[PPSC_CAGE], -0x1000, 0) == 0);   /* nothing committed yet: no line */
    assert(s.kind[PPSC_CAGE].committed == 0 && s.kind[PPSC_CAGE].peak == 0);

    /* The JIT pool's figures are absolute: head plus tail bytes, the head's end. */
    c = &s.kind[PPSC_CENSUS_JIT_RW];
    assert(ppsc_census_set(c, MB(300), MB(290)) == 1);
    assert(ppsc_census_set(c, MB(310), MB(300)) == 0);
    assert(ppsc_census_set(c, MB(280), MB(300)) == 0);
    assert(c->committed == MB(280) && c->peak == MB(310) && c->high_end_off == MB(300));
    assert(ppsc_census_set(c, MB(320), MB(306)) == 1);

    /* Callers: the guest module whose commit it was, its first commit flagged once. */
    c = &s.kind[PPSC_ELF_META];
    assert(ppsc_census_caller_note(c, 0x73e2cb0000ULL, 0x844b000, 0x1000, 0x1000, &first) == 0 && first);
    assert(ppsc_census_caller_note(c, 0x73e2cb0000ULL, 0x1338000, 0x2000, 0x1000, &first) == 0 && !first);
    assert(c->caller[0].module == 0x73e2cb0000ULL && c->caller[0].commits == 2 && c->caller[0].bytes == 0x2000);
    assert(c->caller[0].low_off == 0x1338000 && c->caller[0].high_end_off == 0x844c000);
    assert(ppsc_census_caller_note(c, 0x180000000ULL, 0x2000, 0x1000, 0x1000, &first) == 1 && first);
    assert(ppsc_census_caller_note(c, 0, 0x3000, 0x1000, 0x1000, &first) == 2 && first);   /* not attributed */
    assert(ppsc_census_caller_note(c, 0x190000000ULL, 0x4000, 0x1000, 0x1000, &first) == 3 && first);
    assert(ppsc_census_caller_note(c, 0x1a0000000ULL, 0x5000, 0x1000, 0x1000, &first) == PPSC_CENSUS_CALLERS && !first);
    assert(c->callers_full == 1);
    assert(ppsc_census_caller_note(c, 0x180000000ULL, 0x1000, 0x1000, 0x1000, &first) == 1 && !first);
    assert(c->caller[1].low_off == 0x1000 && c->caller[1].high_end_off == 0x3000 && c->caller[1].commits == 2);
    for (i = 0; i < PPSC_CENSUS_CALLERS; i++) assert(!c->caller[i].name[0]);   /* the glue names them */
    return 0;
}
'''


class SocialClubCensusTests(unittest.TestCase):
    def test_census_counting(self):
        cc = shutil.which('cc')
        self.assertIsNotNone(cc)
        census = next(UNIX.glob('0294-*.patch'))
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = series_headers(pathlib.Path(td), [(PATCH, 'pp_sc_layout.h'), (census, 'pp_sc_census.h')])
            (d / 'test.c').write_text(TEST_C)
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined,address',
                            str(d / 'test.c'), '-o', str(d / 'test')], check=True)
            subprocess.run([str(d / 'test')], check=True)


if __name__ == '__main__':
    unittest.main()

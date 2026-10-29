# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the shipped stock-CEF geometry before wiring it into the runtime."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / 'patches/madeira-unix/0224-ntdll-social-club-layout-geometry.patch'

TEST = r'''
#include "pp_sc_layout.h"
#include <assert.h>

int main(void) {
    unsigned held = 0, mine = 0;
    struct ppsc_range ranges[11];
    int n = 0;
    for (int k = PPSC_ELF; k <= PPSC_CAGE; k++) {
        struct ppsc_range r = ppsc_range(k);
        ranges[n++] = r;
        held |= PPSC_BIT(k);
        assert(r.size && r.base + r.size <= PPSC_TOP);
        assert(ppsc_contains(r, r.base, r.size));
        assert(ppsc_contains(r, r.base + r.size - 1, 1));
        assert(!ppsc_contains(r, r.base + r.size, 1));
        assert(!ppsc_contains(r, r.base - 1, 1));
        assert(!ppsc_contains(r, r.base, UINT64_MAX));
        assert(!ppsc_contains(r, r.base, 0));
        assert(!ppsc_contains(r, UINT64_MAX, 2));
    }
    ranges[n++] = (struct ppsc_range){PPSC_RW_BASE, PPSC_RW_CAP, 0, 0};
    ranges[n++] = (struct ppsc_range){PPSC_GAME_BASE, PPSC_GAME_SIZE, 0, 0};
    ranges[n++] = (struct ppsc_range){PPSC_FEX_BASE, PPSC_TOP - PPSC_FEX_BASE, 0, 0};
    ranges[n++] = (struct ppsc_range){PPSC_FLOOR, PPSC_CEILING - PPSC_FLOOR, 0, 0};
    for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++)
        assert(ranges[i].base + ranges[i].size <= ranges[j].base ||
               ranges[j].base + ranges[j].size <= ranges[i].base);
    assert(PPSC_GAME_SIZE == (8960ULL << 20));
    assert(PPSC_TOP - PPSC_FEX_BASE == (15ULL << 30));
    assert(!(ppsc_range(PPSC_ELF).report & (0x800000000ULL - 1)));
    assert(!(ppsc_range(PPSC_CEF).report & (0x800000000ULL - 1)));
    assert(ppsc_range(PPSC_OILPAN).base - ppsc_range(PPSC_OILPAN).report == 0x400000000ULL);
    assert(!ppsc_contains(ppsc_range(PPSC_ELF), ppsc_range(PPSC_OILPAN).base, 1));

    enum ppsc_slot sequence[] = {PPSC_ELF, PPSC_ELF_META, PPSC_CEF, PPSC_CEF_META, PPSC_OILPAN};
    for (unsigned i = 0; i < sizeof(sequence)/sizeof(*sequence); i++) {
        enum ppsc_slot k = sequence[i];
        struct ppsc_range r = ppsc_range(k);
        uint64_t hint = k == PPSC_ELF_META || k == PPSC_CEF_META ? 0x12340000ULL : 0x1000000000ULL;
        assert(ppsc_classify(r.asked, hint, held, mine) == k);
        held &= ~PPSC_BIT(k);
        mine |= PPSC_BIT(k);
        /* Another helper cannot steal the slots left for this helper. */
        assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, held, 0) == PPSC_REFUSE);
        assert(ppsc_classify(0x400000000ULL, 0x12340000ULL, held, 0) == PPSC_REFUSE);
    }
    assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, held, mine) == PPSC_REFUSE);
    assert(ppsc_classify(PPSC_GAME_SIZE, 0, held, mine) == PPSC_NONE);
    assert(ppsc_classify(4096, 0, held, mine) == PPSC_NONE);
    assert(ppsc_classify(0x800000000ULL, 1, held, mine) == PPSC_REFUSE);
    return 0;
}
'''


class SocialClubLayoutTests(unittest.TestCase):
    def test_shipped_geometry(self):
        cc = shutil.which('cc')
        self.assertIsNotNone(cc)
        section = PATCH.read_text().split('diff --git a/build/ntdll-unix/pp_sc_layout.h', 1)[1]
        section = section.split('diff --git ', 1)[0]
        header = '\n'.join(line[1:] for line in section.splitlines()
                           if line.startswith('+') and not line.startswith('+++')) + '\n'
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / 'pp_sc_layout.h').write_text(header)
            (d / 'test.c').write_text(TEST)
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=undefined', str(d / 'test.c'), '-o', str(d / 'test')], check=True)
            subprocess.run([str(d / 'test')], check=True)

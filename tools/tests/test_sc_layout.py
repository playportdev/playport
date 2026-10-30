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


OWNER_TEST = r'''
#include "pp_sc_layout.h"
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
typedef uint16_t WCHAR;
typedef struct { struct { WCHAR *Buffer; size_t Length; } ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
static PEB pebs[2];
static void *ios_jit_current_peb(void) { return &pebs[1]; }
static int ppsc_ready = 1;
static unsigned ppsc_held, holds;
struct file_view { uint64_t base, size; void *owner; unsigned contents; };
static struct file_view views[PPSC_CAGE + 1];
static struct file_view *find_view(const void *addr, size_t size)
{
    (void)size;
    for (int k = PPSC_ELF; k <= PPSC_CAGE; k++)
        if (views[k].size && (uintptr_t)addr >= views[k].base &&
            (uintptr_t)addr - views[k].base < views[k].size) return &views[k];
    return NULL;
}
static int ppsc_native_hold(uint64_t base, uint64_t size)
{
    holds++;
    for (int k = PPSC_ELF; k <= PPSC_CAGE; k++)
        if (views[k].size && base < views[k].base + views[k].size &&
            base + size > views[k].base) return 0; /* never overwrite an existing view */
    return 1;
}
#include "pp_sc_owner.h"
static unsigned noted;
/* pp_sc_vm.h's logger only reads the kept view. */
static void ppsc_note_kept_view_locked(int k, void *peb, struct file_view *v)
{
    assert(peb && v == &views[k]);
    noted++;
}
int main(void)
{
    assert(!ppsc_helper());
    for (int k = PPSC_ELF; k <= PPSC_CAGE; k++) {
        struct ppsc_range r = ppsc_range(k);
        assert(ppsc_in_slot(r.base, r.size));
        ppsc_owner[k] = &pebs[0];
    }
    /* l2's kept ELF, metadata and Oilpan; l3's wait address in metadata.
     * Teardown already took each view for the runtime (owner NULL). */
    int kept[] = { PPSC_ELF, PPSC_ELF_META, PPSC_OILPAN };
    for (unsigned i = 0; i < sizeof(kept)/sizeof(*kept); i++) {
        int k = kept[i];
        struct ppsc_range r = ppsc_range(k);
        views[k] = (struct file_view){r.base, r.size, NULL, 0x1234};
    }
    struct file_view before[ PPSC_CAGE + 1 ];
    memcpy(before, views, sizeof views);
    ppsc_owner_died_locked(NULL);
    assert(!holds && !ppsc_held);
    ppsc_owner_died_locked(&pebs[1]); /* another owner's exit cannot take these */
    assert(!holds && !ppsc_held);
    ppsc_owner_died_locked(&pebs[0]);
    assert(holds == 3 && noted == 3);
    for (int k = PPSC_ELF; k <= PPSC_CAGE; k++) {
        if (views[k].size) {
            assert(ppsc_owner[k] == &pebs[0] && !(ppsc_held & PPSC_BIT(k)));
        } else {
            assert(!ppsc_owner[k] && (ppsc_held & PPSC_BIT(k)));
        }
    }
    assert(!memcmp(before, views, sizeof views)); /* not moved, emptied or retagged */
    assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, ppsc_held, 0) == PPSC_REFUSE);
    ppsc_owner_died_locked(&pebs[0]); /* retained views still prevent reuse */
    assert(holds == 3 && !memcmp(before, views, sizeof views));

    /* A live foreign fragment not covering the slot's base defeats a fixed
     * native hold too. No held bit means no subsequent grant, not a soft grant. */
    struct ppsc_range r = ppsc_range(PPSC_CEF);
    ppsc_held &= ~PPSC_BIT(PPSC_CEF);
    ppsc_owner[PPSC_CEF] = &pebs[0];
    views[PPSC_CEF] = (struct file_view){r.base + 0x4000, 0x4000, &pebs[1], 0x5678};
    ppsc_owner_died_locked(&pebs[0]);
    assert(!(ppsc_held & PPSC_BIT(PPSC_CEF)));
    assert(views[PPSC_CEF].owner == &pebs[1] && views[PPSC_CEF].contents == 0x5678);
    assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, ppsc_held, 0) == PPSC_REFUSE);
    return 0;
}
'''


class SocialClubOwnerDeathTests(unittest.TestCase):
    def test_dead_owner_never_reclaims_kept_or_foreign_views(self):
        def added_header(patch, name):
            section = patch.read_text().split(f'diff --git a/build/ntdll-unix/{name}', 1)[1]
            section = section.split('diff --git ', 1)[0]
            return '\n'.join(line[1:] for line in section.splitlines()
                             if line.startswith('+') and not line.startswith('+++')) + '\n'

        owner_patch = ROOT / 'patches/madeira-unix/0226-ntdll-route-social-club-helper-reservations.patch'
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / 'pp_sc_layout.h').write_text(added_header(PATCH, 'pp_sc_layout.h'))
            (d / 'pp_sc_owner.h').write_text(added_header(owner_patch, 'pp_sc_owner.h'))
            (d / 'test.c').write_text(OWNER_TEST)
            subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined',
                            str(d / 'test.c'), '-o', str(d / 'test')], check=True)
            subprocess.run([str(d / 'test')], check=True, capture_output=True)

# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the shipped stock-CEF geometry before wiring it into the runtime."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
UNIX = ROOT / 'patches/madeira-unix'
PATCH = UNIX / '0224-ntdll-social-club-layout-geometry.patch'
OWNER_PATCH = UNIX / '0226-ntdll-route-social-club-helper-reservations.patch'
LATER = [UNIX / '0228-ntdll-second-social-club-elf-metadata-slot.patch',
         UNIX / '0231-ntdll-hold-a-dead-owner-s-Social-Club-slot-in-place-.patch',
         UNIX / '0236-ntdll-refuse-the-Social-Club-helper-s-impossible-V8-.patch',
         UNIX / '0243-ntdll-place-the-Social-Club-helper-s-V8-code-range-o.patch',
         UNIX / '0299-ntdll-the-Social-Club-layout-holds-only-its-anchors-.patch']


def added_header(patch, name):
    section = patch.read_text().split(f'diff --git a/build/ntdll-unix/{name}', 1)[1]
    section = section.split('diff --git ', 1)[0]
    return '\n'.join(line[1:] for line in section.splitlines()
                     if line.startswith('+') and not line.startswith('+++')) + '\n'


def series_headers(d, headers):
    """Each (patch, name) header as the series leaves it, under d/build/ntdll-unix."""
    unix = d / 'build/ntdll-unix'
    unix.mkdir(parents=True)
    for patch, name in headers:
        (unix / name).write_text(added_header(patch, name))
    # d is inside this repository's .work: keep git apply from treating it as one.
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(d.parent))
    include = [f'--include=build/ntdll-unix/{name}' for _, name in headers]
    for patch in LATER:
        subprocess.run(['git', 'apply', *include, str(patch)], cwd=d, env=env, check=True)
    return unix

TEST = r'''
#include "pp_sc_layout.h"
#include <assert.h>

#define MiB(n) ((uint64_t)(n) << 20)
#define GiB(n) ((uint64_t)(n) << 30)

/* PLA-842's sizing rule: the highest committed end measured, rounded up to a
 * power of two, times four, and at least 64 MiB. */
static uint64_t anchor_size(uint64_t high_end)
{
    uint64_t p = 1;
    while (p < high_end) p <<= 1;
    return 4 * p < MiB(64) ? MiB(64) : 4 * p;
}

static int disjoint(struct ppsc_range a, struct ppsc_range b)
{
    return a.base + a.size <= b.base || b.base + b.size <= a.base;
}

/* The window's free runs at boot: the guest window below FEX's band without
 * the anchors and the JIT pool's RW alias at its largest, 896 MiB. */
static const struct ppsc_gap boot[] = {
    {0x7004000000ULL, 0x3fc000000ULL}, {0x7440000000ULL, 0x3c0000000ULL},
    {0x7804000000ULL, 0xfc000000ULL}, {0x7938000000ULL, 0x2c8000000ULL}};

int main(void) {
    unsigned avail = 0, mine = 0;
    struct ppsc_range ranges[16];
    int n = 0;

    /* The anchors, from the census (PLA-841) and l5. */
    assert(ppsc_range(PPSC_CEF).size == anchor_size(0x5000) && ppsc_range(PPSC_CEF).size == MiB(64));
    assert(ppsc_range(PPSC_ELF).size == anchor_size(0x5000));
    assert(ppsc_range(PPSC_ELF_META).size == anchor_size(0xaa82000) && ppsc_range(PPSC_ELF_META).size == GiB(1));
    assert(ppsc_range(PPSC_OILPAN).size == anchor_size(0x6420000) && ppsc_range(PPSC_OILPAN).size == MiB(512));
    assert(PPSC_ANCHORS == (PPSC_BIT(PPSC_ELF) | PPSC_BIT(PPSC_CEF) | PPSC_BIT(PPSC_ELF_META) | PPSC_BIT(PPSC_OILPAN)));
    assert(!(PPSC_ANCHORS & PPSC_ON_DEMAND) && (PPSC_ANCHORS | PPSC_ON_DEMAND) == (1u << (PPSC_LAST_SLOT + 1)) - 2);
    assert(PPSC_LAST_SLOT == PPSC_CODE && PPSC_CODE == 7 && PPSC_REFUSE == 8);
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) {
        struct ppsc_range r = ppsc_range(k);
        if (!(PPSC_ANCHORS & PPSC_BIT(k))) {
            /* An on-demand slot no ask placed has no range. */
            assert(!r.size && !r.base && !ppsc_contains(r, 0, 1));
            continue;
        }
        ranges[n++] = r;
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
    ranges[n++] = (struct ppsc_range){PPSC_FEX_BASE, PPSC_TOP - PPSC_FEX_BASE, 0, 0};
    ranges[n++] = (struct ppsc_range){PPSC_FLOOR, PPSC_CEILING - PPSC_FLOOR, 0, 0};
    for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) assert(disjoint(ranges[i], ranges[j]));
    /* About 1.6 GiB held from boot, where the old layout held 30.25 GiB. */
    assert(ppsc_range(PPSC_CEF).size + ppsc_range(PPSC_ELF).size + ppsc_range(PPSC_ELF_META).size +
           ppsc_range(PPSC_OILPAN).size == MiB(1664));
    assert(PPSC_FLOOR == ppsc_range(PPSC_CEF).base + ppsc_range(PPSC_CEF).size);
    assert(PPSC_FEX_BASE == ppsc_range(PPSC_OILPAN).base + ppsc_range(PPSC_OILPAN).size);
    assert(PPSC_TOP - PPSC_FEX_BASE == GiB(16) - MiB(512) && PPSC_RW_CAP == GiB(4));
    /* The window's two 32 GiB-aligned bases; Oilpan 16 GiB above chrome_elf's;
     * ELF_META the upper half of libcef's 32 GiB report. */
    assert(!(ppsc_range(PPSC_ELF).report & (GiB(32) - 1)) && !(ppsc_range(PPSC_CEF).report & (GiB(32) - 1)));
    assert(ppsc_range(PPSC_OILPAN).base - ppsc_range(PPSC_OILPAN).report == GiB(16));
    assert(ppsc_range(PPSC_OILPAN).report == ppsc_range(PPSC_ELF).base);
    assert(ppsc_range(PPSC_ELF_META).base == ppsc_range(PPSC_CEF).report + GiB(16));
    assert(!ppsc_contains(ppsc_range(PPSC_ELF), ppsc_range(PPSC_OILPAN).base, 1));

    /* The on-demand slots' homes: aligned as each needs, inside the window
     * below FEX's band, clear of the anchors, of each other and of the RW alias
     * at its cap, and each inside one of the boot runs. */
    {
        enum ppsc_slot od[] = {PPSC_CEF_META, PPSC_CAGE, PPSC_CODE};
        struct ppsc_range h[3];
        for (int i = 0; i < 3; i++) {
            struct ppsc_home m = ppsc_home(od[i]);
            h[i] = (struct ppsc_range){m.home, m.size, 0, 0};
            assert(m.size && !(m.home & (m.align - 1)) && m.home >= PPSC_FLOOR && m.home + m.size <= PPSC_OILPAN_BASE);
            for (int j = 0; j < n - 3; j++) assert(disjoint(h[i], ranges[j]));
            assert(disjoint(h[i], (struct ppsc_range){PPSC_RW_BASE, PPSC_RW_CAP, 0, 0}));
            for (int j = 0; j < i; j++) assert(disjoint(h[i], h[j]));
            assert(ppsc_place(od[i], boot, 4) == m.home);
        }
        assert(ppsc_home(PPSC_CAGE).size == GiB(8) && ppsc_home(PPSC_CAGE).align == GiB(4));
        assert(ppsc_home(PPSC_CODE).size == GiB(1) && ppsc_home(PPSC_CODE).align == GiB(4));
        assert(ppsc_home(PPSC_CEF_META).size == GiB(1) && ppsc_home(PPSC_CEF_META).asked == GiB(16));
        /* The run above ELF_META's anchor keeps 11 GiB whole for the game's pools. */
        assert(ppsc_home(PPSC_CODE).home - (ppsc_range(PPSC_ELF_META).base + ppsc_range(PPSC_ELF_META).size) == GiB(11));
    }

    /* A placed slot's range: its real size at its base, reporting its base
     * with the size asked. */
    ppsc_placed[PPSC_CAGE] = 0x7600000000ULL;
    assert(ppsc_range(PPSC_CAGE).base == 0x7600000000ULL && ppsc_range(PPSC_CAGE).size == GiB(8) &&
           ppsc_range(PPSC_CAGE).report == 0x7600000000ULL && ppsc_range(PPSC_CAGE).asked == GiB(8));
    ppsc_placed[PPSC_CAGE] = 0;

    /* ppsc_place: the home when free, else the highest aligned base that fits. */
    {
        const struct ppsc_gap taken[] = {{0x7004000000ULL, 0x3fc000000ULL}, {0x7440000000ULL, 0x3c0000000ULL},
                                         {0x7804000000ULL, 0x80000000ULL}, {0x7b10000000ULL, 0xf0000000ULL}};
        const struct ppsc_gap l16[] = {{0x72b0364000ULL, 0x73b6ef4000ULL - 0x72b0364000ULL}};
        const struct ppsc_gap l13[] = {{0x7280000000ULL, 0x20300000ULL}, {0x70f0000000ULL, 0x30300000ULL}};
        const struct ppsc_gap odd[] = {{0x7000010000ULL, GiB(9)}, {UINT64_MAX - GiB(1), GiB(2)}};
        assert(ppsc_place(PPSC_CAGE, taken, 4) == 0x7600000000ULL);
        assert(ppsc_place(PPSC_CEF_META, taken, 4) == 0x7bc0000000ULL);
        assert(ppsc_place(PPSC_CODE, taken, 4) == 0x7700000000ULL);
        /* l16 B's largest hole holds one 4 GiB-aligned GiB, as 0243 found; l13's
         * restarts (largest hole 515 MB) none. */
        assert(ppsc_place(PPSC_CODE, l16, 1) == 0x7300000000ULL);
        assert(!ppsc_place(PPSC_CODE, l13, 2) && !ppsc_place(PPSC_CODE, l13, 0));
        /* An unaligned run that holds the size but no aligned base; one that wraps. */
        assert(ppsc_place(PPSC_CAGE, odd, 2) == 0);
        assert(ppsc_place(PPSC_CODE, odd, 2) == 0x7200000000ULL);
        /* Anchors are never placed. */
        assert(!ppsc_place(PPSC_ELF, boot, 4) && !ppsc_place(PPSC_NONE, boot, 4));
    }

    /* ppsc_classify: the anchors in the helper's order, then libcef's metadata. */
    avail = PPSC_ANCHORS | PPSC_ON_DEMAND;
    enum ppsc_slot sequence[] = {PPSC_ELF, PPSC_ELF_META, PPSC_CEF, PPSC_CEF_META, PPSC_OILPAN};
    for (unsigned i = 0; i < sizeof(sequence)/sizeof(*sequence); i++) {
        enum ppsc_slot k = sequence[i];
        uint64_t asked = k == PPSC_CEF_META ? GiB(16) : ppsc_range(k).asked;
        uint64_t hint = k == PPSC_ELF_META || k == PPSC_CEF_META ? 0x12340000ULL : 0x1000000000ULL;
        assert(ppsc_classify(asked, hint, avail, mine) == k);
        avail &= ~PPSC_BIT(k);
        mine |= PPSC_BIT(k);
        /* Another helper cannot steal the slots left for this helper. */
        assert(ppsc_classify(GiB(32), 0x1000000000ULL, avail, 0) == PPSC_REFUSE);
        assert(ppsc_classify(GiB(16), 0x12340000ULL, avail, 0) == PPSC_REFUSE);
    }
    assert(ppsc_classify(GiB(32), 0x1000000000ULL, avail, mine) == PPSC_REFUSE);
    assert(ppsc_classify(0x230000000ULL, 0, avail, mine) == PPSC_NONE);       /* RDR2's 8,960 MiB */
    assert(ppsc_classify(4096, 0, avail, mine) == PPSC_NONE);
    assert(ppsc_classify(GiB(32), 1, avail, mine) == PPSC_REFUSE);
    /* ELF_META taken (a dead helper's kept view): the next helper's metadata ask is refused. */
    assert(ppsc_classify(GiB(16), 0x12340000ULL, PPSC_ON_DEMAND, PPSC_BIT(PPSC_ELF)) == PPSC_REFUSE);
    assert(ppsc_classify(GiB(16), GiB(16), PPSC_ANCHORS, PPSC_BIT(PPSC_ELF)) == PPSC_NONE);   /* aligned: not metadata */
    /* V8's code range: a hinted 1 GiB at a 4 GiB-aligned hint, l1-l16's offsets. */
    for (uint64_t off = 0; off < GiB(16); off += GiB(4))
        assert(ppsc_classify(GiB(1), 0x4c7000000000ULL + off, avail, mine) == PPSC_CODE);
    assert(ppsc_classify(GiB(1), 0x4c7d00010000ULL, avail, mine) == PPSC_NONE);   /* not 4 GiB-aligned */
    assert(ppsc_classify(GiB(1), 0, avail, mine) == PPSC_NONE);                    /* unhinted */
    assert(ppsc_classify(GiB(1) - 0x10000, 0x60800000000ULL, avail, mine) == PPSC_NONE);
    assert(ppsc_classify(GiB(1), 0x60800000000ULL, avail & ~PPSC_BIT(PPSC_CODE), mine) == PPSC_NONE);   /* another's */
    assert(ppsc_classify(GiB(1), 0x60800000000ULL, avail, mine | PPSC_BIT(PPSC_CODE)) == PPSC_NONE);    /* its second */
    assert(ppsc_classify(GiB(1), 0x60800000000ULL, avail, 0) == PPSC_CODE);        /* before its pools too */

    /* ppsc_impossible (madeira-unix 0236): every helper reserve size l12 logged. */
    {
        unsigned cage = PPSC_BIT(PPSC_CAGE), core = PPSC_BIT(PPSC_ELF) | PPSC_BIT(PPSC_CEF);
        unsigned before = core | PPSC_BIT(PPSC_ELF_META) | PPSC_BIT(PPSC_CEF_META) | PPSC_BIT(PPSC_OILPAN);
        /* V8's sandbox ladder, 512 GiB down to 16 GiB: never fits, cage or not. */
        uint64_t ladder[] = { GiB(512), GiB(256), GiB(128), GiB(64), GiB(32), GiB(16) };
        for (unsigned i = 0; i < sizeof(ladder)/sizeof(*ladder); i++) {
            assert(ppsc_impossible(ladder[i], 0, before) == PPSC_PROBE_NO_GAP);
            assert(ppsc_impossible(ladder[i], 0, before | cage) == PPSC_PROBE_NO_GAP);
            assert(ppsc_impossible(ladder[i], 0, 0) == PPSC_PROBE_NO_GAP);
            /* the hinted try fails fast already: left alone */
            assert(ppsc_impossible(ladder[i], 0x1400000000ULL, before) == PPSC_PROBE_NONE);
            assert(ppsc_impossible(ladder[i], 0x2f00000000ULL, before | cage) == PPSC_PROBE_NONE);
        }
        /* The cage's own 8 GiB ask, before the helper owns kind 6: to the router as before. */
        assert(ppsc_impossible(GiB(8), 0, before) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(GiB(8), 0, 0) == PPSC_PROBE_NONE);
        /* gin's pool tries after the cage: 16 GiB and its padded 16 GiB - 64 KiB never fit;
         * 8 GiB (and Wine's +64 KiB) is a sandbox subspace probe V8 drops. */
        assert(ppsc_impossible(GiB(16), 0, before | cage) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(0x3ffff0000ULL, 0, before | cage) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(GiB(8), 0, before | cage) == PPSC_PROBE_SANDBOX);
        assert(ppsc_impossible(0x200010000ULL, 0, before | cage) == PPSC_PROBE_SANDBOX);
        assert(ppsc_impossible(GiB(8), 0, cage) == PPSC_PROBE_SANDBOX);
        assert(ppsc_impossible(GiB(8), 0x8400000000ULL, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(GiB(8), 0x15400000000ULL, before | cage) == PPSC_PROBE_NONE);
        /* Smaller asks keep Wine's path: the 1 GiB trusted range, the 4 GiB pool, l13's
         * restarted helper's 5 GiB - 64 KiB, the game's 8960 MiB and 1175 MB. */
        assert(ppsc_impossible(GiB(1), 0, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(GiB(1), 0x528b00000000ULL, before) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(GiB(4), 0, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x13fff0000ULL, 0, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x230000000ULL, 0, 0) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x49701000ULL, 0, 0) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(4096, 0, before | cage) == PPSC_PROBE_NONE);
        /* The bound: exactly the layout's largest gap still goes to the walk. */
        assert(PPSC_CEILING - PPSC_FLOOR == 0x3fbff0000ULL);
        assert(ppsc_impossible(0x3fbff0000ULL, 0, before) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x3fbff0001ULL, 0, before) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(UINT64_MAX, 0, 0) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(GiB(8) - 1, 0, before | cage) == PPSC_PROBE_NONE);
    }
    return 0;
}
'''


class SocialClubLayoutTests(unittest.TestCase):
    def test_shipped_geometry(self):
        cc = shutil.which('cc')
        self.assertIsNotNone(cc)
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = series_headers(pathlib.Path(td), [(PATCH, 'pp_sc_layout.h')])
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
static struct file_view views[PPSC_LAST_SLOT + 1];
static struct file_view *find_view(const void *addr, size_t size)
{
    (void)size;
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++)
        if (views[k].size && (uintptr_t)addr >= views[k].base &&
            (uintptr_t)addr - views[k].base < views[k].size) return &views[k];
    return NULL;
}
static int ppsc_native_hold(uint64_t base, uint64_t size)
{
    holds++;
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++)
        if (views[k].size && base < views[k].base + views[k].size &&
            base + size > views[k].base) return 0; /* never overwrite an existing view */
    return 1;
}
#include "pp_sc_owner.h"
static unsigned noted;
/* pp_sc_vm.h's hold in place (0231); this test's teardown frees no view. */
__attribute__((unused)) static int ppsc_owner_view_freed_locked(void *peb, struct file_view *view)
{
    (void)peb; (void)view;
    return 0;
}
/* pp_sc_vm.h's logger only reads the kept view. */
static void ppsc_note_kept_view_locked(int k, void *peb, struct file_view *v)
{
    assert(peb && v == &views[k]);
    noted++;
}
int main(void)
{
    assert(!ppsc_helper());
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++)       /* the on-demand slots placed at their homes */
        if (PPSC_ON_DEMAND & PPSC_BIT(k)) ppsc_placed[k] = ppsc_home(k).home;
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) {
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
    struct file_view before[ PPSC_LAST_SLOT + 1 ];
    memcpy(before, views, sizeof views);
    ppsc_owner_died_locked(NULL);
    assert(!holds && !ppsc_held);
    ppsc_owner_died_locked(&pebs[1]); /* another owner's exit cannot take these */
    assert(!holds && !ppsc_held);
    ppsc_owner_died_locked(&pebs[0]);
    assert(holds == 4 && noted == 3);   /* CEF, CEF_META, the cage and the code range */
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) {
        if (views[k].size) {
            assert(ppsc_owner[k] == &pebs[0] && !(ppsc_held & PPSC_BIT(k)));
        } else {
            assert(!ppsc_owner[k] && (ppsc_held & PPSC_BIT(k)));
        }
    }
    assert(!memcmp(before, views, sizeof views)); /* not moved, emptied or retagged */
    assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, ppsc_held, 0) == PPSC_REFUSE);
    ppsc_owner_died_locked(&pebs[0]); /* retained views still prevent reuse */
    assert(holds == 4 && !memcmp(before, views, sizeof views));

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
    /* The same for an on-demand slot: not held, and placed anew at the next ask. */
    r = ppsc_range(PPSC_CAGE);
    ppsc_held &= ~PPSC_BIT(PPSC_CAGE);
    ppsc_owner[PPSC_CAGE] = &pebs[0];
    views[PPSC_CAGE] = (struct file_view){r.base + 0x10000, 0x4000, &pebs[1], 0x5678};
    ppsc_owner_died_locked(&pebs[0]);
    assert(!(ppsc_held & PPSC_BIT(PPSC_CAGE)) && !ppsc_owner[PPSC_CAGE] && !ppsc_placed[PPSC_CAGE]);
    assert(!ppsc_range(PPSC_CAGE).size && views[PPSC_CAGE].owner == &pebs[1]);

    /* Impossible-probe refusals (madeira-unix 0236): counted per PEB, eight PEBs at once,
     * taken (and the entry freed) by the cage's owner-exit line or at the owner's exit. */
    {
        static char peb_ids[10];
        char buf[48];
        assert(!ppsc_probe_counted_locked(NULL) && !ppsc_probe_take_locked(NULL));
        for (unsigned i = 1; i <= 26; i++) assert(ppsc_probe_counted_locked(&peb_ids[0]) == i);
        assert(ppsc_probe_counted_locked(&peb_ids[1]) == 1);
        for (int p = 2; p < PPSC_PROBE_PEBS; p++) assert(ppsc_probe_counted_locked(&peb_ids[p]) == 1);
        assert(!ppsc_probe_counted_locked(&peb_ids[PPSC_PROBE_PEBS]));   /* full: refused uncounted */
        assert(!strcmp(ppsc_probe_suffix_locked(PPSC_OILPAN, &peb_ids[0], buf, sizeof buf), ""));
        assert(!strcmp(ppsc_probe_suffix_locked(PPSC_CAGE, &peb_ids[0], buf, sizeof buf),
                       "; 26 impossible probes refused"));
        assert(!ppsc_probe_take_locked(&peb_ids[0]));                     /* taken once */
        assert(ppsc_probe_counted_locked(&peb_ids[PPSC_PROBE_PEBS]) == 1); /* its entry is free again */
        assert(ppsc_probe_take_locked(&peb_ids[1]) == 1 && !ppsc_probe_take_locked(&peb_ids[1]));
        /* An owner that dies without the cage line gives its count back too. */
        assert(ppsc_probe_counted_locked(&pebs[1]) == 1 && ppsc_probe_counted_locked(&pebs[1]) == 2);
        ppsc_owner_died_locked(&pebs[1]);
        assert(!ppsc_probe_take_locked(&pebs[1]));
        assert(!strcmp(ppsc_probe_suffix_locked(PPSC_CAGE, &peb_ids[9], buf, sizeof buf),
                       "; 0 impossible probes refused"));
    }
    return 0;
}
'''


class SocialClubOwnerDeathTests(unittest.TestCase):
    def test_dead_owner_never_reclaims_kept_or_foreign_views(self):
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = series_headers(pathlib.Path(td), [(PATCH, 'pp_sc_layout.h'), (OWNER_PATCH, 'pp_sc_owner.h')])
            (d / 'test.c').write_text(OWNER_TEST)
            subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined',
                            str(d / 'test.c'), '-o', str(d / 'test')], check=True)
            subprocess.run([str(d / 'test')], check=True, capture_output=True)

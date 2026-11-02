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
         UNIX / '0243-ntdll-place-the-Social-Club-helper-s-V8-code-range-o.patch']


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

/* The retry's walk over ppsc_code_range_next against a window whose only free
 * space is holes[]: the first base whose [b, b + size) lies inside one hole. */
static uint64_t code_range_fit(uint64_t size, uint64_t hint, const uint64_t (*holes)[2], unsigned n)
{
    uint64_t b = 0;
    while ((b = ppsc_code_range_next(size, hint, b)))
        for (unsigned i = 0; i < n; i++)
            if (b >= holes[i][0] && b + size <= holes[i][1]) return b;
    return 0;
}

int main(void) {
    unsigned held = 0, mine = 0;
    struct ppsc_range ranges[11];
    int n = 0;
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) {
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
    /* The spare chrome_elf metadata slot: 1 GiB real right below the cage,
     * reporting its own base with the 16 GiB asked; the RW alias stops below. */
    {
        struct ppsc_range m = ppsc_range(PPSC_ELF_META2);
        assert(m.base == 0x79c0000000ULL && m.size == 0x40000000ULL);
        assert(m.report == m.base && m.asked == ppsc_range(PPSC_ELF_META).asked);
        assert(m.base + m.size == ppsc_range(PPSC_CAGE).base);
        assert(PPSC_RW_BASE + PPSC_RW_CAP == m.base && PPSC_RW_CAP == 0xc0000000ULL);
        assert(PPSC_ELF_META2 < PPSC_REFUSE && PPSC_LAST_SLOT == PPSC_ELF_META2 && PPSC_REFUSE == 8);
    }

    enum ppsc_slot sequence[] = {PPSC_ELF, PPSC_ELF_META, PPSC_CEF, PPSC_CEF_META, PPSC_OILPAN};
    for (unsigned i = 0; i < sizeof(sequence)/sizeof(*sequence); i++) {
        enum ppsc_slot k = sequence[i];
        struct ppsc_range r = ppsc_range(k);
        uint64_t hint = k == PPSC_ELF_META || k == PPSC_CEF_META ? 0x12340000ULL : 0x1000000000ULL;
        assert(ppsc_classify(r.asked, hint, held, mine, 0) == k);
        held &= ~PPSC_BIT(k);
        mine |= PPSC_BIT(k);
        /* Another helper cannot steal the slots left for this helper. */
        assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, held, 0, mine) == PPSC_REFUSE);
        assert(ppsc_classify(0x400000000ULL, 0x12340000ULL, held, 0, mine) == PPSC_REFUSE);
    }
    assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, held, mine, 0) == PPSC_REFUSE);
    assert(ppsc_classify(PPSC_GAME_SIZE, 0, held, mine, 0) == PPSC_NONE);
    assert(ppsc_classify(4096, 0, held, mine, 0) == PPSC_NONE);
    assert(ppsc_classify(0x800000000ULL, 1, held, mine, 0) == PPSC_REFUSE);

    /* ELF_META2: only for a helper with ELF and no ELF metadata, only while
     * another PEB owns ELF_META, and only while it is held. */
    {
        unsigned all = 0, elf = PPSC_BIT(PPSC_ELF), meta = PPSC_BIT(PPSC_ELF_META);
        unsigned meta2 = PPSC_BIT(PPSC_ELF_META2), both = elf | PPSC_BIT(PPSC_CEF);
        uint64_t m = 0x400000000ULL, h = 0x12340000ULL;
        for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) all |= PPSC_BIT(k);
        assert(ppsc_classify(m, h, all & ~elf, elf, 0) == PPSC_ELF_META);            /* ELF_META held: that */
        assert(ppsc_classify(m, h, all & ~elf, elf, meta2) == PPSC_ELF_META);
        assert(ppsc_classify(m, h, all & ~(elf | meta), elf, meta) == PPSC_ELF_META2);
        assert(ppsc_classify(m, h, all & ~(elf | meta), elf, 0) == PPSC_REFUSE);       /* unheld, unowned */
        assert(ppsc_classify(m, h, all & ~(elf | meta | meta2), elf, meta) == PPSC_REFUSE);
        assert(ppsc_classify(m, h, all & ~(elf | meta), elf | meta2, meta) == PPSC_REFUSE);  /* never both */
        assert(ppsc_classify(m, h, all & ~(elf | meta), elf | meta, 0) == PPSC_REFUSE);
        assert(ppsc_classify(m, h, all & ~(elf | meta2), elf | meta2, 0) == PPSC_REFUSE);
        assert(ppsc_classify(m, h, all & ~both, both, meta) == PPSC_CEF_META);         /* not the spare */
        assert(ppsc_classify(m, h, all & ~(both | meta2), both | meta2, meta) == PPSC_CEF_META);
        assert(ppsc_classify(m, h, all & ~meta, 0, meta) == PPSC_REFUSE);              /* no ELF */
        assert(ppsc_classify(m, 0x400000000ULL, all & ~(elf | meta), elf, meta) == PPSC_NONE);  /* aligned: not metadata */
    }

    /* ppsc_impossible (madeira-unix 0236): every helper reserve size l12 logged. */
    {
        unsigned cage = PPSC_BIT(PPSC_CAGE), core = PPSC_BIT(PPSC_ELF) | PPSC_BIT(PPSC_CEF);
        unsigned before = core | PPSC_BIT(PPSC_ELF_META) | PPSC_BIT(PPSC_CEF_META) | PPSC_BIT(PPSC_OILPAN);
        /* V8's sandbox ladder, 512 GiB down to 16 GiB: never fits, cage or not. */
        uint64_t ladder[] = { 0x8000000000ULL, 0x4000000000ULL, 0x2000000000ULL, 0x1000000000ULL,
                              0x800000000ULL, 0x400000000ULL };
        for (unsigned i = 0; i < sizeof(ladder)/sizeof(*ladder); i++) {
            assert(ppsc_impossible(ladder[i], 0, before) == PPSC_PROBE_NO_GAP);
            assert(ppsc_impossible(ladder[i], 0, before | cage) == PPSC_PROBE_NO_GAP);
            assert(ppsc_impossible(ladder[i], 0, 0) == PPSC_PROBE_NO_GAP);
            /* the hinted try fails fast already: left alone */
            assert(ppsc_impossible(ladder[i], 0x1400000000ULL, before) == PPSC_PROBE_NONE);
            assert(ppsc_impossible(ladder[i], 0x2f00000000ULL, before | cage) == PPSC_PROBE_NONE);
        }
        /* The cage's own 8 GiB ask, before the helper owns kind 6: to the router as before. */
        assert(ppsc_impossible(0x200000000ULL, 0, before) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x200000000ULL, 0, 0) == PPSC_PROBE_NONE);
        /* gin's pool tries after the cage: 16 GiB and its padded 16 GiB - 64 KiB never fit;
         * 8 GiB (and Wine's +64 KiB) is a sandbox subspace probe V8 drops. */
        assert(ppsc_impossible(0x400000000ULL, 0, before | cage) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(0x3ffff0000ULL, 0, before | cage) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(0x200000000ULL, 0, before | cage) == PPSC_PROBE_SANDBOX);
        assert(ppsc_impossible(0x200010000ULL, 0, before | cage) == PPSC_PROBE_SANDBOX);
        assert(ppsc_impossible(0x200000000ULL, 0, cage) == PPSC_PROBE_SANDBOX);
        assert(ppsc_impossible(0x200000000ULL, 0x8400000000ULL, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x200000000ULL, 0x15400000000ULL, before | cage) == PPSC_PROBE_NONE);
        /* Smaller asks keep Wine's path: the 1 GiB trusted range, the 4 GiB pool, l13's
         * restarted helper's 5 GiB - 64 KiB, the game's 8960 MiB and 1175 MB. */
        assert(ppsc_impossible(0x40000000ULL, 0, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x40000000ULL, 0x528b00000000ULL, before) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x100000000ULL, 0, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x13fff0000ULL, 0, before | cage) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(PPSC_GAME_SIZE, 0, 0) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x49701000ULL, 0, 0) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(4096, 0, before | cage) == PPSC_PROBE_NONE);
        /* The bound: exactly the layout's largest gap still goes to the walk. */
        assert(PPSC_CEILING - PPSC_FLOOR == 0x3efff0000ULL);
        assert(ppsc_impossible(0x3efff0000ULL, 0, before) == PPSC_PROBE_NONE);
        assert(ppsc_impossible(0x3efff0001ULL, 0, before) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(UINT64_MAX, 0, 0) == PPSC_PROBE_NO_GAP);
        assert(ppsc_impossible(0x1ffffffffULL, 0, before | cage) == PPSC_PROBE_NONE);
    }

    /* ppsc_code_range_next (madeira-unix 0243): the 4 GiB-aligned bases of the window. */
    {
        uint64_t gib = 0x40000000ULL, want[] = {0x7100000000ULL, 0x7200000000ULL, 0x7300000000ULL};
        uint64_t b = 0;
        unsigned n = 0;
        while ((b = ppsc_code_range_next(gib, 0x60800000000ULL, b))) {
            assert(n < 3 && b == want[n]);
            assert(b >= PPSC_FLOOR && b + gib <= PPSC_CEILING && !(b & (PPSC_CODE_RANGE_ALIGN - 1)));
            n++;
        }
        assert(n == 3);
        /* l16 B's largest hole [0x72b0364000, 0x73b6ef4000): the first base inside it,
         * for its off-0 hint (cand plain) and its off-4 GiB one (cand guard). */
        {
            const uint64_t l16[][2] = {{0x72b0364000ULL, 0x73b6ef4000ULL}};
            assert(code_range_fit(gib, 0x60800000000ULL, l16, 1) == 0x7300000000ULL);
            assert(code_range_fit(gib, 0x4c7d00000000ULL, l16, 1) == 0x7300000000ULL);
        }
        /* A fully occupied window (l13's restarts: largest hole 515 MB): none, so
         * the kernel's pick follows as before. */
        {
            const uint64_t l13[][2] = {{0x7100000000ULL - 0x10000000ULL, 0x7100000000ULL + 0x20300000ULL},
                                       {0x7280000000ULL, 0x72a0300000ULL}};
            assert(!code_range_fit(gib, 0x60800000000ULL, l13, 2));
            assert(!code_range_fit(gib, 0x60800000000ULL, l13, 0));
        }
        /* Every hint offset l1-l16 logged (0, 4, 8, 12 GiB) gets the same bases. */
        for (uint64_t off = 0; off < 0x400000000ULL; off += 0x100000000ULL)
            assert(ppsc_code_range_next(gib, 0x4c7000000000ULL + off, 0) == 0x7100000000ULL);
        /* Not 4 GiB-aligned, unhinted or empty: not this rule. */
        assert(!ppsc_code_range_next(gib, 0x4c7d00010000ULL, 0));
        assert(!ppsc_code_range_next(gib, 0x4c7cffff0000ULL, 0));
        assert(!ppsc_code_range_next(gib, 0, 0));
        assert(!ppsc_code_range_next(0, 0x60800000000ULL, 0));
        /* Larger asks fit fewer bases; one no base can hold gets none. */
        assert(ppsc_code_range_next(0x200000000ULL, 0x60800000000ULL, 0) == 0x7100000000ULL);
        assert(!ppsc_code_range_next(0x200000000ULL, 0x60800000000ULL, 0x7100000000ULL));
        assert(ppsc_code_range_next(0x80000000ULL, 0x60800000000ULL, 0x7200000000ULL) == 0x7300000000ULL);
        assert(ppsc_code_range_next(PPSC_CEILING - 0x7100000000ULL, 0x60800000000ULL, 0) == 0x7100000000ULL);
        assert(!ppsc_code_range_next(PPSC_CEILING - 0x7100000000ULL + 1, 0x60800000000ULL, 0));
        assert(!ppsc_code_range_next(UINT64_MAX, 0x60800000000ULL, 0));
        /* prev past the window, or not a base: no wrap, the next base above it. */
        assert(!ppsc_code_range_next(gib, 0x60800000000ULL, PPSC_CEILING));
        assert(!ppsc_code_range_next(gib, 0x60800000000ULL, UINT64_MAX));
        assert(ppsc_code_range_next(gib, 0x60800000000ULL, 0x7180000000ULL) == 0x7200000000ULL);
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
    assert(holds == 4 && noted == 3);   /* CEF, CEF_META, the cage and ELF_META2 */
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) {
        if (views[k].size) {
            assert(ppsc_owner[k] == &pebs[0] && !(ppsc_held & PPSC_BIT(k)));
        } else {
            assert(!ppsc_owner[k] && (ppsc_held & PPSC_BIT(k)));
        }
    }
    assert(!memcmp(before, views, sizeof views)); /* not moved, emptied or retagged */
    assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, ppsc_held, 0, PPSC_BIT(PPSC_ELF) | PPSC_BIT(PPSC_ELF_META) |
                         PPSC_BIT(PPSC_OILPAN)) == PPSC_REFUSE);
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
    assert(ppsc_classify(0x800000000ULL, 0x1000000000ULL, ppsc_held, 0, PPSC_BIT(PPSC_ELF)) == PPSC_REFUSE);

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

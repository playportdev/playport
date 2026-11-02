# SPDX-License-Identifier: GPL-3.0-or-later
"""Social Club VM router, free and access checks against the shipped headers.

The headers are extracted from the patches at run time (created by 0224 and
0226, then changed by LATER's hunks) and compiled against a small fake of the
ntdll view table, native holds and process identity. 0231's teardown call is
replayed by teardown_views below.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]   # tools/tests/ -> repository root
UNIX = ROOT / 'patches/madeira-unix'
HEADERS = [('0224-ntdll-social-club-layout-geometry.patch', 'pp_sc_layout.h'),
           ('0226-ntdll-route-social-club-helper-reservations.patch', 'pp_sc_owner.h'),
           ('0226-ntdll-route-social-club-helper-reservations.patch', 'pp_sc_vm.h'),
           ('0226-ntdll-route-social-club-helper-reservations.patch', 'pp_sc_access.h')]
LATER = ['0228-ntdll-second-social-club-elf-metadata-slot.patch',
         '0231-ntdll-hold-a-dead-owner-s-Social-Club-slot-in-place-.patch',
         '0236-ntdll-refuse-the-Social-Club-helper-s-impossible-V8-.patch',
         '0243-ntdll-place-the-Social-Club-helper-s-V8-code-range-o.patch']


def header(patch, name):
    section = patch.read_text().split(f'diff --git a/build/ntdll-unix/{name}', 1)[1]
    section = section.split('diff --git ', 1)[0]
    return '\n'.join(line[1:] for line in section.splitlines()
                     if line.startswith('+') and not line.startswith('+++')) + '\n'


def series_headers(d, headers, later):
    """Write each header as the series leaves it, under d/build/ntdll-unix."""
    unix = d / 'build/ntdll-unix'
    unix.mkdir(parents=True)
    for patch, name in headers:
        (unix / name).write_text(header(UNIX / patch, name))
    # d is inside this repository's .work: keep git apply from treating it as one.
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(d.parent))
    include = [f'--include=build/ntdll-unix/{name}' for _, name in headers]
    for patch in later:
        subprocess.run(['git', 'apply', *include, str(UNIX / patch)], cwd=d, env=env, check=True)
    return unix


PRELUDE = r'''
#include <assert.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "pp_sc_layout.h"

typedef uint16_t WCHAR;
typedef size_t SIZE_T;
typedef uintptr_t ULONG_PTR;
typedef unsigned ULONG;
typedef int NTSTATUS;
typedef struct { struct { WCHAR *Buffer; size_t Length; } ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_NO_MEMORY ((NTSTATUS)0xC0000017u)
#define STATUS_UNABLE_TO_FREE_VM ((NTSTATUS)0xC000001Au)
#define STATUS_CONFLICTING_ADDRESSES ((NTSTATUS)0xC0000018u)
#define STATUS_ACCESS_DENIED ((NTSTATUS)0xC0000022u)
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define MEM_DECOMMIT 0x4000
#define MEM_RELEASE 0x8000
#define PAGE_NOACCESS 0x01
#define PAGE_READWRITE 0x04
#define KERN_SUCCESS 0

/* The current process: pebs[0], [1] and [3] are SocialClubHelper.exe, [2] a game. */
static PEB pebs[4];
static RTL_USER_PROCESS_PARAMETERS params[4];
static WCHAR helper_path[] = u"C:\\Program Files\\Rockstar\\Social Club\\SocialClubHelper.EXE";
static WCHAR game_path[] = u"C:\\Games\\RDR2.exe";
static PEB *cur;
static void *ios_jit_current_peb(void) { return cur; }

static int virtual_mutex, mutex_depth;
static void server_enter_uninterrupted_section(int *m, sigset_t *s) { (void)m; (void)s; mutex_depth++; }
static void server_leave_uninterrupted_section(int *m, sigset_t *s) { (void)m; (void)s; mutex_depth--; assert(mutex_depth >= 0); }

static int dprintf_calls;
static char last_msg[512];
static char all_msgs[65536];
__attribute__((format(printf, 2, 3)))
static int ppsc_test_dprintf(int fd, const char *fmt, ...)
{
    va_list ap;
    (void)fd;
    va_start(ap, fmt);
    vsnprintf(last_msg, sizeof last_msg, fmt, ap);
    va_end(ap);
    dprintf_calls++;
    strncat(all_msgs, last_msg, sizeof all_msgs - strlen(all_msgs) - 1);
    return 0;
}
#define dprintf ppsc_test_dprintf

/* Boot state the real code gets from pp_sc_boot.h. */
static unsigned ppsc_held;
static int ppsc_ready;

/* Wine's reserved areas and the per-page protection of one view. */
typedef unsigned char BYTE;
#define VPROT_COMMITTED 0x02
struct reserved_area { void *base; size_t size; int entry; };
static struct reserved_area reserved_areas[4];
static int reserved_count;
#define LIST_FOR_EACH_ENTRY(e, list, type, field) \
    for ((e) = (type *)(list); (e) < (type *)(list) + reserved_count; (e)++)
static uintptr_t vprot_base;
static BYTE vprot_pages[0x100000];       /* one byte per page from vprot_base, then none */
static BYTE vprot_at(size_t page) { return page < sizeof vprot_pages ? vprot_pages[page] : 0; }
static SIZE_T get_vprot_range_size(char *base, SIZE_T size, BYTE mask, BYTE *vprot)
{
    size_t page = ((uintptr_t)base - vprot_base) / 0x1000, n = 0;
    BYTE first = vprot_at(page) & mask;
    while (n < size && vprot_at(page + n / 0x1000) == vprot_at(page)) n += 0x1000;
    *vprot = first;
    return n < size ? n : size;
}

#define VPROT_SYSTEM 0x0200
struct file_view { void *base; size_t size; void *ios_owner_peb; unsigned protect; };
#define MAXV 16
static struct file_view views[MAXV];
static struct file_view *find_view(const void *addr, size_t size)
{
    (void)size;
    for (int i = 0; i < MAXV; i++)
        if (views[i].size && (uintptr_t)addr >= (uintptr_t)views[i].base &&
            (uintptr_t)addr - (uintptr_t)views[i].base < views[i].size) return &views[i];
    return NULL;
}
static int overlaps_view(uint64_t base, uint64_t size)
{
    for (int i = 0; i < MAXV; i++)
        if (views[i].size && base < (uintptr_t)views[i].base + views[i].size && base + size > (uintptr_t)views[i].base) return 1;
    return 0;
}
static struct file_view *add_view(uint64_t base, uint64_t size, void *owner)
{
    for (int i = 0; i < MAXV; i++) if (!views[i].size) {
        views[i] = (struct file_view){(void *)(uintptr_t)base, size, owner, 0};
        return &views[i];
    }
    assert(0);
    return NULL;
}
static void *views_first_owner(void) { for (int i = 0; i < MAXV; i++) if (views[i].size) return views[i].ios_owner_peb; return NULL; }
static int view_count(void) { int n = 0; for (int i = 0; i < MAXV; i++) n += views[i].size != 0; return n; }

/* Fake native holds: one flag per slot, as the boot's PROT_NONE mappings. */
static int native_held[PPSC_LAST_SLOT + 1];
static int foreign_mapping;     /* a foreign mapping appeared: native holds fail */
static int dealloc_fail, dealloc_calls, hold_calls;
static int mach_task_self(void) { return 1; }
static int slot_at(uint64_t base)
{
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) if (ppsc_range(k).base == base) return k;
    return 0;
}
static int mach_vm_deallocate(int task, uint64_t a, uint64_t size)
{
    int k = slot_at(a);
    (void)task; (void)size;
    dealloc_calls++;
    if (dealloc_fail || !k || !native_held[k]) return 1;
    native_held[k] = 0;
    return KERN_SUCCESS;
}
static int ppsc_native_hold(uint64_t base, uint64_t size)
{
    int k = slot_at(base);
    hold_calls++;
    assert(k && size == ppsc_range(k).size);
    if (foreign_mapping || overlaps_view(base, size)) return 0;
    native_held[k] = 1;
    return 1;
}

/* 0231's hold mapped over a live view: the view must still be there (the range
 * was never unmapped first). */
static int hold_over_fail, hold_over_calls;
static int ppsc_native_hold_over(uint64_t base, uint64_t size)
{
    int k = slot_at(base);
    hold_over_calls++;
    assert(k && size == ppsc_range(k).size && !native_held[k]);
    assert(find_view((void *)(uintptr_t)base, 0));
    if (hold_over_fail) return 0;
    native_held[k] = 1;
    return 1;
}
/* Wine's delete_view: it unmaps unless VPROT_SYSTEM. An unmapped slot range is
 * taken by a native mapping when intruder_on_unmap is set (l8's kind 2). */
static int delete_calls, unmap_calls, intruder_on_unmap;
static void unmap_range(uint64_t base)
{
    unmap_calls++;
    if (intruder_on_unmap && slot_at(base)) foreign_mapping = 1;
}
static void delete_view(struct file_view *v)
{
    delete_calls++;
    if (!(v->protect & VPROT_SYSTEM)) unmap_range((uintptr_t)v->base);
    memset(v, 0, sizeof *v);
}
static int alias_release_calls;
static void ios_jit_anon_alias_release(const void *base, size_t size) { (void)base; (void)size; alias_release_calls++; }

/* Fake allocator: a fixed reserve inside a slot; options inject failures. */
static int alloc_calls, alloc_fail, alloc_mismatch, mismatch_foreign_owner, free_fail;
static ULONG last_protect;
static NTSTATUS allocate_virtual_memory(void **ret, SIZE_T *size, ULONG type, ULONG protect,
                                        ULONG_PTR a, ULONG_PTR b, ULONG_PTR c, ULONG_PTR d)
{
    int k = slot_at((uintptr_t)*ret);
    (void)a; (void)b; (void)c; (void)d;
    alloc_calls++;
    last_protect = protect;
    assert(type == MEM_RESERVE && k);
    assert(!native_held[k]); /* the hold must be dropped before the real map */
    if (alloc_fail || overlaps_view((uintptr_t)*ret, *size)) return STATUS_NO_MEMORY;
    if (alloc_mismatch) *size = ppsc_range(k).size / 2;
    add_view((uintptr_t)*ret, *size, mismatch_foreign_owner ? (void *)&pebs[1] : cur);
    return STATUS_SUCCESS;
}
static int free_calls;
static NTSTATUS free_pages(struct file_view *v, void *base, size_t size)
{
    free_calls++;
    assert(v->base == base && v->size == size);
    if (free_fail) return STATUS_ACCESS_DENIED;
    unmap_range((uintptr_t)v->base);
    memset(v, 0, sizeof *v);
    return STATUS_SUCCESS;
}

#include "pp_sc_owner.h"
#include "pp_sc_vm.h"
#include "pp_sc_access.h"

#define GiB(n) ((uint64_t)(n) << 30)
static void reset(void)
{
    memset(views, 0, sizeof views);
    memset(ppsc_owner, 0, sizeof ppsc_owner);
    memset(ppsc_probe_peb, 0, sizeof ppsc_probe_peb);
    memset(ppsc_probe_count, 0, sizeof ppsc_probe_count);
    memset(all_msgs, 0, sizeof all_msgs);
    params[0].ImagePathName.Buffer = params[1].ImagePathName.Buffer = params[3].ImagePathName.Buffer = helper_path;
    params[0].ImagePathName.Length = params[1].ImagePathName.Length = params[3].ImagePathName.Length =
        sizeof helper_path - sizeof(WCHAR);
    params[2].ImagePathName.Buffer = game_path;
    params[2].ImagePathName.Length = sizeof game_path - sizeof(WCHAR);
    for (int i = 0; i < 4; i++) pebs[i].ProcessParameters = &params[i];
    cur = &pebs[0];
    ppsc_ready = 1;
    reserved_count = 0;
    memset(vprot_pages, 0, sizeof vprot_pages);
    ppsc_held = 0;
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++) { ppsc_held |= PPSC_BIT(k); native_held[k] = 1; }
    foreign_mapping = dealloc_fail = alloc_fail = alloc_mismatch = mismatch_foreign_owner = free_fail = 0;
    alloc_calls = dealloc_calls = hold_calls = free_calls = dprintf_calls = 0;
    hold_over_fail = hold_over_calls = delete_calls = unmap_calls = intruder_on_unmap = alias_release_calls = 0;
    mutex_depth = 0;
}
/* The slot bookkeeping and the fake native holds must always agree. */
static void check_holds(void)
{
    assert(mutex_depth == 0);
    for (int k = PPSC_ELF; k <= PPSC_LAST_SLOT; k++)
        assert(!!(ppsc_held & PPSC_BIT(k)) == !!native_held[k]);
}
/* Run one reserve through the router; returns routed flag. */
static int reserve(uint64_t hint, uint64_t size, ULONG type, ULONG prot, int ext, NTSTATUS *st, void **out, SIZE_T *outsize)
{
    void *ret = (void *)(uintptr_t)hint;
    SIZE_T sz = size;
    int routed;
    *st = 0x12345;
    routed = ppsc_route(&ret, &sz, type, prot, 0, ext, st);
    *out = ret; *outsize = sz;
    return routed;
}
static void grant_ok(uint64_t hint, uint64_t size, int ext, enum ppsc_slot k)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    struct ppsc_range r = ppsc_range(k);
    assert(reserve(hint, size, MEM_RESERVE, PAGE_NOACCESS, ext, &st, &ret, &sz));
    assert(st == STATUS_SUCCESS);
    assert((uint64_t)(uintptr_t)ret == r.report && sz == size);
    struct file_view *v = find_view((void *)(uintptr_t)r.base, 0);
    assert(v && (uint64_t)(uintptr_t)v->base == r.base && v->size == r.size && v->ios_owner_peb == cur);
    assert(ppsc_owner[k] == cur && !(ppsc_held & PPSC_BIT(k)));
    check_holds();
}
static const enum ppsc_slot seq[] = {PPSC_ELF, PPSC_ELF_META, PPSC_CEF, PPSC_CEF_META, PPSC_OILPAN};
static int count_msg(const char *needle)
{
    int n = 0;
    for (const char *p = all_msgs; (p = strstr(p, needle)); p += strlen(needle)) n++;
    return n;
}
static void grant_sequence(void)
{
    for (unsigned i = 0; i < 5; i++) {
        enum ppsc_slot k = seq[i];
        int meta = k == PPSC_ELF_META || k == PPSC_CEF_META;
        grant_ok(meta ? 0x12340000ULL : GiB(64), ppsc_range(k).asked, 0, k);
    }
}

'''

CASES = r'''
static void t_route_not_routed(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    reset(); cur = &pebs[2];                                 /* not the helper */
    assert(!reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));
    assert(!alloc_calls && !dealloc_calls && st == 0x12345);
    reset(); cur = NULL;                                     /* no process at all */
    assert(!reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));
    reset(); ppsc_ready = 0;                                 /* layout not on: not even a name check */
    assert(!reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));
    assert(!alloc_calls && !dealloc_calls && !dprintf_calls && st == 0x12345);
    reset();                                                 /* helper, but not reserve-only */
    assert(!reserve(GiB(64), GiB(32), MEM_RESERVE | MEM_COMMIT, PAGE_NOACCESS, 0, &st, &ret, &sz));
    assert(!reserve(0x1000, 0x1000, MEM_COMMIT, PAGE_READWRITE, 0, &st, &ret, &sz));
    {   /* a limit (address restriction) is not ours */
        void *r2 = (void *)(uintptr_t)GiB(64); SIZE_T s2 = GiB(32); NTSTATUS s;
        assert(!ppsc_route(&r2, &s2, MEM_RESERVE, PAGE_NOACCESS, 1, 0, &s));
    }
    /* A helper small ask keeps the ordinary path, even one below the giant threshold. */
    assert(!reserve(0, 0x10000, MEM_RESERVE, PAGE_READWRITE, 0, &st, &ret, &sz));
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_READWRITE, 0, &st, &ret, &sz));
    assert(!reserve(0, PPSC_GAME_SIZE, MEM_RESERVE, PAGE_READWRITE, 0, &st, &ret, &sz));
    assert(!alloc_calls && !dprintf_calls && ppsc_held == (1u << (PPSC_LAST_SLOT + 1)) - 2);
    check_holds();
}

static void t_route_giant_unknown(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    uint64_t sizes[] = {GiB(16), GiB(64), GiB(1024)};
    reset();
    for (unsigned i = 0; i < 3; i++) {
        assert(reserve(0, sizes[i], MEM_RESERVE, PAGE_READWRITE, 0, &st, &ret, &sz));
        assert(st == STATUS_NO_MEMORY);
    }
    /* Known shape with a bad hint is refused as well. */
    assert(reserve(0x1000, GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(reserve(0x1000, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!alloc_calls && !dealloc_calls && !view_count());
    check_holds();
    /* Layout not ready: nothing is routed, so the ordinary path decides. */
    ppsc_ready = 0;
    assert(!reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == 0x12345);
    assert(!reserve(0, GiB(64), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == 0x12345);
    assert(!alloc_calls && !dealloc_calls);
}

static void t_route_sequence(void)
{
    reset();
    grant_sequence();
    assert(alloc_calls == 5 && dealloc_calls == 5 && view_count() == 5);
    assert(ppsc_held == (PPSC_BIT(PPSC_CAGE) | PPSC_BIT(PPSC_ELF_META2)));   /* the spare stays held */
    assert(strstr(all_msgs, "grant kind=5") && !strstr(all_msgs, "grant kind=7"));        /* a diagnostic is logged per grant */
}
static void t_route_cage(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    reset();
    /* Without both core pools owned there is no cage, whatever the shape. */
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));     /* ELF only */
    grant_ok(GiB(64), GiB(32), 0, PPSC_CEF);
    assert(alloc_calls == 2 && (ppsc_held & PPSC_BIT(PPSC_CAGE)));
    cur = &pebs[1];                                                                 /* another helper */
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
    assert(alloc_calls == 2 && !ppsc_owner[PPSC_CAGE]);
    cur = &pebs[0];
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_READWRITE, 1, &st, &ret, &sz));    /* not NOACCESS */
    assert(!reserve(0, GiB(4), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));     /* not 8 GiB */
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));     /* not extended */
    assert(alloc_calls == 2);
    grant_ok(0, GiB(8), 1, PPSC_CAGE);
    assert(last_protect == PAGE_NOACCESS);
    /* The cage already taken: its owner's next unhinted 8 GiB is a sandbox probe,
     * refused without a walk (0236); a hinted one keeps the ordinary path. */
    assert(reserve(0, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!reserve(0x8400000000ULL, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
    assert(alloc_calls == 3);
}

static void teardown_views(PEB *peb);
/* 0236: A's l12 V8 sequence (v8-no-gap-fits). Every unhinted ask that cannot
 * fit is refused before allocate_virtual_memory; hinted tries, the cage and
 * the small asks are as before. Two lines per PEB; the cage's exit line counts. */
static void t_route_impossible_probes(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    uint64_t ladder[] = {GiB(512), GiB(256), GiB(128), GiB(64), GiB(32), GiB(16)};
    int calls;
    reset();
    grant_sequence();
    calls = alloc_calls;
    for (unsigned i = 0; i < 6; i++) {
        assert(!reserve(0x1400000000ULL, ladder[i], MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
        assert(reserve(0, ladder[i], MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    }
    assert(alloc_calls == calls && !ppsc_owner[PPSC_CAGE]);
    grant_ok(0, GiB(8), 1, PPSC_CAGE);                                               /* the cage is unaffected */
    calls = alloc_calls;
    assert(!reserve(0x528b00000000ULL, GiB(1), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
    assert(!reserve(0, GiB(1), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));     /* the trusted range */
    for (unsigned i = 0; i < 10; i++) {
        assert(!reserve(0x8400000000ULL + i * GiB(16), GiB(16), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
        assert(reserve(0, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    }
    for (unsigned i = 0; i < 10; i++) {
        assert(reserve(0, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
        assert(reserve(0, GiB(16) - 0x10000, MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    }
    assert(!reserve(0, GiB(4), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));     /* l13's smaller asks */
    assert(!reserve(0, 0x13fff0000ULL, MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
    assert(alloc_calls == calls);
    assert(count_msg("probe refused") == 2 && count_msg("larger than any gap the layout leaves") == 2);
    /* The non-extended entry point: the same rule, so no `refused reserve` line either. */
    cur = &pebs[3];
    assert(reserve(0, GiB(64), MEM_RESERVE, PAGE_READWRITE, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(reserve(0, GiB(16) - 0x10000, MEM_RESERVE, PAGE_READWRITE, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_READWRITE, 0, &st, &ret, &sz));    /* no cage of its own */
    assert(count_msg("probe refused") == 4 && !count_msg("refused reserve") && alloc_calls == calls);
    cur = &pebs[2];                                                                  /* the game: untouched */
    assert(!reserve(0, GiB(64), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
    /* A's exit: 6 + 10 + 20 counted on its cage line. */
    memset(all_msgs, 0, sizeof all_msgs);
    teardown_views(&pebs[0]);
    assert(count_msg("kind=6 slot held in place; 36 impossible probes refused") == 1);
    assert(count_msg("impossible probes refused") == 1);
    teardown_views(&pebs[3]);                                                        /* no cage: its own line */
    assert(count_msg("owner") && count_msg("exited without kind=6; 2 impossible probes refused") == 1);
    check_holds();
}

/* 0243: l16 B's V8 code-range asks (hinted 1 GiB, offsets 0 and 4 GiB) and its
 * padded fallback are never routed, so Wine's hinted retry gets them. Every base
 * that retry tries lies outside every slot's real range, and the helper may commit
 * there; as the guard walk's 0x7100000000-0x7300000000 always did, it lies in
 * kind 2's reported tail, which is noted, not refused. */
static void t_route_code_range(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    uint64_t hints[] = {0x60800000000ULL, 0xbf000000000ULL, 0x4c7d00000000ULL};
    unsigned bases = 0;
    int calls;
    reset();
    cur = &pebs[1];
    grant_sequence();
    grant_ok(0, GiB(8), 1, PPSC_CAGE);
    calls = alloc_calls;
    memset(all_msgs, 0, sizeof all_msgs);
    for (unsigned i = 0; i < 3; i++) {
        assert(!reserve(hints[i], GiB(1), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));
        assert(!reserve(hints[i], GiB(1), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
        for (uint64_t b = 0; (b = ppsc_code_range_next(GiB(1), hints[i], b)); bases++) {
            assert(!ppsc_in_slot(b, GiB(1)));
            assert(ppsc_access((void *)(uintptr_t)b, 0x1000, PPSC_OP_COMMIT));
        }
    }
    assert(bases == 9);
    assert(!reserve(0, 0x13fff0000ULL, MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));
    assert(alloc_calls == calls);
    assert(!count_msg("refused") && !count_msg("probe") && count_msg("in reported tail of kind=2"));
    check_holds();
}

static void t_route_second_helper(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    reset();
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    cur = &pebs[1];
    /* The second helper may not take the first one's remaining slots. */
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(alloc_calls == 1 && view_count() == 1 && ppsc_owner[PPSC_ELF] == &pebs[0]);
    assert(!ppsc_owner[PPSC_CEF] && (ppsc_held & PPSC_BIT(PPSC_CEF)));
    check_holds();
    /* ...and the first one carries on. */
    cur = &pebs[0];
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META);
}

static void t_grant_failures(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    struct ppsc_range r = ppsc_range(PPSC_ELF);
    reset(); dealloc_fail = 1;                        /* the hold cannot be dropped */
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!alloc_calls && !ppsc_owner[PPSC_ELF] && (ppsc_held & PPSC_BIT(PPSC_ELF)));
    check_holds();

    reset(); alloc_fail = 1;                          /* allocate fails: slot is held again */
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(alloc_calls == 1 && hold_calls == 1 && !view_count() && !ppsc_owner[PPSC_ELF]);
    assert(ppsc_held & PPSC_BIT(PPSC_ELF));
    check_holds();

    reset(); alloc_fail = foreign_mapping = 1;        /* ...unless a foreign mapping appeared */
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!(ppsc_held & PPSC_BIT(PPSC_ELF)) && !ppsc_owner[PPSC_ELF]);
    check_holds();
    /* A slot with no hold left is never granted. */
    foreign_mapping = alloc_fail = 0; alloc_calls = dealloc_calls = 0;
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));
    assert(st == STATUS_NO_MEMORY || ppsc_owner[PPSC_ELF]); /* classify may pick CEF now; never ELF */
    assert(!ppsc_owner[PPSC_ELF]);

    reset(); alloc_mismatch = 1;                      /* our own wrong-shaped view is freed */
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(free_calls == 1 && !view_count() && !ppsc_owner[PPSC_ELF] && (ppsc_held & PPSC_BIT(PPSC_ELF)));
    check_holds();

    reset(); alloc_mismatch = mismatch_foreign_owner = 1;   /* someone else's view is left alone */
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!free_calls && view_count() == 1 && views_first_owner() == &pebs[1]);
    assert(!ppsc_owner[PPSC_ELF] && !(ppsc_held & PPSC_BIT(PPSC_ELF)));
    check_holds();

    reset(); ppsc_owner[PPSC_ELF] = &pebs[0];         /* an owned slot is never granted again */
    ret = (void *)(uintptr_t)r.report; sz = r.asked;
    assert(ppsc_grant(PPSC_ELF, r.asked, &ret, &sz, PAGE_NOACCESS) == STATUS_NO_MEMORY);
    assert(!dealloc_calls && !alloc_calls);
}

static void t_grant_reserved_area(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    struct ppsc_range r = ppsc_range(PPSC_ELF);
    reset();                                          /* a Wine reserved area inside the slot */
    reserved_areas[0] = (struct reserved_area){(void *)(uintptr_t)(r.base + 0x1000), 0x1000, 0};
    reserved_count = 1;
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!dealloc_calls && !alloc_calls && !view_count() && !ppsc_owner[PPSC_ELF]);
    assert((ppsc_held & PPSC_BIT(PPSC_ELF)) && native_held[PPSC_ELF]);   /* the hold is not given back */
    assert(strstr(all_msgs, "slot overlaps a reserved area; not granted, hold kept"));
    check_holds();
    /* An area straddling either edge counts; areas just outside do not. */
    reserved_areas[0] = (struct reserved_area){(void *)(uintptr_t)(r.base - 0x1000), 0x2000, 0};
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    reserved_areas[0] = (struct reserved_area){(void *)(uintptr_t)(r.base + r.size - 0x1000), 0x2000, 0};
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!dealloc_calls && !alloc_calls);
    reserved_areas[0] = (struct reserved_area){(void *)(uintptr_t)(r.base - 0x1000), 0x1000, 0};
    reserved_areas[1] = (struct reserved_area){(void *)(uintptr_t)(r.base + r.size), 0x1000, 0};
    reserved_count = 2;
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
}

static void t_grant_intruder(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    struct ppsc_range r = ppsc_range(PPSC_ELF);
    struct file_view *intruder;
    reset();                                          /* something mapped inside the slot meanwhile */
    intruder = add_view(r.base + 0x10000, 0x4000, &pebs[2]);
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(alloc_calls == 1 && view_count() == 1 && !free_calls);
    assert((uint64_t)(uintptr_t)intruder->base == r.base + 0x10000 && intruder->size == 0x4000 &&
           intruder->ios_owner_peb == &pebs[2]);      /* left untouched */
    assert(!ppsc_owner[PPSC_ELF] && !(ppsc_held & PPSC_BIT(PPSC_ELF)));
    assert(strstr(all_msgs, "view not placed") && strstr(all_msgs, "NOT held again"));
    check_holds();
}

static void t_free_whole(void)
{
    NTSTATUS st; void *addr; SIZE_T sz;
    reset(); grant_sequence();
    /* Oilpan shares ELF's reported base and is retired first. */
    addr = (void *)(uintptr_t)ppsc_range(PPSC_ELF).report; sz = 0;
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_SUCCESS);
    assert(sz == ppsc_range(PPSC_OILPAN).asked && !ppsc_owner[PPSC_OILPAN] && ppsc_owner[PPSC_ELF] == &pebs[0]);
    /* 0231: held in place, never unmapped and held again. */
    assert(hold_over_calls == 1 && !free_calls && !unmap_calls && !hold_calls && alias_release_calls == 1);
    assert(strstr(all_msgs, "released kind=5 owner=") && strstr(all_msgs, "slot held in place"));
    assert((ppsc_held & PPSC_BIT(PPSC_OILPAN)) && !find_view((void *)(uintptr_t)ppsc_range(PPSC_OILPAN).base, 0));
    assert(find_view((void *)(uintptr_t)ppsc_range(PPSC_ELF).base, 0));
    check_holds();
    /* ...then the same address frees ELF itself. */
    sz = 0;
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_SUCCESS);
    assert(sz == ppsc_range(PPSC_ELF).asked && !ppsc_owner[PPSC_ELF] && (ppsc_held & PPSC_BIT(PPSC_ELF)));
    check_holds();
    /* Every kind frees at its reported base, and is granted again afterwards. */
    for (unsigned i = 2; i < 4; i++) {
        struct ppsc_range r = ppsc_range(seq[i]);
        addr = (void *)(uintptr_t)r.report; sz = 0;
        assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_SUCCESS && sz == r.asked);
    }
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
}

static void t_free_refusals(void)
{
    NTSTATUS st; void *addr; SIZE_T sz;
    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    addr = (void *)(uintptr_t)ppsc_range(PPSC_ELF).report;
    st = 0x777; sz = 0x1000;                          /* partial release */
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_UNABLE_TO_FREE_VM);
    assert(sz == 0x1000 && ppsc_owner[PPSC_ELF] == &pebs[0] && !free_calls);
    check_holds();
    st = 0x777; sz = GiB(32);                         /* even the full reported size is not "whole" */
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_UNABLE_TO_FREE_VM && !free_calls);
    st = 0x777; sz = 0;                               /* non-release types are not ours */
    assert(!ppsc_free(&addr, &sz, MEM_DECOMMIT, &st) && st == 0x777 && !free_calls);
    cur = &pebs[1]; st = 0x777;                       /* a non-owner is not handled by the layout */
    assert(!ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == 0x777 && !free_calls);
    cur = &pebs[0]; addr = (void *)(uintptr_t)0x1000; /* not a reported base */
    assert(!ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == 0x777);
    addr = (void *)(uintptr_t)(ppsc_range(PPSC_ELF).report + 0x1000);
    assert(!ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == 0x777);
    addr = (void *)(uintptr_t)ppsc_range(PPSC_ELF).report;
    hold_over_fail = 1;                               /* no hold over it: free_pages, then a hold */
    free_fail = 1; sz = 0;                            /* free_pages failing keeps the ledger */
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_ACCESS_DENIED);
    assert(ppsc_owner[PPSC_ELF] == &pebs[0] && sz == 0 && find_view((void *)(uintptr_t)ppsc_range(PPSC_ELF).base, 0));
    free_fail = 0; foreign_mapping = 1; sz = 0;       /* a foreign mapping: freed but not held again */
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_SUCCESS);
    assert(!ppsc_owner[PPSC_ELF] && !(ppsc_held & PPSC_BIT(PPSC_ELF)));
    assert(strstr(all_msgs, "slot not held in place") && strstr(all_msgs, "slot NOT held again"));
    check_holds();
    ppsc_ready = 0;                                   /* layout off: nothing is ours */
    assert(!ppsc_free(&addr, &sz, MEM_RELEASE, &st));
}

/* With no current PEB, owner == NULL equals an unowned slot's ledger entry:
 * ppsc_free must not claim a free slot's reported base. */
static void t_free_null_owner(void)
{
    NTSTATUS st = 0x777; void *addr; SIZE_T sz = 0;
    reset(); cur = NULL;
    addr = (void *)(uintptr_t)ppsc_range(PPSC_ELF).report;
    assert(!ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == 0x777);
}

static void t_access(void)
{
    struct ppsc_range e = ppsc_range(PPSC_ELF);
    void *p;
    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    p = (void *)(uintptr_t)(e.base + 0x1000);
    assert(ppsc_access(p, 0x1000, PPSC_OP_COMMIT));                                         /* owner, inside */
    assert(ppsc_access((void *)(uintptr_t)e.base, 0, PPSC_OP_COMMIT));                      /* size 0 is one byte */
    assert(ppsc_access((void *)(uintptr_t)e.base, e.size, PPSC_OP_COMMIT));                 /* the whole real view */
    assert(ppsc_access((void *)(uintptr_t)(e.base + e.size - 1), 1, PPSC_OP_COMMIT));
    cur = &pebs[1]; assert(!ppsc_access(p, 0x1000, PPSC_OP_COMMIT));                        /* another helper */
    cur = &pebs[2]; assert(!ppsc_access(p, 0x1000, PPSC_OP_COMMIT));                        /* another process */
    cur = NULL;     assert(!ppsc_access(p, 0x1000, PPSC_OP_COMMIT));
    cur = &pebs[0];
    assert(!ppsc_access((void *)(uintptr_t)(e.base + e.size - 0x1000), 0x2000, PPSC_OP_COMMIT)); /* straddles the end */
    assert(!ppsc_access((void *)(uintptr_t)(e.base - 0x1000), 0x2000, PPSC_OP_COMMIT));     /* straddles the start */
    assert(!ppsc_access((void *)(uintptr_t)(e.base + 0x1000), UINT64_MAX, PPSC_OP_COMMIT));   /* overflow of size */
    assert(!ppsc_access((void *)(uintptr_t)(UINT64_MAX - 10), 100, PPSC_OP_COMMIT));          /* overflow of address */
    assert(!ppsc_access((void *)(uintptr_t)UINT64_MAX, 2, PPSC_OP_COMMIT));
    {   /* a slot nobody owns: not even the helper may touch it */
        struct ppsc_range c = ppsc_range(PPSC_CEF);
        assert(!ppsc_access((void *)(uintptr_t)c.base, 0x1000, PPSC_OP_COMMIT));
    }
    assert(ppsc_access((void *)(uintptr_t)0x1000, 0x1000, PPSC_OP_COMMIT));                 /* outside all slots */
    assert(ppsc_access((void *)(uintptr_t)(PPSC_GAME_BASE + 0x1000), 0x1000, PPSC_OP_COMMIT));
    cur = &pebs[1];
    assert(ppsc_access((void *)(uintptr_t)0x1000, 0x1000, PPSC_OP_COMMIT));                 /* outside, any process */
    cur = &pebs[0];
    assert(mutex_depth == 0);
    ppsc_ready = 0;                                                         /* layout not ready */
    cur = &pebs[1];
    assert(ppsc_access(p, 0x1000, PPSC_OP_COMMIT) && ppsc_access((void *)(uintptr_t)UINT64_MAX, 2, PPSC_OP_COMMIT));
    ppsc_ready = 1;
    {   /* The reported tail beyond the real range is logged, never refused. */
        struct file_view *v = add_view(0x7900000000ULL, 0x10000, &pebs[1]);
        cur = &pebs[0]; dprintf_calls = 0; memset(all_msgs, 0, sizeof all_msgs);
        assert(ppsc_access((void *)(uintptr_t)0x7900001000ULL, 0x1000, PPSC_OP_COMMIT));
        assert(count_msg("in reported tail of kind=1") == 2 && strstr(all_msgs, "lands on view owned by"));
        v->ios_owner_peb = &pebs[0]; dprintf_calls = 0;      /* our own view: only the commit's tail line */
        assert(ppsc_access((void *)(uintptr_t)0x7900001000ULL, 0x1000, PPSC_OP_COMMIT) && dprintf_calls == 1);
        dprintf_calls = 0;
        assert(ppsc_access((void *)(uintptr_t)0x7900001000ULL, 0x1000, PPSC_OP_PROTECT) && !dprintf_calls);
        assert(ppsc_access((void *)(uintptr_t)0x7900001000ULL, 0x1000, PPSC_OP_FREE) && !dprintf_calls);
    }
}

/* PLA-482 diagnostics only log; each message kind is capped at 16 per slot kind. */
static void t_reported_tail(void)
{
    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF); grant_ok(GiB(64), GiB(32), 0, PPSC_CEF);
    memset(all_msgs, 0, sizeof all_msgs);
    for (int i = 0; i < 17; i++) {                    /* ELF's reported tail, beyond its real range */
        assert(ppsc_access((void *)(uintptr_t)(0x7900001000ULL + i * 0x1000), 0x1000, PPSC_OP_COMMIT));
        assert(count_msg("in reported tail of kind=1") == (i < 16 ? i + 1 : 16));
    }
    assert(count_msg("in reported tail of kind=2") == 0);
    assert(ppsc_access((void *)(uintptr_t)0x7700000000ULL, 0x1000, PPSC_OP_COMMIT));   /* CEF's, another kind */
    assert(count_msg("in reported tail of kind=2") == 1 && count_msg("in reported tail of kind=1") == 16);
    assert(strstr(all_msgs, ": view owner=") && !strstr(all_msgs, "real slot kind="));
    assert(!count_msg("refused"));
    check_holds();
}

static void t_reported_oilpan_low(void)
{
    reset(); grant_sequence();
    memset(all_msgs, 0, sizeof all_msgs);
    for (int i = 0; i < 17; i++) {                    /* lower half of Oilpan's report, in ELF's real range */
        assert(ppsc_access((void *)(uintptr_t)(0x7800001000ULL + i * 0x1000), 0x1000, PPSC_OP_COMMIT));
        assert(count_msg("in Oilpan's reported lower half") == (i < 16 ? i + 1 : 16));
    }
    assert(strstr(all_msgs, "(real slot kind=1)") && !count_msg("refused"));
    memset(all_msgs, 0, sizeof all_msgs);             /* only commits are noted that way */
    assert(ppsc_access((void *)(uintptr_t)0x7800001000ULL, 0x1000, PPSC_OP_PROTECT));
    assert(!count_msg("lower half"));
}

static void t_reported_cross_slot(void)
{
    reset(); grant_sequence();
    memset(all_msgs, 0, sizeof all_msgs);
    for (int i = 0; i < 17; i++) {   /* kind 3's report covers kind 4's real range, both owned by us */
        assert(ppsc_access((void *)(uintptr_t)(0x7590001000ULL + i * 0x1000), 0x1000, PPSC_OP_COMMIT));
        assert(count_msg("in reported extent of kind=3 ") == (i < 16 ? i + 1 : 16));
    }
    /* Kind 3 is metadata, so past its real end that is possible overflow;
     * kind 2's report covers it too, and kind 2 is not metadata. */
    assert(count_msg("possible metadata overflow into kind=4") == 16);
    assert(count_msg("in reported extent of kind=3 off=") == 16 && count_msg("past its real end") == 16);
    assert(count_msg("lands in its own kind=4 real range") == 16);
    assert(!count_msg("refused") && !count_msg("reported tail"));
    cur = &pebs[1];                                   /* not ours: refused, not noted */
    memset(all_msgs, 0, sizeof all_msgs);
    assert(!ppsc_access((void *)(uintptr_t)0x7590001000ULL, 0x1000, PPSC_OP_COMMIT));
    assert(count_msg("refused") == 1 && !count_msg("reported extent"));
}

static void t_owner_died(void)
{
    struct ppsc_range r;
    reset(); grant_sequence();
    /* Teardown removed every view: all five slots are held again and free. */
    memset(views, 0, sizeof views);
    ppsc_owner_died_locked(&pebs[1]);                  /* not the owner: nothing happens */
    assert(!hold_calls);
    ppsc_owner_died_locked(NULL);
    assert(!hold_calls);
    ppsc_owner_died_locked(&pebs[0]);
    assert(hold_calls == 5);
    for (int k = PPSC_ELF; k <= PPSC_OILPAN; k++) assert(!ppsc_owner[k] && (ppsc_held & PPSC_BIT(k)));
    check_holds();
    cur = &pebs[1];                                   /* a new helper can now own the slots */
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    ppsc_owner_died_locked(&pebs[0]);                 /* ...and the old one's exit cannot take them */
    assert(ppsc_owner[PPSC_ELF] == &pebs[1]);

    {   /* A grant whose view survives teardown stays owned; the note counts committed pages. */
        struct ppsc_range e = ppsc_range(PPSC_ELF);
        char want[256];
        reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
        vprot_base = e.base;
        for (int i = 0; i < 16; i++) vprot_pages[i] = VPROT_COMMITTED | 4;
        for (int i = 100; i < 104; i++) vprot_pages[i] = VPROT_COMMITTED | 4;
        memset(all_msgs, 0, sizeof all_msgs);
        ppsc_owner_died_locked(&pebs[0]);
        assert(!hold_calls && ppsc_owner[PPSC_ELF] == &pebs[0] && view_count() == 1);
        snprintf(want, sizeof want, "kind=1 view kept (view %p+0x%llx owner=%p)", (void *)(uintptr_t)e.base,
                 (unsigned long long)e.size, (void *)&pebs[0]);
        assert(strstr(all_msgs, want));
        assert(strstr(all_msgs, "kind=1 committed runs=2 bytes=0x14000 highest_end_off=0x68000"));
        assert(!(ppsc_held & PPSC_BIT(PPSC_ELF)));
        memset(vprot_pages, 0, sizeof vprot_pages);   /* nothing committed: zeros */
        memset(all_msgs, 0, sizeof all_msgs);
        ppsc_owner_died_locked(&pebs[0]);
        assert(strstr(all_msgs, "committed runs=0 bytes=0x0 highest_end_off=0x0"));
    }

    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);   /* a mapping appeared while it ran */
    memset(views, 0, sizeof views); foreign_mapping = 1;
    ppsc_owner_died_locked(&pebs[0]);
    assert(!ppsc_owner[PPSC_ELF] && !(ppsc_held & PPSC_BIT(PPSC_ELF)));
    check_holds();
    cur = &pebs[1];
    {   NTSTATUS st; void *ret; SIZE_T sz;             /* a slot with no hold is not granted */
        assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz));
        assert(!ppsc_owner[PPSC_ELF]);
    }

    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    ppsc_ready = 0; hold_calls = 0;                    /* layout not ready: teardown is a no-op */
    ppsc_owner_died_locked(&pebs[0]);
    assert(!hold_calls && ppsc_owner[PPSC_ELF] == &pebs[0]);
    ppsc_ready = 1;
    r = ppsc_range(PPSC_ELF);
    assert(ppsc_in_slot((uintptr_t)r.base, 0x1000) && !ppsc_in_slot(0x1000, 0x1000));
    ppsc_ready = 0; assert(!ppsc_in_slot((uintptr_t)r.base, 0x1000));
}

/* 0231: the teardown loop in virtual_ios.c, for each view a dead peb frees:
 * the slot hook first, else delete_view; then the ledger. */
static void teardown_views(PEB *peb)
{
    for (int i = 0; i < MAXV; i++)
        if (views[i].size && views[i].ios_owner_peb == peb && !ppsc_owner_view_freed_locked(peb, &views[i]))
            delete_view(&views[i]);
    ppsc_owner_died_locked(peb);
}

static void t_owner_held_in_place(void)
{
    struct file_view *other;
    reset(); grant_sequence();
    other = add_view(0x10000000ULL, 0x100000, cur);       /* a non-slot view of the same owner */
    intruder_on_unmap = 1;                                /* l8: a native mapping takes any unmapped slot */
    memset(all_msgs, 0, sizeof all_msgs);
    teardown_views(&pebs[0]);
    assert(hold_over_calls == 5 && !hold_calls);          /* held in place, never re-held after */
    assert(delete_calls == 6 && unmap_calls == 1 && !foreign_mapping);   /* only the non-slot view unmapped */
    assert(!other->size && !view_count());
    assert(count_msg("slot held in place") == 5 && !count_msg("NOT held") && !count_msg("held again"));
    for (int k = PPSC_ELF; k <= PPSC_OILPAN; k++) assert(!ppsc_owner[k] && (ppsc_held & PPSC_BIT(k)));
    check_holds();
    cur = &pebs[1];                                       /* a second helper gets the same kinds */
    grant_sequence();
    for (int k = PPSC_ELF; k <= PPSC_OILPAN; k++) assert(ppsc_owner[k] == &pebs[1]);

    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);     /* a view that is not a whole slot view */
    {
        struct file_view *v = find_view((void *)(uintptr_t)ppsc_range(PPSC_ELF).base, 0);
        v->size /= 2;
        assert(!ppsc_owner_view_freed_locked(&pebs[0], v) && v->size && !hold_over_calls);
        v->size *= 2;
        assert(!ppsc_owner_view_freed_locked(&pebs[1], v) && v->size && !hold_over_calls);   /* not the owner */
        ppsc_ready = 0;
        assert(!ppsc_owner_view_freed_locked(&pebs[0], v) && v->size && !hold_over_calls);
        ppsc_ready = 1;
    }
    other = add_view(0x10000000ULL, 0x100000, cur); dprintf_calls = 0;
    assert(!ppsc_owner_view_freed_locked(&pebs[0], other) && other->size && !other->protect);
    assert(!hold_over_calls && ppsc_owner[PPSC_ELF] == &pebs[0] && !dprintf_calls);

    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);     /* no hold over it: freed, then held again */
    hold_over_fail = 1; memset(all_msgs, 0, sizeof all_msgs);
    teardown_views(&pebs[0]);
    assert(hold_over_calls == 1 && unmap_calls == 1 && hold_calls == 1);
    assert(strstr(all_msgs, "kind=1 slot not held in place") && strstr(all_msgs, "kind=1 slot held again"));
    assert(!ppsc_owner[PPSC_ELF] && (ppsc_held & PPSC_BIT(PPSC_ELF)));
    check_holds();
    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);     /* ...and NOT held when something took it */
    hold_over_fail = intruder_on_unmap = 1; memset(all_msgs, 0, sizeof all_msgs);
    teardown_views(&pebs[0]);
    assert(strstr(all_msgs, "kind=1 slot NOT held again (something mapped it)"));
    assert(!ppsc_owner[PPSC_ELF] && !(ppsc_held & PPSC_BIT(PPSC_ELF)));
    check_holds();
}

/* PLA-476 second chrome_elf metadata slot (0228). */
#define ALL_SLOTS ((1u << (PPSC_LAST_SLOT + 1)) - 2)
static void grant_all(void) { grant_sequence(); grant_ok(0, GiB(8), 1, PPSC_CAGE); }
/* What teardown leaves: every view of peb gone but kind keep's, then the slot ledger. */
static void exit_keeping(PEB *peb, int keep)
{
    for (int i = 0; i < MAXV; i++)
        if (views[i].size && views[i].ios_owner_peb == peb &&
            !(keep && (uintptr_t)views[i].base == ppsc_range(keep).base)) memset(&views[i], 0, sizeof views[i]);
    if (keep) vprot_base = ppsc_range(keep).base;
    ppsc_owner_died_locked(peb);
}
/* Helper A takes every kind but the spare, then dies with its ELF metadata
 * kept (l3-l5); helper B starts. */
static void a_died_metadata_kept(void)
{
    reset(); grant_all();
    assert(ppsc_held == PPSC_BIT(PPSC_ELF_META2));
    exit_keeping(&pebs[0], PPSC_ELF_META);
    assert(ppsc_owner[PPSC_ELF_META] == &pebs[0] && ppsc_held == (ALL_SLOTS & ~PPSC_BIT(PPSC_ELF_META)));
    check_holds();
    cur = &pebs[1];
}

static void t_meta2_second_helper(void)
{
    NTSTATUS st; void *ret; SIZE_T sz;
    a_died_metadata_kept();
    memset(all_msgs, 0, sizeof all_msgs);
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);
    assert(strstr(all_msgs, "grant kind=7 ") &&
           strstr(all_msgs, "report=0x79c0000000+0x400000000 real=0x79c0000000+0x40000000"));
    grant_ok(GiB(64), GiB(32), 0, PPSC_CEF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_CEF_META);
    grant_ok(GiB(64), GiB(32), 0, PPSC_OILPAN);
    grant_ok(0, GiB(8), 1, PPSC_CAGE);
    assert(ppsc_mine(&pebs[1]) == (ALL_SLOTS & ~PPSC_BIT(PPSC_ELF_META)) && !ppsc_held);
    assert(ppsc_owner[PPSC_ELF_META] == &pebs[0]);
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!ppsc_access((void *)(uintptr_t)0x7400001000ULL, 0x1000, PPSC_OP_COMMIT));   /* A's kept view */
    assert(strstr(all_msgs, "refused reserve") && strstr(all_msgs, "kind=8 "));       /* PPSC_REFUSE is 8 */

    /* Helper C, while B lives and A's metadata is kept, gets nothing. */
    cur = &pebs[3]; alloc_calls = 0;
    assert(reserve(GiB(64), GiB(32), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!reserve(0, GiB(8), MEM_RESERVE, PAGE_NOACCESS, 1, &st, &ret, &sz));
    assert(!alloc_calls && !ppsc_mine(&pebs[3]));

    /* B exits and its views are freed: its six slots are held again, A's is not. */
    exit_keeping(&pebs[1], 0);
    assert(ppsc_held == (ALL_SLOTS & ~PPSC_BIT(PPSC_ELF_META)) && !ppsc_mine(&pebs[1]));
    assert(ppsc_owner[PPSC_ELF_META] == &pebs[0]);
    check_holds();
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);                /* C now, as B was */
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);

    /* A's view goes at last: ELF_META is held again but C never gets both. */
    exit_keeping(&pebs[0], 0);
    assert(!ppsc_owner[PPSC_ELF_META] && (ppsc_held & PPSC_BIT(PPSC_ELF_META)));
    check_holds();
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!ppsc_owner[PPSC_ELF_META] && ppsc_owner[PPSC_ELF_META2] == &pebs[3]);
    /* ...and once C is gone the next helper takes ELF_META, not the spare. */
    exit_keeping(&pebs[3], 0);
    cur = &pebs[1];
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META);
    assert(!ppsc_owner[PPSC_ELF_META2] && (ppsc_held & PPSC_BIT(PPSC_ELF_META2)));
}

/* The spare goes only to a helper owning ELF, no ELF metadata, while another
 * PEB owns ELF_META; never to a helper as its second ELF metadata. */
static void t_meta2_only_for_another_owner(void)
{
    NTSTATUS st; void *ret; SIZE_T sz; void *addr;
    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    ppsc_held &= ~PPSC_BIT(PPSC_ELF_META); native_held[PPSC_ELF_META] = 0;   /* not held, nobody owns it */
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!ppsc_owner[PPSC_ELF_META2] && (ppsc_held & PPSC_BIT(PPSC_ELF_META2)) && alloc_calls == 1);

    reset(); grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);              /* A lives, owning ELF and its metadata */
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META);
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(!ppsc_owner[PPSC_ELF_META2]);                           /* never both */
    addr = (void *)(uintptr_t)ppsc_range(PPSC_ELF).report; sz = 0;  /* A gives ELF back, keeps its metadata */
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_SUCCESS);
    cur = &pebs[1];                                                 /* B: ELF, and the spare for metadata */
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    cur = &pebs[0];                                                 /* A owns no ELF now: no metadata */
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(ppsc_owner[PPSC_ELF_META] == &pebs[0] && ppsc_owner[PPSC_ELF_META2] == &pebs[1]);
    check_holds();
}

static void t_meta2_free_and_exit(void)
{
    NTSTATUS st; void *ret, *addr; SIZE_T sz;
    struct ppsc_range m = ppsc_range(PPSC_ELF_META2);
    a_died_metadata_kept();
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);
    addr = (void *)(uintptr_t)m.report; sz = 0;                    /* whole release at its reported base */
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_SUCCESS && sz == GiB(16));
    assert(!ppsc_owner[PPSC_ELF_META2] && (ppsc_held & PPSC_BIT(PPSC_ELF_META2)) && !find_view(addr, 0));
    check_holds();
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);           /* asked again: granted again */
    addr = (void *)(uintptr_t)(m.report + 0x1000); sz = 0;         /* not its base: not the layout's */
    assert(!ppsc_free(&addr, &sz, MEM_RELEASE, &st));
    addr = (void *)(uintptr_t)m.report; sz = 0x1000; st = 0x777;  /* partial: refused */
    assert(ppsc_free(&addr, &sz, MEM_RELEASE, &st) && st == STATUS_UNABLE_TO_FREE_VM);

    memset(all_msgs, 0, sizeof all_msgs);                           /* B dies with the spare's view kept */
    exit_keeping(&pebs[1], PPSC_ELF_META2);
    assert(ppsc_owner[PPSC_ELF_META2] == &pebs[1] && !(ppsc_held & PPSC_BIT(PPSC_ELF_META2)));
    assert(strstr(all_msgs, "kind=7 view kept") && strstr(all_msgs, "kind=1 slot held again"));
    check_holds();
    cur = &pebs[3]; alloc_calls = 0;                                /* C: ELF, but both metadata slots are kept */
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    assert(reserve(0x12340000ULL, GiB(16), MEM_RESERVE, PAGE_NOACCESS, 0, &st, &ret, &sz) && st == STATUS_NO_MEMORY);
    assert(alloc_calls == 1);
    exit_keeping(&pebs[1], 0);                                      /* the spare's view goes: held again */
    assert(!ppsc_owner[PPSC_ELF_META2] && (ppsc_held & PPSC_BIT(PPSC_ELF_META2)));
    check_holds();
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);
}

/* An operation must lie wholly in one owned real range: one straddling two
 * adjacent slots is refused even when the caller owns both. */
static void straddles_refused(uint64_t a, uint64_t n)
{
    assert(!ppsc_access((void *)(uintptr_t)a, n, PPSC_OP_COMMIT));
    assert(!ppsc_access((void *)(uintptr_t)a, n, PPSC_OP_PROTECT));
    assert(!ppsc_access((void *)(uintptr_t)a, n, PPSC_OP_FREE));
    assert(ppsc_access((void *)(uintptr_t)(a + n / 2 - 0x1000), 0x1000, PPSC_OP_COMMIT));   /* each side alone */
    assert(ppsc_access((void *)(uintptr_t)(a + n / 2), 0x1000, PPSC_OP_COMMIT));
}
static void t_access_straddle(void)
{
    reset(); grant_all();                                   /* A owns both sides of each */
    memset(all_msgs, 0, sizeof all_msgs);
    straddles_refused(0x758ffff000ULL, 0x2000);             /* ELF_META | CEF_META */
    straddles_refused(0x7bfffff000ULL, 0x2000);             /* cage | Oilpan */
    assert(count_msg("refused memory operation") == 6);
    a_died_metadata_kept();                                 /* B: the spare and the cage */
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);
    grant_ok(GiB(64), GiB(32), 0, PPSC_CEF);
    grant_ok(0, GiB(8), 1, PPSC_CAGE);
    memset(all_msgs, 0, sizeof all_msgs);
    straddles_refused(0x79ffff0000ULL, 0x20000);            /* ELF_META2 | cage */
    assert(count_msg("refused memory operation") == 3);
    assert(mutex_depth == 0);
}

/* Real-range containment decides; past a metadata kind's real end it is
 * logged as possible overflow, for metadata kinds only, never refused. */
static void t_meta_overflow_note(void)
{
    char want[256];
    a_died_metadata_kept();
    grant_ok(GiB(64), GiB(32), 0, PPSC_ELF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_ELF_META2);
    grant_ok(GiB(64), GiB(32), 0, PPSC_CEF);
    grant_ok(0x12340000ULL, GiB(16), 0, PPSC_CEF_META);
    grant_ok(GiB(64), GiB(32), 0, PPSC_OILPAN);
    grant_ok(0, GiB(8), 1, PPSC_CAGE);
    memset(all_msgs, 0, sizeof all_msgs);
    assert(ppsc_access((void *)(uintptr_t)0x7a00001000ULL, 0x1000, PPSC_OP_COMMIT));   /* cage, past the spare */
    snprintf(want, sizeof want, "helper %p op=0 %p+0x1000 in reported extent of kind=7 off=0x40001000 past its real end: possible metadata overflow into kind=6",
             (void *)&pebs[1], (void *)(uintptr_t)0x7a00001000ULL);
    assert(count_msg(want) == 1 && count_msg("possible metadata overflow") == 1);
    assert(count_msg("in reported extent of kind=1 off=0x200001000 lands in its own kind=6 real range") == 1);
    assert(count_msg("in Oilpan's reported lower half off=0x200001000 (real slot kind=6)") == 1);
    memset(all_msgs, 0, sizeof all_msgs);
    assert(ppsc_access((void *)(uintptr_t)0x7a00001000ULL, 0x1000, PPSC_OP_PROTECT));
    assert(count_msg("possible metadata overflow into kind=6") == 1);
    assert(count_msg("of kind=5 off=0x200001000 lands in its own kind=6") == 1);       /* Oilpan is not metadata */
    memset(all_msgs, 0, sizeof all_msgs);
    assert(ppsc_access((void *)(uintptr_t)0x7c00001000ULL, 0x1000, PPSC_OP_COMMIT));   /* Oilpan, still in the spare's report */
    assert(count_msg("of kind=7 off=0x240001000 past its real end: possible metadata overflow into kind=5") == 1);
    assert(count_msg("possible metadata overflow") == 1);
    memset(all_msgs, 0, sizeof all_msgs);
    assert(ppsc_access((void *)(uintptr_t)0x79c0001000ULL, 0x1000, PPSC_OP_COMMIT));   /* the spare's own range */
    assert(!count_msg("possible metadata overflow") && count_msg("lands in its own kind=7 real range") == 1);
    memset(all_msgs, 0, sizeof all_msgs);
    for (int i = 0; i < 17; i++)                                    /* capped per reported kind */
        assert(ppsc_access((void *)(uintptr_t)(0x7a00100000ULL + i * 0x200000), 0x1000, PPSC_OP_COMMIT));
    assert(count_msg("of kind=7 off=") == 13);                      /* 3 above + 13 = the cap of 16 */
    assert(!count_msg("refused"));
}

/* The same check for a helper that owns no metadata report reaching the cage
 * (its own process: the notes' limits are per run). */
static void t_meta_overflow_core_kinds(void)
{
    reset(); grant_all();
    memset(all_msgs, 0, sizeof all_msgs);
    assert(ppsc_access((void *)(uintptr_t)0x7b00000000ULL, 0x1000, PPSC_OP_PROTECT));
    assert(!count_msg("possible metadata overflow"));
    assert(count_msg("of kind=1 off=0x300000000 lands in its own kind=6") == 1 &&
           count_msg("of kind=5 off=0x300000000 lands in its own kind=6") == 1);
}

static const struct { const char *name; void (*fn)(void); } tests[] = {
    {"route_not_routed", t_route_not_routed}, {"route_giant_unknown", t_route_giant_unknown},
    {"route_sequence", t_route_sequence}, {"route_cage", t_route_cage},
    {"route_impossible_probes", t_route_impossible_probes}, {"route_code_range", t_route_code_range},
    {"route_second_helper", t_route_second_helper}, {"grant_failures", t_grant_failures},
    {"grant_reserved_area", t_grant_reserved_area}, {"grant_intruder", t_grant_intruder},
    {"reported_tail", t_reported_tail}, {"reported_oilpan_low", t_reported_oilpan_low},
    {"reported_cross_slot", t_reported_cross_slot},
    {"free_whole", t_free_whole}, {"free_refusals", t_free_refusals},
    {"free_null_owner", t_free_null_owner}, {"access", t_access}, {"owner_died", t_owner_died},
    {"owner_held_in_place", t_owner_held_in_place},
    {"meta2_second_helper", t_meta2_second_helper}, {"meta2_only_for_another_owner", t_meta2_only_for_another_owner},
    {"meta2_free_and_exit", t_meta2_free_and_exit}, {"access_straddle", t_access_straddle},
    {"meta_overflow_note", t_meta_overflow_note}, {"meta_overflow_core_kinds", t_meta_overflow_core_kinds},
};
int main(int argc, char **argv)
{
    assert(argc == 2);
    for (unsigned i = 0; i < sizeof tests / sizeof *tests; i++)
        if (!strcmp(argv[1], tests[i].name)) { tests[i].fn(); return 0; }
    fprintf(stderr, "no test %s\n", argv[1]);
    return 2;
}
'''


NAMES = ['route_not_routed', 'route_giant_unknown', 'route_sequence', 'route_cage', 'route_impossible_probes', 'route_code_range',
         'route_second_helper', 'grant_failures', 'grant_reserved_area', 'grant_intruder',
         'free_whole', 'free_refusals', 'free_null_owner', 'access', 'reported_tail',
         'reported_oilpan_low', 'reported_cross_slot', 'owner_died', 'owner_held_in_place', 'meta2_second_helper',
         'meta2_only_for_another_owner', 'meta2_free_and_exit', 'access_straddle', 'meta_overflow_note',
         'meta_overflow_core_kinds']


class SocialClubVmTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which('cc')
        assert cc, 'no C compiler'
        scratch = ROOT / '.work/tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        cls.tmp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR', scratch))
        d = series_headers(pathlib.Path(cls.tmp.name), HEADERS, LATER)
        (d / 'test.c').write_text(PRELUDE + CASES)
        subprocess.run([cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined',
                        str(d / 'test.c'), '-o', str(d / 'test')], check=True)
        cls.binary = str(d / 'test')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_case(self, name):
        done = subprocess.run([self.binary, name], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)


for _name in NAMES:
    setattr(SocialClubVmTests, 'test_' + _name, lambda self, _name=_name: self.run_case(_name))

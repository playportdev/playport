/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * guest_pool_test.c — the donor pool's bookkeeping (app/Sources/SharedMemory/guest_pool.c)
 * against a page model: takes and releases (whole, prefix, suffix, middle,
 * across leases), reuse of freed ranges inside an object (best fit, coalesced
 * neighbours, fragmentation, exhaustion), and the purge and reset of an object
 * whose last lease went, some purges deferred and some failing. Checks that
 * every page Wine gets reads zero (never used, purged, or reported stale and
 * zeroed by the caller before Wine sees it), that no pool page backs two guest
 * pages, that a guest page keeps its pool page through splits, that an object
 * awaiting its purge is never handed out, and that the guest page table
 * (madeira-unix 0150's small commits: one entry per guest page) refuses a page
 * leased twice or outside it and handles thousands of one-page leases.
 */
#include "guest_pool.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

enum { PAGE = 16384, OBJS = 4, OBJ_PAGES = 64, GUEST_PAGES = 1024 };
enum { FRESH, LEASED, DIRTY };   /* reads zero; backs a guest page; free with old data */
static unsigned char pool_state[OBJS][OBJ_PAGES];
/* The pool page backing each guest page, -1 for none. */
static int guest_obj[GUEST_PAGES], guest_off[GUEST_PAGES];
/* Objects whose last lease went and whose purge the test has not done yet. */
static int pending[OBJS];
static const uintptr_t BASE = 0x7000000000ull;

static int bit(const uint64_t *bits, unsigned i) { return (int)(bits[i / 64] >> (i % 64)) & 1; }

static void check_model(const struct pp_pool *p)
{
    int seen[OBJS][OBJ_PAGES];
    memset(seen, 0, sizeof seen);
    uint64_t live = 0, stale = 0;
    for (unsigned g = 0; g < GUEST_PAGES; g++) {
        uint32_t object;
        uint64_t offset;
        if (pp_pool_lookup(p, BASE + (uintptr_t)g * PAGE, &object, &offset)) {
            CHECK(guest_obj[g] < 0);
            continue;
        }
        unsigned o = (unsigned)(offset / PAGE);
        CHECK(!(offset % PAGE) && object < OBJS && offset < p->objects[object].size);
        CHECK(guest_obj[g] == (int)object && guest_off[g] == (int)o);
        CHECK(pool_state[object][o] == LEASED);
        CHECK(!seen[object][o]++);
        live += PAGE;
    }
    CHECK(live == p->live);
    for (unsigned o = 0; o < OBJS; o++) {
        const struct pp_pool_object *ob = &p->objects[o];
        uint64_t olive = 0, ostale = 0;
        for (unsigned k = 0; k < OBJ_PAGES; k++) {
            CHECK(bit(ob->leased, k) == (pool_state[o][k] == LEASED));
            CHECK(bit(ob->stale_map, k) == (pool_state[o][k] == DIRTY));
            if (pool_state[o][k] == LEASED) { CHECK(seen[o][k]); olive += PAGE; }
            if (pool_state[o][k] == DIRTY) ostale += PAGE;
        }
        CHECK(olive == ob->live && ostale == ob->stale);
        CHECK(ob->awaiting_purge == pending[o]);
        /* An object with nothing leased and old data awaits its purge, unless it is retired. */
        if (!ob->retired && !ob->live) CHECK(!ob->stale || ob->awaiting_purge);
        stale += ob->stale;
    }
    CHECK(stale == p->stale);
}

/* Takes like GuestPool.m: zero the take's stale runs, then pp_pool_zeroed. Returns the object or -1. */
static int take(struct pp_pool *p, unsigned g, unsigned pages)
{
    for (unsigned k = 0; k < pages; k++) if (guest_obj[g + k] >= 0) return -1;   /* Wine backs only fresh commits */
    uint32_t obj;
    uint64_t off, len = (uint64_t)pages * PAGE;
    if (pp_pool_take(p, BASE + (uintptr_t)g * PAGE, len, &obj, &off)) return -1;
    CHECK(obj < OBJS && !pending[obj] && !p->objects[obj].retired);
    for (uint64_t at = off, run; (run = pp_pool_next_stale(p, obj, &at, off + len)); at += run) {
        CHECK(at >= off && at + run <= off + len);
        for (uint64_t b = at; b < at + run; b += PAGE) {
            CHECK(pool_state[obj][b / PAGE] == DIRTY);
            pool_state[obj][b / PAGE] = FRESH;   /* the caller's memset */
        }
    }
    pp_pool_zeroed(p, obj, off, len);
    for (unsigned k = 0; k < pages; k++) {
        unsigned o = (unsigned)(off / PAGE) + k;
        CHECK(pool_state[obj][o] == FRESH);   /* the zero guarantee */
        pool_state[obj][o] = LEASED;
        guest_obj[g + k] = (int)obj;
        guest_off[g + k] = (int)o;
    }
    return (int)obj;
}

static void purge(struct pp_pool *p, unsigned o, int zeroed)
{
    CHECK(pending[o] && !p->objects[o].live);
    pending[o] = 0;
    if (zeroed) memset(pool_state[o], FRESH, OBJ_PAGES);
    pp_pool_reset(p, o, zeroed);
    CHECK(!p->objects[o].awaiting_purge);
    if (zeroed) CHECK(!p->objects[o].stale);
    else CHECK(p->objects[o].retired);
}

/* Releases like GuestPool.m; defer leaves the emptied objects pending (purged by flush). */
static uint32_t release(struct pp_pool *p, unsigned g, unsigned pages, int detached, int fail, int defer)
{
    uint32_t emptied[PP_POOL_MAX_OBJECTS];
    for (unsigned k = 0; k < pages; k++) {
        if (guest_obj[g + k] < 0) continue;
        pool_state[guest_obj[g + k]][guest_off[g + k]] = DIRTY;
        guest_obj[g + k] = guest_off[g + k] = -1;
    }
    uint32_t n = pp_pool_release(p, BASE + (uintptr_t)g * PAGE, BASE + (uintptr_t)(g + pages) * PAGE, detached, emptied);
    for (uint32_t i = 0; i < n; i++) {
        CHECK(emptied[i] < OBJS && !p->objects[emptied[i]].live && p->objects[emptied[i]].awaiting_purge);
        for (uint32_t j = 0; j < i; j++) CHECK(emptied[j] != emptied[i]);
        CHECK(!pending[emptied[i]]);
        pending[emptied[i]] = 1;
        if (!defer) purge(p, emptied[i], !fail);
    }
    return n;
}

static void flush(struct pp_pool *p)
{
    for (unsigned o = 0; o < OBJS; o++) if (pending[o]) purge(p, o, 1);
}

static uint32_t where[GUEST_PAGES];

static void reset_model(struct pp_pool *p, unsigned objs)
{
    memset(where, 0, sizeof where);
    pp_pool_init(p, PAGE, where, BASE, GUEST_PAGES);
    for (unsigned o = 0; o < objs; o++) CHECK(pp_pool_add(p, (uint64_t)OBJ_PAGES * PAGE) == (int)o);
    memset(pool_state, FRESH, sizeof pool_state);
    memset(pending, 0, sizeof pending);
    for (unsigned g = 0; g < GUEST_PAGES; g++) guest_obj[g] = guest_off[g] = -1;
}

int main(void)
{
    static struct pp_pool p;
    uint32_t obj;
    uint64_t off;

    /* The bounds: the guest window's table on 16 KiB pages, the largest pool, a 256 MiB object. */
    CHECK(pp_pool_map_entries(0x7000000000ull, 0x7c00000000ull, 16384) == 3145728);
    CHECK(pp_pool_map_entries(0x7c00000000ull, 0x7000000000ull, 16384) == 0);
    CHECK((uint64_t)PP_POOL_MAX_OBJECTS * (256ull << 20) == (8ull << 30));
    CHECK((uint64_t)PP_POOL_MAX_OBJECT_PAGES * 16384 == (256ull << 20));

    /* Misaligned, oversize and too-large requests are refused; adds past the limits too. */
    pp_pool_init(&p, PAGE, where, BASE, GUEST_PAGES);
    CHECK(pp_pool_add(&p, PAGE + 1) < 0);
    CHECK(pp_pool_add(&p, (uint64_t)(PP_POOL_MAX_OBJECT_PAGES + 1) * PAGE) < 0);
    reset_model(&p, OBJS);
    CHECK(pp_pool_take(&p, BASE + 1, PAGE, &obj, &off) < 0);
    CHECK(pp_pool_take(&p, BASE, PAGE + 1, &obj, &off) < 0);
    CHECK(pp_pool_take(&p, BASE, (uint64_t)(OBJ_PAGES + 1) * PAGE, &obj, &off) < 0);
    CHECK(p.refused == 3 && !p.live);
    /* Outside the guest page table, or a guest page already leased: refused, nothing changes. */
    CHECK(pp_pool_take(&p, BASE - PAGE, PAGE, &obj, &off) < 0);
    CHECK(pp_pool_take(&p, BASE + (GUEST_PAGES - 1) * (uintptr_t)PAGE, 2 * PAGE, &obj, &off) < 0);
    CHECK(take(&p, 900, 4) == 0);
    CHECK(pp_pool_take(&p, BASE + 902 * (uintptr_t)PAGE, 4 * PAGE, &obj, &off) < 0);
    CHECK(p.refused == 6 && p.live == 4ull * PAGE);
    CHECK(!pp_pool_lookup(&p, BASE + 901 * (uintptr_t)PAGE + 100, &obj, &off) && obj == 0 && off == PAGE + 100);
    CHECK(pp_pool_lookup(&p, BASE + 904 * (uintptr_t)PAGE, &obj, &off) < 0);
    CHECK(pp_pool_lookup(&p, BASE - 1, &obj, &off) < 0);
    check_model(&p);
    /* A release reaching past the table counts its outside bytes as unmatched. */
    {
        uint32_t emptied[PP_POOL_MAX_OBJECTS];
        for (unsigned k = 900; k < 904; k++) { pool_state[0][k - 900] = DIRTY; guest_obj[k] = guest_off[k] = -1; }
        CHECK(pp_pool_release(&p, BASE + 900 * (uintptr_t)PAGE, BASE + (GUEST_PAGES + 8) * (uintptr_t)PAGE, 0, emptied) == 1);
        CHECK(p.released_bytes == 4ull * PAGE && p.unmatched_bytes == (uint64_t)(GUEST_PAGES + 8 - 904) * PAGE);
        pending[0] = 1;
        purge(&p, 0, 1);
        check_model(&p);
    }
    reset_model(&p, OBJS);

    /* untake gives the space back as it was, stale pages included. */
    take(&p, 0, 8);
    take(&p, 8, 8);
    release(&p, 0, 8, 0, 0, 0);
    CHECK(!pp_pool_take(&p, BASE + 64 * PAGE, 8 * PAGE, &obj, &off) && obj == 0 && off == 0);
    CHECK(p.reuses == 1 && p.zeroed_bytes == 8ull * PAGE && p.objects[0].stale == 0);
    pp_pool_untake(&p, BASE + 64 * PAGE, 8 * PAGE);
    CHECK(p.reuses == 0 && !p.zeroed_bytes && p.objects[0].stale == 8ull * PAGE && p.served == 2);
    check_model(&p);

    /* Reuse with zero on reuse, best fit: a freed range inside an object is handed out
     * again, zeroed, while another part of the object is still leased. */
    reset_model(&p, OBJS);
    take(&p, 0, 32);
    take(&p, 32, 16);
    release(&p, 0, 32, 0, 0, 0);
    CHECK(p.objects[0].live == 16ull * PAGE && p.objects[0].stale == 32ull * PAGE && !p.objects[0].awaiting_purge);
    CHECK(take(&p, 100, 8) == 0 && guest_off[100] == 48);   /* the 16-page tail fits better than the 32-page hole */
    CHECK(take(&p, 200, 32) == 0 && guest_off[200] == 0);   /* the hole, exactly */
    CHECK(p.reuses == 1 && p.zeroed_bytes == 32ull * PAGE && !p.stale);
    check_model(&p);
    release(&p, 32, 16, 1, 0, 0);
    CHECK(p.detaches == 1 && p.detached_bytes == 16ull * PAGE && !p.resets);
    check_model(&p);

    /* Coalescing: two adjacent freed ranges serve one take of their joint size. */
    reset_model(&p, OBJS);
    for (unsigned k = 0; k < 4; k++) take(&p, k * 16, 16);
    release(&p, 16, 16, 0, 0, 0);
    release(&p, 32, 16, 0, 0, 0);
    CHECK(take(&p, 300, 32) == 0 && guest_off[300] == 16);
    CHECK(p.reuses == 1 && p.zeroed_bytes == 32ull * PAGE);
    check_model(&p);

    /* Fragmentation: 32 one-page holes in object 0 serve one-page takes; a two-page
     * take goes to a fresh object, and with no fresh object it is refused. */
    reset_model(&p, 1);
    for (unsigned k = 0; k < OBJ_PAGES; k++) take(&p, k, 1);
    for (unsigned k = 1; k < OBJ_PAGES; k += 2) release(&p, k, 1, 0, 0, 0);
    CHECK(p.objects[0].stale == 32ull * PAGE && p.live == 32ull * PAGE);
    uint64_t refused = p.refused;
    CHECK(take(&p, 500, 2) < 0 && p.refused == refused + 1);
    CHECK(take(&p, 500, 1) == 0 && guest_off[500] == 1);
    check_model(&p);
    reset_model(&p, 2);
    for (unsigned k = 0; k < OBJ_PAGES; k++) take(&p, k, 1);
    for (unsigned k = 1; k < OBJ_PAGES; k += 2) release(&p, k, 1, 0, 0, 0);
    CHECK(take(&p, 500, 2) == 1 && guest_off[500] == 0);
    CHECK(take(&p, 510, 1) == 0 && guest_off[510] == 1);   /* best fit: a hole, not the fresh object */
    check_model(&p);

    /* Exhaustion: a full pool refuses; a freed range serves again, then it is full once more. */
    reset_model(&p, OBJS);
    for (unsigned o = 0; o < OBJS; o++) take(&p, o * OBJ_PAGES, OBJ_PAGES);
    refused = p.refused;
    CHECK(take(&p, 600, 1) < 0 && p.refused == refused + 1);
    release(&p, 2 * OBJ_PAGES + 8, 8, 0, 0, 0);
    CHECK(take(&p, 600, 8) == 2 && guest_off[600] == 8 && p.reuses == 1);
    CHECK(take(&p, 700, 1) < 0);
    check_model(&p);

    /* An emptied object awaits its purge and is not handed out before it; after the purge
     * it serves from offset 0 with nothing stale. */
    reset_model(&p, 1);
    take(&p, 0, 16);
    CHECK(release(&p, 0, 16, 0, 0, 1) == 1 && p.objects[0].awaiting_purge);
    CHECK(take(&p, 100, 4) < 0);
    check_model(&p);
    flush(&p);
    CHECK(p.resets == 1 && !p.stale);
    CHECK(take(&p, 100, 4) == 0 && guest_off[100] == 0 && !p.reuses);
    check_model(&p);
    /* A failed purge retires the object. */
    CHECK(release(&p, 100, 4, 0, 1, 0) == 1 && p.retired == 1);
    CHECK(take(&p, 200, 1) < 0);
    check_model(&p);

    /* Every lease page released one at a time in the middle: splits stay within the bound. */
    reset_model(&p, OBJS);
    for (unsigned o = 0; o < OBJS; o++) take(&p, o * OBJ_PAGES, OBJ_PAGES);
    for (unsigned g = 1; g < OBJS * OBJ_PAGES; g += 2) { release(&p, g, 1, 0, 0, 0); check_model(&p); }
    CHECK(p.live == (uint64_t)OBJS * OBJ_PAGES / 2 * PAGE);
    release(&p, 0, OBJS * OBJ_PAGES, 0, 0, 0);
    CHECK(!p.live && !p.stale && p.resets == OBJS);
    check_model(&p);

    /* Unmatched bytes are counted, nothing else changes. */
    uint64_t unmatched = p.unmatched_bytes;
    CHECK(unmatched == (uint64_t)OBJS * OBJ_PAGES / 2 * PAGE);   /* the pages released before */
    release(&p, 500, 4, 0, 0, 0);
    CHECK(p.unmatched_bytes == unmatched + 4ull * PAGE && !p.live);

    /* Small commits: every page of the pool as its own lease, released in a scattered
     * order and taken again one page at a time, each take an exact fit (a hole). */
    reset_model(&p, OBJS);
    for (unsigned g = 0; g < OBJS * OBJ_PAGES; g++) CHECK(take(&p, g, 1) >= 0);
    CHECK(p.live == (uint64_t)OBJS * OBJ_PAGES * PAGE && take(&p, OBJS * OBJ_PAGES, 1) < 0);
    for (unsigned k = 0; k < OBJS * OBJ_PAGES; k += 1) {
        unsigned g = (k * 37) % (OBJS * OBJ_PAGES);
        if (g % 3 == 0) release(&p, g, 1, 0, 0, 1);
    }
    check_model(&p);
    for (unsigned g = OBJS * OBJ_PAGES; g < GUEST_PAGES && take(&p, g, 1) >= 0; g++) {}
    CHECK(p.live == (uint64_t)OBJS * OBJ_PAGES * PAGE && !p.stale && p.reuses == p.served - OBJS * OBJ_PAGES);
    check_model(&p);

    /* Random: takes of 1-40 pages, releases of any range, purges sometimes deferred to a
     * later call (as GuestPool.m does) and sometimes failing (retire). */
    for (unsigned seed = 1; seed <= 300; seed++) {
        unsigned rng = seed;
        reset_model(&p, OBJS);
#define NEXT (rng = rng * 1664525u + 1013904223u, rng >> 8)
        for (unsigned step = 0; step < 600; step++) {
            unsigned g = NEXT % GUEST_PAGES;
            if (NEXT % 3 == 0) flush(&p);
            if (NEXT % 2) {
                unsigned pages = 1 + NEXT % 40;
                if (g + pages > GUEST_PAGES) pages = GUEST_PAGES - g;
                take(&p, g, pages);
            } else {
                unsigned pages = 1 + NEXT % 120;
                if (g + pages > GUEST_PAGES) pages = GUEST_PAGES - g;
                int detached = NEXT % 4 == 0;
                int fail = seed % 7 == 0 && NEXT % 5 == 0;
                int defer = !fail && NEXT % 2;
                release(&p, g, pages, detached, fail, defer);
            }
            /* Wine never offers a guest page twice: such a take is refused. */
            if (guest_obj[g] >= 0) {
                uint64_t refused_before = p.refused, live = p.live;
                CHECK(pp_pool_take(&p, BASE + (uintptr_t)g * PAGE, PAGE, &obj, &off) < 0);
                CHECK(p.refused == refused_before + 1 && p.live == live);
            }
            check_model(&p);
        }
        CHECK(p.served_bytes == p.live + p.released_bytes);
    }
    if (failures) { printf("%d failures\n", failures); return 1; }
    printf("guest pool: ok\n");
    return 0;
}

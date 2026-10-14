/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * guest_pool_test.c — the donor pool's bookkeeping (app/Sources/SharedMemory/guest_pool.c)
 * against a page model: random takes and releases (whole, prefix, suffix, middle,
 * across leases), purge-and-reset when an object empties. Checks that a range is
 * only ever handed out from never-used or reset pool pages (the zero guarantee),
 * that no pool page backs two guest pages, that a guest page keeps its pool page
 * through splits, and that the lease bound covers the worst split pattern.
 */
#include "guest_pool.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

enum { PAGE = 16384, OBJS = 4, OBJ_PAGES = 64, GUEST_PAGES = 1024 };
enum { FRESH, LEASED, DIRTY };
static unsigned char pool_state[OBJS][OBJ_PAGES];
/* The pool page backing each guest page, -1 for none. */
static int guest_obj[GUEST_PAGES], guest_off[GUEST_PAGES];
static const uintptr_t BASE = 0x7000000000ull;

static void check_model(const struct pp_pool *p)
{
    int seen[OBJS][OBJ_PAGES];
    memset(seen, 0, sizeof seen);
    uint64_t live = 0;
    for (uint32_t i = 0; i < p->nleases; i++) {
        const struct pp_pool_lease *l = &p->leases[i];
        CHECK(l->lo < l->hi && !(l->lo % PAGE) && !(l->hi % PAGE) && !(l->offset % PAGE));
        CHECK(l->offset + (l->hi - l->lo) <= p->objects[l->object].bump);
        for (uintptr_t a = l->lo; a < l->hi; a += PAGE) {
            unsigned g = (unsigned)((a - BASE) / PAGE), o = (unsigned)((l->offset + (a - l->lo)) / PAGE);
            CHECK(guest_obj[g] == (int)l->object && guest_off[g] == (int)o);
            CHECK(pool_state[l->object][o] == LEASED);
            CHECK(!seen[l->object][o]++);
        }
        live += l->hi - l->lo;
    }
    CHECK(live == p->live);
    for (unsigned o = 0; o < OBJS; o++) {
        uint64_t olive = 0;
        for (unsigned k = 0; k < OBJ_PAGES; k++) {
            if (pool_state[o][k] == LEASED) { CHECK(seen[o][k]); olive += PAGE; }
            if ((uint64_t)k * PAGE >= p->objects[o].bump) CHECK(pool_state[o][k] == FRESH);
        }
        CHECK(olive == p->objects[o].live);
    }
}

static void take(struct pp_pool *p, unsigned g, unsigned pages)
{
    for (unsigned k = 0; k < pages; k++) if (guest_obj[g + k] >= 0) return;   /* Wine backs only fresh commits */
    uint32_t obj;
    uint64_t off;
    if (pp_pool_take(p, BASE + (uintptr_t)g * PAGE, (uint64_t)pages * PAGE, &obj, &off)) return;
    for (unsigned k = 0; k < pages; k++) {
        unsigned o = (unsigned)(off / PAGE) + k;
        CHECK(pool_state[obj][o] == FRESH);   /* the zero guarantee */
        pool_state[obj][o] = LEASED;
        guest_obj[g + k] = (int)obj;
        guest_off[g + k] = (int)o;
    }
}

static void release(struct pp_pool *p, unsigned g, unsigned pages, int detached, unsigned resets_fail)
{
    uint32_t emptied[PP_POOL_MAX_OBJECTS];
    for (unsigned k = 0; k < pages; k++) {
        if (guest_obj[g + k] < 0) continue;
        pool_state[guest_obj[g + k]][guest_off[g + k]] = DIRTY;
        guest_obj[g + k] = guest_off[g + k] = -1;
    }
    uint32_t n = pp_pool_release(p, BASE + (uintptr_t)g * PAGE, BASE + (uintptr_t)(g + pages) * PAGE, detached, emptied);
    for (uint32_t i = 0; i < n; i++) {
        CHECK(emptied[i] < OBJS && !p->objects[emptied[i]].live);
        for (uint32_t j = 0; j < i; j++) CHECK(emptied[j] != emptied[i]);
        int zeroed = !resets_fail;
        if (zeroed) memset(pool_state[emptied[i]], FRESH, OBJ_PAGES);
        pp_pool_reset(p, emptied[i], zeroed);
        if (!zeroed) CHECK(p->objects[emptied[i]].retired);
    }
    /* An object with no lease and pages handed out must have been reported. */
    for (unsigned o = 0; o < OBJS; o++)
        if (!p->objects[o].retired && !p->objects[o].live) CHECK(!p->objects[o].bump);
}

static void reset_model(void)
{
    memset(pool_state, FRESH, sizeof pool_state);
    for (unsigned g = 0; g < GUEST_PAGES; g++) guest_obj[g] = guest_off[g] = -1;
}

int main(void)
{
    static struct pp_pool p;
    uint64_t max = pp_pool_max_leases((uint64_t)OBJS * OBJ_PAGES * PAGE, PAGE);
    struct pp_pool_lease *leases = calloc(max, sizeof *leases);

    /* The bound: a 6 GiB pool on 16 KiB pages, and the largest pool. */
    CHECK(pp_pool_max_leases(6ull << 30, 16384) == 393216);
    CHECK((uint64_t)PP_POOL_MAX_OBJECTS * (256ull << 20) == (8ull << 30));

    /* Misaligned and oversize requests are refused; adds past the limit too. */
    pp_pool_init(&p, PAGE, leases, (uint32_t)max);
    CHECK(pp_pool_add(&p, PAGE + 1) < 0);
    for (unsigned o = 0; o < OBJS; o++) CHECK(pp_pool_add(&p, (uint64_t)OBJ_PAGES * PAGE) == (int)o);
    uint32_t obj;
    uint64_t off;
    CHECK(pp_pool_take(&p, BASE + 1, PAGE, &obj, &off) < 0);
    CHECK(pp_pool_take(&p, BASE, PAGE + 1, &obj, &off) < 0);
    CHECK(pp_pool_take(&p, BASE, (uint64_t)(OBJ_PAGES + 1) * PAGE, &obj, &off) < 0);
    CHECK(p.refused == 3 && !p.nleases);

    /* untake gives the space back. */
    CHECK(!pp_pool_take(&p, BASE, 4 * PAGE, &obj, &off) && obj == 0 && off == 0);
    pp_pool_untake(&p, BASE);
    CHECK(!p.nleases && !p.objects[0].bump && !p.live && !p.served);

    /* A released range is not reused until its whole object is free, then from 0. */
    reset_model();
    take(&p, 0, 32);
    take(&p, 32, 16);
    release(&p, 0, 32, 0, 0);
    CHECK(p.objects[0].bump == 48ull * PAGE && p.objects[0].live == 16ull * PAGE);
    take(&p, 100, 32);   /* does not fit past the bump: the next object */
    CHECK(guest_obj[100] == 1);
    release(&p, 32, 16, 1, 0);
    CHECK(!p.objects[0].bump && p.resets == 1 && p.detaches == 1 && p.detached_bytes == 16ull * PAGE);
    take(&p, 200, 8);
    CHECK(guest_obj[200] == 0 && guest_off[200] == 0);
    check_model(&p);

    /* Every lease page released one at a time in the middle: splits stay within the bound. */
    pp_pool_init(&p, PAGE, leases, (uint32_t)max);
    for (unsigned o = 0; o < OBJS; o++) pp_pool_add(&p, (uint64_t)OBJ_PAGES * PAGE);
    reset_model();
    for (unsigned o = 0; o < OBJS; o++) take(&p, o * OBJ_PAGES, OBJ_PAGES);
    for (unsigned g = 1; g < OBJS * OBJ_PAGES; g += 2) { release(&p, g, 1, 0, 0); check_model(&p); }
    CHECK(p.nleases == OBJS * OBJ_PAGES / 2 && p.nleases <= max);
    release(&p, 0, OBJS * OBJ_PAGES, 0, 0);
    CHECK(!p.nleases && !p.live && p.resets == OBJS);
    check_model(&p);

    /* Unmatched bytes are counted, nothing else changes. */
    uint64_t unmatched = p.unmatched_bytes;
    CHECK(unmatched == (uint64_t)OBJS * OBJ_PAGES / 2 * PAGE);   /* the pages released before */
    release(&p, 500, 4, 0, 0);
    CHECK(p.unmatched_bytes == unmatched + 4ull * PAGE && !p.nleases);

    /* Random: takes of 1-40 pages, releases of any range, some resets failing (retire). */
    for (unsigned seed = 1; seed <= 300; seed++) {
        unsigned rng = seed;
        pp_pool_init(&p, PAGE, leases, (uint32_t)max);
        for (unsigned o = 0; o < OBJS; o++) pp_pool_add(&p, (uint64_t)OBJ_PAGES * PAGE);
        reset_model();
#define NEXT (rng = rng * 1664525u + 1013904223u, rng >> 8)
        for (unsigned step = 0; step < 400; step++) {
            unsigned g = NEXT % GUEST_PAGES;
            if (NEXT % 2) {
                unsigned pages = 1 + NEXT % 40;
                if (g + pages > GUEST_PAGES) pages = GUEST_PAGES - g;
                take(&p, g, pages);
            } else {
                unsigned pages = 1 + NEXT % 120;
                if (g + pages > GUEST_PAGES) pages = GUEST_PAGES - g;
                int detached = NEXT % 4 == 0;
                int fail = seed % 7 == 0 && NEXT % 3 == 0;
                release(&p, g, pages, detached, fail);
            }
            check_model(&p);
            CHECK(p.nleases <= max);
        }
        CHECK(p.served_bytes == p.live + p.released_bytes);
    }
    free(leases);
    if (failures) { printf("%d failures\n", failures); return 1; }
    printf("guest pool: ok\n");
    return 0;
}

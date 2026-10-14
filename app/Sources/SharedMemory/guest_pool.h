/* SPDX-License-Identifier: GPL-3.0-or-later
 * The donor pool's bookkeeping (docs/plans/2026-10-12-donor-memory.md, steps 3
 * and 4): which part of which pool object backs which guest range. Pure C, no
 * Mach, so the host tests it (app/tests/guest_pool_test.c); GuestPool.m maps,
 * zeroes and purges.
 *
 * Each object keeps two page bitmaps: leased (backs a guest range now) and
 * stale (may hold old guest data). A request takes the smallest run of free
 * pages that fits, over all objects (best fit; freed neighbours coalesce
 * because they are adjacent free pages). A released range becomes free and
 * stale; it is handed out again, but the caller must zero every stale page of a
 * take (pp_pool_next_stale) and then call pp_pool_zeroed before Wine sees the
 * range. When an object's last lease is released it awaits a purge: it is not
 * handed out until the caller zeroes all of it and calls pp_pool_reset (or
 * retires it when that fails). So every page Wine gets reads zero, as a Windows
 * commit must. Which pool page backs which guest page is a table indexed by the
 * guest page (madeira-unix 0150 offers every fresh commit of a host page or
 * more, so tens of thousands of small leases may be live): a release costs the
 * pages of its own range, not the number of leases. Callers serialize every call. */
#ifndef PP_GUEST_POOL_H
#define PP_GUEST_POOL_H
#include <stdint.h>

/* 8 GiB of 256 MiB objects; the dev setting's largest pool is 6 GiB. */
#define PP_POOL_MAX_OBJECTS 32u
/* The pages of one object: 256 MiB of 16 KiB pages. */
#define PP_POOL_MAX_OBJECT_PAGES 16384u
#define PP_POOL_OBJECT_WORDS (PP_POOL_MAX_OBJECT_PAGES / 64u)

struct pp_pool_object {
    uint64_t size;     /* bytes, a multiple of the page */
    uint64_t live;     /* bytes leased */
    uint64_t stale;    /* bytes free that may hold old data */
    int awaiting_purge;   /* its last lease went: not handed out until pp_pool_reset */
    int retired;          /* a purge failed: never handed out again */
    uint64_t leased[PP_POOL_OBJECT_WORDS];      /* page bits */
    uint64_t stale_map[PP_POOL_OBJECT_WORDS];   /* page bits; a leased page is stale only between take and zeroed */
};

struct pp_pool {
    uint64_t page;
    struct pp_pool_object objects[PP_POOL_MAX_OBJECTS];
    uint32_t nobjects;
    /* One entry per guest page of [base, base + entries pages), owned by the caller:
     * 0, or 1 + object * PP_POOL_MAX_OBJECT_PAGES + the object's page backing it. */
    uint32_t *where;
    uintptr_t base;
    uint64_t entries;
    /* Counters for the log. */
    uint64_t live, stale, served, served_bytes, released_bytes, detaches, detached_bytes;
    uint64_t resets, retired, refused, unmatched_bytes;
    uint64_t reuses, zeroed_bytes;   /* takes with stale pages, and those pages' bytes */
};

/* The entries of the guest page table for guest [base, end). */
uint64_t pp_pool_map_entries(uintptr_t base, uintptr_t end, uint64_t page);

/* Sets up p over `where` (pp_pool_map_entries entries, zeroed) for guest pages from
 * base; objects are added by pp_pool_add. */
void pp_pool_init(struct pp_pool *p, uint64_t page, uint32_t *where, uintptr_t base, uint64_t entries);
/* Adds an object of `size` bytes (at most PP_POOL_MAX_OBJECT_PAGES pages); returns
 * its index, or -1 when full, too large or misaligned. Its pages start zero. */
int pp_pool_add(struct pp_pool *p, uint64_t size);

/* Leases len bytes for guest [lo, lo + len) from the smallest free run that
 * fits (lowest object and offset on a tie; the first exact fit ends the
 * search). Returns 0 and the object and offset, or -1 (counted as refused)
 * when nothing fits, or the request is misaligned, outside the table or
 * overlaps a guest page already leased. The take's stale pages must be zeroed
 * before Wine uses it. */
int pp_pool_take(struct pp_pool *p, uintptr_t lo, uint64_t len, uint32_t *object, uint64_t *offset);
/* The first run of stale pages of object in [*at, end): returns its length
 * and moves *at to its start, or returns 0 when there is none. */
uint64_t pp_pool_next_stale(const struct pp_pool *p, uint32_t object, uint64_t *at, uint64_t end);
/* The caller zeroed every stale page of the take at offset, len bytes. */
void pp_pool_zeroed(struct pp_pool *p, uint32_t object, uint64_t offset, uint64_t len);
/* Undoes the pp_pool_take of guest [lo, lo + len) (its mapping failed; nothing was zeroed). */
void pp_pool_untake(struct pp_pool *p, uintptr_t lo, uint64_t len);
/* The object and offset backing guest page va: 0, or -1 when no lease covers it. */
int pp_pool_lookup(const struct pp_pool *p, uintptr_t va, uint32_t *object, uint64_t *offset);

/* Wine no longer uses guest [lo, hi) (unmap, decommit, or a detach to
 * ordinary memory when `detached`). Frees every leased page in it; the freed
 * pages become stale. Writes the objects whose last lease went to emptied[]
 * (at most PP_POOL_MAX_OBJECTS) and returns how many: each awaits a purge and
 * pp_pool_reset. Bytes of [lo, hi) that no lease covers are counted in
 * unmatched_bytes. */
uint32_t pp_pool_release(struct pp_pool *p, uintptr_t lo, uintptr_t hi, int detached, uint32_t *emptied);
/* After a release emptied the object: zeroed makes all of it free and zero
 * again, otherwise it is retired. */
void pp_pool_reset(struct pp_pool *p, uint32_t object, int zeroed);
#endif

/* SPDX-License-Identifier: GPL-3.0-or-later
 * The donor pool's bookkeeping (docs/plans/2026-10-12-donor-memory.md, step 3):
 * which part of which pool object backs which guest range. Pure C, no Mach, so
 * the host tests it (app/tests/guest_pool_test.c); GuestPool.m maps and purges.
 *
 * Each object is handed out from its start upward (bump) and never twice: a
 * released range is not reused while any other part of its object is in use.
 * When an object's last lease is released the caller zeroes the whole object
 * (purges it) and resets it, or retires it when that fails. So every range
 * handed out is either never-touched or freshly purged: zero, as a Windows
 * commit must read. Callers serialize every call. */
#ifndef PP_GUEST_POOL_H
#define PP_GUEST_POOL_H
#include <stdint.h>

/* 8 GiB of 256 MiB objects; the dev setting's largest pool is 6 GiB. */
#define PP_POOL_MAX_OBJECTS 32u

struct pp_pool_object {
    uint64_t size;    /* bytes, a multiple of the page */
    uint64_t bump;    /* bytes from the start handed out since the last reset */
    uint64_t live;    /* bytes of those still leased */
    int retired;      /* a reset failed: never handed out again */
};

/* [lo, hi) of guest memory is backed by the object's bytes from offset. */
struct pp_pool_lease {
    uintptr_t lo, hi;
    uint64_t offset;
    uint32_t object;
};

struct pp_pool {
    uint64_t page;
    struct pp_pool_object objects[PP_POOL_MAX_OBJECTS];
    uint32_t nobjects;
    struct pp_pool_lease *leases;   /* maxleases entries, owned by the caller */
    uint32_t nleases, maxleases;
    /* Counters for the log. */
    uint64_t live, served, served_bytes, released_bytes, detaches, detached_bytes;
    uint64_t resets, retired, refused, unmatched_bytes;
};

/* The leases a pool of `bytes` can need: each is at least one page and no two
 * share a pool byte, so this bound also covers splits. */
uint64_t pp_pool_max_leases(uint64_t bytes, uint64_t page);

/* Sets up p over `leases` (pp_pool_max_leases entries); objects are added by pp_pool_add. */
void pp_pool_init(struct pp_pool *p, uint64_t page, struct pp_pool_lease *leases, uint32_t maxleases);
/* Adds an object of `size` bytes; returns its index, or -1 when full or misaligned. */
int pp_pool_add(struct pp_pool *p, uint64_t size);

/* Leases len bytes for guest [lo, lo + len) from the first object with that
 * much unused past its bump. Returns 0 and the object and offset, or -1
 * (counted as refused) when no object has room or the request is misaligned. */
int pp_pool_take(struct pp_pool *p, uintptr_t lo, uint64_t len, uint32_t *object, uint64_t *offset);
/* Undoes the last pp_pool_take for lo (its mapping failed). */
void pp_pool_untake(struct pp_pool *p, uintptr_t lo);

/* Wine no longer uses guest [lo, hi) (unmap, decommit, or a detach to
 * ordinary memory when `detached`). Trims every lease it overlaps. Writes the
 * objects whose last lease went to emptied[] (at most PP_POOL_MAX_OBJECTS) and
 * returns how many: each must be zeroed and pp_pool_reset. Bytes of [lo, hi)
 * that no lease covers are counted in unmatched_bytes. */
uint32_t pp_pool_release(struct pp_pool *p, uintptr_t lo, uintptr_t hi, int detached, uint32_t *emptied);
/* After a release emptied the object: zeroed makes all of it available again,
 * otherwise it is retired. */
void pp_pool_reset(struct pp_pool *p, uint32_t object, int zeroed);
#endif

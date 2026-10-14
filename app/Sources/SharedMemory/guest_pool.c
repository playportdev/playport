/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "guest_pool.h"
#include <string.h>

/* The first page in [from, n) whose bit equals `set`, or n. */
static uint32_t next_bit(const uint64_t *bits, uint32_t from, uint32_t n, int set)
{
    while (from < n) {
        uint64_t w = set ? bits[from / 64] : ~bits[from / 64];
        w &= ~0ull << (from % 64);
        if (w) {
            uint32_t at = (from & ~63u) + (uint32_t)__builtin_ctzll(w);
            return at < n ? at : n;
        }
        from = (from & ~63u) + 64;
    }
    return n;
}

static void set_bits(uint64_t *bits, uint32_t from, uint32_t to, int set)
{
    for (uint32_t i = from; i < to; i++) {
        if (set) bits[i / 64] |= 1ull << (i % 64);
        else bits[i / 64] &= ~(1ull << (i % 64));
    }
}

static uint32_t count_bits(const uint64_t *bits, uint32_t from, uint32_t to)
{
    uint32_t n = 0;
    for (uint32_t i = from; i < to; i++) n += (uint32_t)(bits[i / 64] >> (i % 64)) & 1u;
    return n;
}

static uint32_t pages_of(const struct pp_pool *p, const struct pp_pool_object *o)
{
    return (uint32_t)(o->size / p->page);
}

uint64_t pp_pool_max_leases(uint64_t bytes, uint64_t page)
{
    return page ? bytes / page : 0;
}

void pp_pool_init(struct pp_pool *p, uint64_t page, struct pp_pool_lease *leases, uint32_t maxleases)
{
    memset(p, 0, sizeof *p);
    p->page = page;
    p->leases = leases;
    p->maxleases = maxleases;
}

int pp_pool_add(struct pp_pool *p, uint64_t size)
{
    if (p->nobjects >= PP_POOL_MAX_OBJECTS || !p->page || !size || size % p->page
        || size / p->page > PP_POOL_MAX_OBJECT_PAGES) return -1;
    struct pp_pool_object *o = &p->objects[p->nobjects];
    memset(o, 0, sizeof *o);
    o->size = size;
    return (int)p->nobjects++;
}

int pp_pool_take(struct pp_pool *p, uintptr_t lo, uint64_t len, uint32_t *object, uint64_t *offset)
{
    if (!len || len % p->page || lo % p->page || lo + len < lo || p->nleases >= p->maxleases
        || len / p->page > PP_POOL_MAX_OBJECT_PAGES) {
        p->refused++;
        return -1;
    }
    uint32_t need = (uint32_t)(len / p->page), best_obj = 0, best_at = 0, best_len = UINT32_MAX;
    for (uint32_t i = 0; i < p->nobjects; i++) {
        const struct pp_pool_object *o = &p->objects[i];
        uint32_t n = pages_of(p, o);
        if (o->retired || o->awaiting_purge || o->size - o->live < len) continue;
        for (uint32_t at = next_bit(o->leased, 0, n, 0); at < n;) {
            uint32_t end = next_bit(o->leased, at, n, 1);
            if (end - at >= need && end - at < best_len) {
                best_obj = i;
                best_at = at;
                best_len = end - at;
            }
            at = next_bit(o->leased, end, n, 0);
        }
        if (best_len == need) break;   /* nothing fits better */
    }
    if (best_len == UINT32_MAX) {
        p->refused++;
        return -1;
    }
    struct pp_pool_object *o = &p->objects[best_obj];
    set_bits(o->leased, best_at, best_at + need, 1);
    uint64_t stale = (uint64_t)count_bits(o->stale_map, best_at, best_at + need) * p->page;
    o->stale -= stale;
    p->stale -= stale;
    if (stale) {
        p->reuses++;
        p->zeroed_bytes += stale;
    }
    *object = best_obj;
    *offset = (uint64_t)best_at * p->page;
    p->leases[p->nleases++] = (struct pp_pool_lease){ lo, lo + len, *offset, best_obj };
    o->live += len;
    p->live += len;
    p->served++;
    p->served_bytes += len;
    return 0;
}

uint64_t pp_pool_next_stale(const struct pp_pool *p, uint32_t object, uint64_t *at, uint64_t end)
{
    const struct pp_pool_object *o = &p->objects[object];
    uint32_t n = (uint32_t)((end < o->size ? end : o->size) / p->page);
    uint32_t a = next_bit(o->stale_map, (uint32_t)(*at / p->page), n, 1);
    if (a >= n) return 0;
    uint32_t b = next_bit(o->stale_map, a, n, 0);
    *at = (uint64_t)a * p->page;
    return (uint64_t)(b - a) * p->page;
}

void pp_pool_zeroed(struct pp_pool *p, uint32_t object, uint64_t offset, uint64_t len)
{
    struct pp_pool_object *o = &p->objects[object];
    set_bits(o->stale_map, (uint32_t)(offset / p->page), (uint32_t)((offset + len) / p->page), 0);
}

void pp_pool_untake(struct pp_pool *p, uintptr_t lo)
{
    if (!p->nleases || p->leases[p->nleases - 1].lo != lo) return;
    struct pp_pool_lease l = p->leases[--p->nleases];
    struct pp_pool_object *o = &p->objects[l.object];
    uint64_t len = l.hi - l.lo;
    uint32_t a = (uint32_t)(l.offset / p->page), b = (uint32_t)((l.offset + len) / p->page);
    /* Nothing was mapped or zeroed: the pages are free again as they were. */
    set_bits(o->leased, a, b, 0);
    uint64_t stale = (uint64_t)count_bits(o->stale_map, a, b) * p->page;
    o->stale += stale;
    p->stale += stale;
    if (stale) {
        p->reuses--;
        p->zeroed_bytes -= stale;
    }
    o->live -= len;
    p->live -= len;
    p->served--;
    p->served_bytes -= len;
}

uint32_t pp_pool_release(struct pp_pool *p, uintptr_t lo, uintptr_t hi, int detached, uint32_t *emptied)
{
    uint64_t matched = 0;
    uint32_t n = 0, i = 0;
    if (lo >= hi) return 0;
    while (i < p->nleases) {
        struct pp_pool_lease *l = &p->leases[i];
        if (!(l->lo < hi && lo < l->hi)) { i++; continue; }
        uintptr_t a = l->lo > lo ? l->lo : lo, b = l->hi < hi ? l->hi : hi;
        uint32_t obj = l->object;
        uint64_t from = l->offset + (a - l->lo);
        int removed = 0;
        if (a == l->lo && b == l->hi) {
            p->leases[i] = p->leases[--p->nleases];
            removed = 1;
        } else if (a == l->lo) {
            l->offset += b - l->lo;
            l->lo = b;
        } else if (b == l->hi) {
            l->hi = a;
        } else {
            /* The middle goes: the suffix becomes its own lease. Leases never
             * share a pool byte and each is at least a page, so there is room. */
            p->leases[p->nleases++] = (struct pp_pool_lease){ b, l->hi, l->offset + (b - l->lo), obj };
            l->hi = a;
        }
        struct pp_pool_object *o = &p->objects[obj];
        uint32_t pa = (uint32_t)(from / p->page), pb = (uint32_t)((from + (b - a)) / p->page);
        set_bits(o->leased, pa, pb, 0);
        set_bits(o->stale_map, pa, pb, 1);
        o->live -= b - a;
        p->live -= b - a;
        o->stale += b - a;
        p->stale += b - a;
        matched += b - a;
        if (!o->live) {
            o->awaiting_purge = 1;
            emptied[n++] = obj;
        }
        if (!removed) i++;
    }
    p->released_bytes += matched;
    p->unmatched_bytes += (hi - lo) - matched;
    if (detached) {
        p->detaches++;
        p->detached_bytes += matched;
    }
    return n;
}

void pp_pool_reset(struct pp_pool *p, uint32_t object, int zeroed)
{
    struct pp_pool_object *o = &p->objects[object];
    if (o->live || !o->awaiting_purge) return;
    o->awaiting_purge = 0;
    if (zeroed) {
        p->stale -= o->stale;
        o->stale = 0;
        memset(o->stale_map, 0, sizeof o->stale_map);
        p->resets++;
    } else if (!o->retired) {
        o->retired = 1;
        p->retired++;
    }
}

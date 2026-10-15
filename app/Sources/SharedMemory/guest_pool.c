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

uint64_t pp_pool_map_entries(uintptr_t base, uintptr_t end, uint64_t page)
{
    return page && end > base ? (end - base) / page : 0;
}

void pp_pool_init(struct pp_pool *p, uint64_t page, uint32_t *where, uintptr_t base, uint64_t entries)
{
    memset(p, 0, sizeof *p);
    p->page = page;
    p->where = where;
    p->base = base;
    p->entries = entries;
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

/* The table index of guest page lo, with len bytes inside the table; 0 if not. */
static int table_index(const struct pp_pool *p, uintptr_t lo, uint64_t len, uint64_t *index)
{
    if (lo < p->base || lo % p->page || len % p->page) return 0;
    uint64_t first = (lo - p->base) / p->page;
    if (first > p->entries || len / p->page > p->entries - first) return 0;
    *index = first;
    return 1;
}

int pp_pool_take(struct pp_pool *p, uintptr_t lo, uint64_t len, uint32_t *object, uint64_t *offset)
{
    uint64_t first;
    if (!len || lo + len < lo || len / p->page > PP_POOL_MAX_OBJECT_PAGES || !table_index(p, lo, len, &first)) {
        p->refused++;
        return -1;
    }
    uint32_t need = (uint32_t)(len / p->page), best_obj = 0, best_at = 0, best_len = UINT32_MAX;
    for (uint32_t k = 0; k < need; k++) {
        if (p->where[first + k]) {   /* Wine never offers a page twice: refuse rather than alias it */
            p->refused++;
            return -1;
        }
    }
    /* Growing, the candidates are the runs of free pages (leased clear); stopped, only the
     * runs of stale pages (free pages used since the object's last purge). */
    int want = p->growth_stopped ? 1 : 0;
    for (uint32_t i = 0; i < p->nobjects && best_len != need; i++) {
        const struct pp_pool_object *o = &p->objects[i];
        const uint64_t *runs = p->growth_stopped ? o->stale_map : o->leased;
        uint32_t n = pages_of(p, o);
        if (o->retired || o->awaiting_purge || o->size - o->live < len || (p->growth_stopped && o->stale < len)) continue;
        for (uint32_t at = next_bit(runs, 0, n, want); at < n;) {
            uint32_t end = next_bit(runs, at, n, !want);
            if (end - at >= need && end - at < best_len) {
                best_obj = i;
                best_at = at;
                best_len = end - at;
                if (best_len == need) break;   /* nothing fits better */
            }
            at = next_bit(runs, end, n, want);
        }
    }
    if (best_len == UINT32_MAX) {
        p->refused++;
        if (p->growth_stopped) p->growth_refused++;
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
    for (uint32_t k = 0; k < need; k++)
        p->where[first + k] = 1 + best_obj * PP_POOL_MAX_OBJECT_PAGES + best_at + k;
    *object = best_obj;
    *offset = (uint64_t)best_at * p->page;
    o->live += len;
    p->live += len;
    p->served++;
    p->served_bytes += len;
    return 0;
}

int pp_pool_lookup(const struct pp_pool *p, uintptr_t va, uint32_t *object, uint64_t *offset)
{
    uint64_t i;
    if (!table_index(p, va - va % p->page, 0, &i) || i >= p->entries || !p->where[i]) return -1;
    uint32_t e = p->where[i] - 1;
    *object = e / PP_POOL_MAX_OBJECT_PAGES;
    *offset = (uint64_t)(e % PP_POOL_MAX_OBJECT_PAGES) * p->page + va % p->page;
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

void pp_pool_untake(struct pp_pool *p, uintptr_t lo, uint64_t len)
{
    uint64_t first;
    uint32_t object;
    uint64_t offset;
    if (!len || !table_index(p, lo, len, &first) || pp_pool_lookup(p, lo, &object, &offset)) return;
    struct pp_pool_object *o = &p->objects[object];
    uint32_t a = (uint32_t)(offset / p->page), b = a + (uint32_t)(len / p->page);
    /* Nothing was mapped or zeroed: the pages are free again as they were. */
    for (uint64_t k = 0; k < len / p->page; k++) p->where[first + k] = 0;
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
    uint32_t n = 0;
    if (lo >= hi) return 0;
    /* The table's pages that [lo, hi) touches; a partial page is not leased by it. */
    uintptr_t a = lo > p->base ? lo : p->base, end = p->base + p->entries * p->page;
    uintptr_t b = hi < end ? hi : end;
    a = p->base + (a - p->base + p->page - 1) / p->page * p->page;
    b = p->base + (b > p->base ? (b - p->base) / p->page * p->page : 0);
    for (uintptr_t va = a; va < b; va += p->page) {
        uint32_t *e = &p->where[(va - p->base) / p->page];
        if (!*e) continue;
        uint32_t obj = (*e - 1) / PP_POOL_MAX_OBJECT_PAGES, page = (*e - 1) % PP_POOL_MAX_OBJECT_PAGES;
        struct pp_pool_object *o = &p->objects[obj];
        *e = 0;
        o->leased[page / 64] &= ~(1ull << (page % 64));
        o->stale_map[page / 64] |= 1ull << (page % 64);
        o->live -= p->page;
        p->live -= p->page;
        o->stale += p->page;
        p->stale += p->page;
        matched += p->page;
        if (!o->live) {
            o->awaiting_purge = 1;
            emptied[n++] = obj;
        }
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

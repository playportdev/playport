/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "guest_pool.h"
#include <string.h>

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
    if (p->nobjects >= PP_POOL_MAX_OBJECTS || !size || size % p->page) return -1;
    p->objects[p->nobjects] = (struct pp_pool_object){ .size = size };
    return (int)p->nobjects++;
}

int pp_pool_take(struct pp_pool *p, uintptr_t lo, uint64_t len, uint32_t *object, uint64_t *offset)
{
    if (!len || len % p->page || lo % p->page || lo + len < lo || p->nleases >= p->maxleases) {
        p->refused++;
        return -1;
    }
    for (uint32_t i = 0; i < p->nobjects; i++) {
        struct pp_pool_object *o = &p->objects[i];
        if (o->retired || o->size - o->bump < len) continue;
        *object = i;
        *offset = o->bump;
        p->leases[p->nleases++] = (struct pp_pool_lease){ lo, lo + len, o->bump, i };
        o->bump += len;
        o->live += len;
        p->live += len;
        p->served++;
        p->served_bytes += len;
        return 0;
    }
    p->refused++;
    return -1;
}

void pp_pool_untake(struct pp_pool *p, uintptr_t lo)
{
    if (!p->nleases || p->leases[p->nleases - 1].lo != lo) return;
    struct pp_pool_lease l = p->leases[--p->nleases];
    struct pp_pool_object *o = &p->objects[l.object];
    uint64_t len = l.hi - l.lo;
    if (o->bump == l.offset + len) o->bump = l.offset;   /* nothing was mapped: hand it out again */
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
        o->live -= b - a;
        p->live -= b - a;
        matched += b - a;
        if (!o->live && o->bump) emptied[n++] = obj;
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
    if (o->live) return;
    if (zeroed) {
        o->bump = 0;
        p->resets++;
    } else if (!o->retired) {
        o->retired = 1;
        p->retired++;
    }
}

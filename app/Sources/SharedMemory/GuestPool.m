// SPDX-License-Identifier: GPL-3.0-or-later
// The donor pool behind madeira-unix 0148's hooks, dev builds only
// (docs/plans/2026-10-12-donor-memory.md, step 3). The app keeps the pool's
// purgeable objects as memory-entry send rights and maps none of them: each
// fresh guest commit Wine offers is backed by vm_map of an unused range of one
// object at Wine's own address, so pool pages are resident only once the game
// touches them. A release is bookkeeping here, no IPC: the freed range is
// handed out again (best fit, guest_pool.h), and its stale pages are zeroed by
// memset at Wine's new address right after the vm_map, before the hook returns.
// An object whose last lease is released is purged whole (8.4 ms per touched
// 256 MiB on the phone) at the next hook call, before any take: Wine calls the
// release hook before it replaces its own mapping, so neither zeroing ever runs
// while Wine still maps the old range. Every hook runs on a Wine thread under
// virtual_mutex.
#import "GuestPool.h"
#import "SharedMemory.h"
#include "guest_pool.h"
#include <mach/mach.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static struct pp_pool pool;
static NSArray<PPMemoryRegion *> *regions;   // the send rights; held for the process's life
static void (*logLine)(const char *);
static uint64_t mapFailures, purgeNanos, purgeMaxNanos, zeroNanos, zeroMaxNanos;
// Time inside the hooks (madeira-unix 0150 offers every fresh commit of a host page or more).
static uint64_t backNanos, backMaxNanos, releaseNanos, releaseMaxNanos, releases;
// The guest window 0148/0150 back, and the pool's table of its pages.
static const uintptr_t windowLo = 0x7000000000ULL, windowHi = 0x7c00000000ULL;
// Objects whose last lease went in an earlier release, purged by purgePending.
static uint32_t pending[PP_POOL_MAX_OBJECTS], npending;

static void say(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *format, ...) {
    if (!logLine) { return; }
    char line[320];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    logLine(line);
}

static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// Purges the objects emptied by earlier releases (Wine has replaced its mappings of
// them since: it calls the release hook before it does, all under virtual_mutex).
// Called with the lock held, at the start of every hook.
static void purgePending(void) {
    for (uint32_t i = 0; i < npending; i++) {
        uint32_t object = pending[i];
        uint64_t t0 = now();
        int kr = pp_memory_empty(regions[object]);
        uint64_t took = now() - t0;
        purgeNanos += took;
        if (took > purgeMaxNanos) { purgeMaxNanos = took; }
        pp_pool_reset(&pool, object, kr == 0);
        if (pool.resets + pool.retired <= 16 || !(pool.resets % 64) || kr) {
            say("donor-pool: object %u free again: purge kr=%d in %.2f ms (%s); resets=%llu", object, kr,
                took / 1e6, kr ? "retired" : "zeroed", pool.resets);
        }
    }
    npending = 0;
}

bool pp_guest_pool_install(NSArray<PPMemoryRegion *> *objects, void (*log)(const char *)) {
    os_unfair_lock_lock(&lock);
    bool done = false;
    if (!regions && objects.count && objects.count <= PP_POOL_MAX_OBJECTS) {
        uint64_t bytes = 0;
        for (PPMemoryRegion *r in objects) { bytes += r.byteCount; }
        uint64_t entries = pp_pool_map_entries(windowLo, windowHi, vm_page_size);
        uint32_t *where = calloc(entries, sizeof *where);   // 12 MiB, zero-fill: pages only as used
        if (where && bytes) {
            pp_pool_init(&pool, vm_page_size, where, windowLo, entries);
            for (PPMemoryRegion *r in objects) { pp_pool_add(&pool, r.byteCount); }
            regions = [objects copy];
            logLine = log;
            done = true;
        } else {
            free(where);
        }
    }
    os_unfair_lock_unlock(&lock);
    return done;
}

NSDictionary<NSString *, NSNumber *> *pp_guest_pool_stats(void) {
    os_unfair_lock_lock(&lock);
    uint64_t bytes = 0, retired = 0;
    for (uint32_t i = 0; i < pool.nobjects; i++) { bytes += pool.objects[i].size; retired += pool.objects[i].retired; }
    NSDictionary *stats = @{@"objects": @(pool.nobjects), @"bytes": @(bytes), @"live": @(pool.live),
        @"served": @(pool.served), @"served_bytes": @(pool.served_bytes),
        @"released_bytes": @(pool.released_bytes), @"detaches": @(pool.detaches),
        @"detached_bytes": @(pool.detached_bytes), @"resets": @(pool.resets), @"retired": @(retired),
        @"refused": @(pool.refused), @"unmatched_bytes": @(pool.unmatched_bytes), @"map_failures": @(mapFailures),
        @"purge_ms_total": @(purgeNanos / 1000000), @"purge_ms_max": @(purgeMaxNanos / 1000000),
        @"stale_bytes": @(pool.stale), @"reuses": @(pool.reuses), @"zeroed_bytes": @(pool.zeroed_bytes),
        @"zero_ms_total": @(zeroNanos / 1000000), @"zero_us_max": @(zeroMaxNanos / 1000),
        @"purges_pending": @(npending),
        @"back_ms_total": @(backNanos / 1000000), @"back_us_max": @(backMaxNanos / 1000),
        @"releases": @(releases), @"release_ms_total": @(releaseNanos / 1000000),
        @"release_us_max": @(releaseMaxNanos / 1000)};
    NSArray<PPMemoryRegion *> *objects = regions;
    os_unfair_lock_unlock(&lock);
    uint64_t resident = 0, swapped = 0;
    for (PPMemoryRegion *r in objects) {
        NSDictionary *counts = [r pageCounts];
        resident += [counts[@"resident"] unsignedLongLongValue];
        swapped += [counts[@"swapped"] unsignedLongLongValue];
    }
    NSMutableDictionary *all = [stats mutableCopy];
    all[@"resident_bytes"] = @(resident);
    all[@"swapped_bytes"] = @(swapped);
    return all;
}

// madeira-unix 0148/0150: back guest [address, address + bytes), a fresh RW commit
// (host-page aligned, at most 64 MiB, in [0x7000000000, 0x7c00000000)), or say no.
int playport_guest_memory_backing(void *address, size_t bytes) {
    uintptr_t va = (uintptr_t)address;
    if (va < windowLo || va >= windowHi || bytes > windowHi - va) { return 0; }
    os_unfair_lock_lock(&lock);
    uint64_t hookStart = now();
    int backed = 0;
    uint32_t object;
    uint64_t offset;
    if (regions) { purgePending(); }
    if (regions && !pp_pool_take(&pool, va, bytes, &object, &offset)) {
        int kr = pp_memory_map_range(regions[object], offset, bytes, address);
        if (kr) {
            pp_pool_untake(&pool, va, bytes);
            if (++mapFailures <= 8) {
                say("donor-pool: map %p+0x%zx from object %u offset 0x%llx failed: kr=%d; ordinary memory",
                    address, bytes, object, offset, kr);
            }
        } else {
            backed = 1;
            // The reused pages may hold the data of a range Wine released earlier: zero
            // them through Wine's new mapping before Wine sees it.
            uint64_t t0 = now(), stale = 0;
            for (uint64_t at = offset, run; (run = pp_pool_next_stale(&pool, object, &at, offset + bytes)); at += run) {
                memset((char *)address + (at - offset), 0, run);
                stale += run;
            }
            pp_pool_zeroed(&pool, object, offset, bytes);
            if (stale) {
                uint64_t took = now() - t0;
                zeroNanos += took;
                if (took > zeroMaxNanos) { zeroMaxNanos = took; }
                if (pool.reuses <= 16 || !(pool.reuses % 256)) {
                    say("donor-pool: reuse #%llu %p+0x%zx from object %u offset 0x%llx: zeroed %llu KiB in %.3f ms; "
                        "zeroed_mb=%llu stale_mb=%llu", pool.reuses, address, bytes, object, offset, stale >> 10,
                        took / 1e6, pool.zeroed_bytes >> 20, pool.stale >> 20);
                }
            }
            if (pool.served <= 8 || !(pool.served % 256)) {
                say("donor-pool: served #%llu %p+0x%zx from object %u offset 0x%llx; served_mb=%llu live_mb=%llu",
                    pool.served, address, bytes, object, offset, pool.served_bytes >> 20, pool.live >> 20);
            }
        }
    } else if (regions && (pool.refused == 1 || !(pool.refused % 256))) {
        say("donor-pool: refused %p+0x%zx (#%llu): no free run fits; live_mb=%llu stale_mb=%llu", address, bytes,
            pool.refused, pool.live >> 20, pool.stale >> 20);
    }
    if (regions) {
        uint64_t took = now() - hookStart;
        backNanos += took;
        if (took > backMaxNanos) { backMaxNanos = took; }
    }
    os_unfair_lock_unlock(&lock);
    return backed;
}

// madeira-unix 0148: Wine no longer uses guest [address, address + bytes): it
// unmaps or decommits it, or (detached) has just copied it to ordinary memory
// before a protection other than RW.
void playport_guest_memory_released(void *address, size_t bytes, int detached) {
    os_unfair_lock_lock(&lock);
    if (regions) {
        uint64_t t0 = now();
        purgePending();
        uint32_t emptied[PP_POOL_MAX_OBJECTS];
        uint64_t unmatched = pool.unmatched_bytes;
        uint32_t n = pp_pool_release(&pool, (uintptr_t)address, (uintptr_t)address + bytes, detached, emptied);
        if (detached && (pool.detaches <= 16 || !(pool.detaches % 64))) {
            say("donor-pool: detach #%llu %p+0x%zx to ordinary memory; detached_mb=%llu", pool.detaches, address,
                bytes, pool.detached_bytes >> 20);
        }
        if (pool.unmatched_bytes != unmatched) {
            say("donor-pool: release %p+0x%zx: %llu bytes not leased", address, bytes, pool.unmatched_bytes - unmatched);
        }
        // Wine still maps the range until this hook returns: purge at the next call.
        for (uint32_t i = 0; i < n; i++) { pending[npending++] = emptied[i]; }
        uint64_t took = now() - t0;
        releases++;
        releaseNanos += took;
        if (took > releaseMaxNanos) { releaseMaxNanos = took; }
    }
    os_unfair_lock_unlock(&lock);
}

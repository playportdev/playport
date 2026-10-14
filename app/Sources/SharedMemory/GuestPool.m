// SPDX-License-Identifier: GPL-3.0-or-later
// The donor pool behind madeira-unix 0148's hooks, dev builds only
// (docs/plans/2026-10-12-donor-memory.md, step 3). The app keeps the pool's
// purgeable objects as memory-entry send rights and maps none of them: each
// fresh guest commit Wine offers is backed by vm_map of an unused range of one
// object at Wine's own address, so pool pages are resident only once the game
// touches them. A release is bookkeeping here, no IPC; an object whose last
// lease is released is purged whole before any of it is handed out again
// (guest_pool.h). Every hook runs on a Wine thread under virtual_mutex.
#import "GuestPool.h"
#import "SharedMemory.h"
#include "guest_pool.h"
#include <mach/mach.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static struct pp_pool pool;
static NSArray<PPMemoryRegion *> *regions;   // the send rights; held for the process's life
static void (*logLine)(const char *);
static uint64_t mapFailures, purgeNanos, purgeMaxNanos;

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

bool pp_guest_pool_install(NSArray<PPMemoryRegion *> *objects, void (*log)(const char *)) {
    os_unfair_lock_lock(&lock);
    bool done = false;
    if (!regions && objects.count && objects.count <= PP_POOL_MAX_OBJECTS) {
        uint64_t bytes = 0;
        for (PPMemoryRegion *r in objects) { bytes += r.byteCount; }
        uint64_t max = pp_pool_max_leases(bytes, vm_page_size);
        struct pp_pool_lease *leases = calloc(max, sizeof *leases);   // zero-fill: pages only as used
        if (leases) {
            pp_pool_init(&pool, vm_page_size, leases, (uint32_t)max);
            for (PPMemoryRegion *r in objects) { pp_pool_add(&pool, r.byteCount); }
            regions = [objects copy];
            logLine = log;
            done = true;
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
        @"leases": @(pool.nleases), @"served": @(pool.served), @"served_bytes": @(pool.served_bytes),
        @"released_bytes": @(pool.released_bytes), @"detaches": @(pool.detaches),
        @"detached_bytes": @(pool.detached_bytes), @"resets": @(pool.resets), @"retired": @(retired),
        @"refused": @(pool.refused), @"unmatched_bytes": @(pool.unmatched_bytes), @"map_failures": @(mapFailures),
        @"purge_ms_total": @(purgeNanos / 1000000), @"purge_ms_max": @(purgeMaxNanos / 1000000)};
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

// madeira-unix 0148: back guest [address, address + bytes), a fresh RW commit
// (host-page aligned, at most 64 MiB, in [0x7000000000, 0x7c00000000)), or say no.
int playport_guest_memory_backing(void *address, size_t bytes) {
    uintptr_t va = (uintptr_t)address;
    if (va < 0x7000000000ULL || va >= 0x7c00000000ULL || bytes > 0x7c00000000ULL - va) { return 0; }
    os_unfair_lock_lock(&lock);
    int backed = 0;
    uint32_t object;
    uint64_t offset;
    if (regions && !pp_pool_take(&pool, va, bytes, &object, &offset)) {
        int kr = pp_memory_map_range(regions[object], offset, bytes, address);
        if (kr) {
            pp_pool_untake(&pool, va);
            if (++mapFailures <= 8) {
                say("donor-pool: map %p+0x%zx from object %u offset 0x%llx failed: kr=%d; ordinary memory",
                    address, bytes, object, offset, kr);
            }
        } else {
            backed = 1;
            if (pool.served <= 8 || !(pool.served % 256)) {
                say("donor-pool: served #%llu %p+0x%zx from object %u offset 0x%llx; served_mb=%llu live_mb=%llu",
                    pool.served, address, bytes, object, offset, pool.served_bytes >> 20, pool.live >> 20);
            }
        }
    } else if (regions && (pool.refused == 1 || !(pool.refused % 256))) {
        say("donor-pool: refused %p+0x%zx (#%llu): no object has room; live_mb=%llu", address, bytes, pool.refused,
            pool.live >> 20);
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
        for (uint32_t i = 0; i < n; i++) {
            uint64_t t0 = now();
            int kr = pp_memory_empty(regions[emptied[i]]);
            uint64_t took = now() - t0;
            purgeNanos += took;
            if (took > purgeMaxNanos) { purgeMaxNanos = took; }
            pp_pool_reset(&pool, emptied[i], kr == 0);
            if (pool.resets + pool.retired <= 16 || !(pool.resets % 64) || kr) {
                say("donor-pool: object %u free again: purge kr=%d in %.2f ms (%s); resets=%llu", emptied[i], kr,
                    took / 1e6, kr ? "retired" : "zeroed", pool.resets);
            }
        }
    }
    os_unfair_lock_unlock(&lock);
}

// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "SharedMemory.h"

NS_ASSUME_NONNULL_BEGIN
/// Puts the donor pool (purgeable objects whose donors have ended) behind madeira-unix
/// 0148's guest hooks, once per process; log gets each logged line. False if a pool is
/// already installed, there are no or too many objects, or the bookkeeping cannot be allocated.
bool pp_guest_pool_install(NSArray<PPMemoryRegion *> *objects, void (*log)(const char *));
/// The pool's counters: objects, bytes, live, leases, served, served_bytes, released_bytes,
/// detaches, detached_bytes, resets, retired, refused, unmatched_bytes, map_failures,
/// purge_ms_total, purge_ms_max, and the objects' resident_bytes and swapped_bytes (in the
/// compressor). All zero before install.
NSDictionary<NSString *, NSNumber *> *pp_guest_pool_stats(void);

/// madeira-unix 0148's hooks (weak imports in ntdll's unix side).
int playport_guest_memory_backing(void * _Nullable address, size_t bytes);
void playport_guest_memory_released(void * _Nullable address, size_t bytes, int detached);
NS_ASSUME_NONNULL_END

// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "SharedMemory.h"

NS_ASSUME_NONNULL_BEGIN
/// Puts the donor pool (purgeable objects whose donors have ended) behind madeira-unix
/// 0148's guest hooks, once per process; log gets each logged line. False if a pool is
/// already installed, there are no or too many objects, or the bookkeeping cannot be allocated.
bool pp_guest_pool_install(NSArray<PPMemoryRegion *> *objects, void (*log)(const char *));
/// The pool's counters: objects, bytes, live, served, served_bytes, released_bytes,
/// detaches, detached_bytes, resets, retired, refused, unmatched_bytes, map_failures,
/// purge_ms_total, purge_ms_max, stale_bytes (free, not yet zeroed), reuses (takes that zeroed
/// stale pages), zeroed_bytes, zero_ms_total, zero_us_max, purges_pending, and the objects'
/// resident_bytes and swapped_bytes (in the compressor), and the time in the hooks: back_ms_total,
/// back_us_max, releases, release_ms_total, release_us_max; the MADV_ZERO share of the zeroing
/// (madv_zeroed_bytes, madv_zero_ms_total, madv_failures); growing (0 while stopped) and
/// growth_refused. All zero before install.
NSDictionary<NSString *, NSNumber *> *pp_guest_pool_stats(void);
/// Lets the pool take pages it has not used since their object's last purge (growing), or
/// only stale ones (the phone is low; DonorPool's growth check).
void pp_guest_pool_set_growth(bool growing);

/// madeira-unix 0148's hooks (weak imports in ntdll's unix side).
int playport_guest_memory_backing(void * _Nullable address, size_t bytes);
void playport_guest_memory_released(void * _Nullable address, size_t bytes, int detached);
NS_ASSUME_NONNULL_END

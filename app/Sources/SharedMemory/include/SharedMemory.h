// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
/// A named, ledger-tagged Mach memory object. The creator owns its footprint;
/// XPC transports a send right (never a numeric port name or the buffer bytes).
@interface PPMemoryRegion : NSObject <NSSecureCoding>
@property(nonatomic, readonly) uint64_t byteCount;
@property(nonatomic, readonly) uint64_t token;
- (nullable void *)mapWithError:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, NSNumber *> *)pageCounts;
@end

PPMemoryRegion * _Nullable pp_memory_create(uint64_t bytes, uint64_t token, NSError * _Nullable * _Nullable error);
/// The same transport for a purgeable (set non-volatile) object allocated by this task, which owns it.
PPMemoryRegion * _Nullable pp_memory_create_purgeable(uint64_t bytes, uint64_t token, NSError * _Nullable * _Nullable error);
/// The object's purgeable state as seen through this task's mapping
/// (VM_PURGABLE_NONVOLATILE 0, VOLATILE 1, EMPTY 2), -1 if unmappable, -1000-kr if not purgeable.
int pp_memory_purgeable_state(PPMemoryRegion *region);
NSDictionary<NSString *, NSNumber *> *pp_memory_snapshot(void);
/// The whole phone's VM counters (host_statistics64, page counts as bytes) and jetsam's
/// kern.memorystatus_level (percent available) and _vm_pressure_level (1 normal, 2 warn, 4 critical; -1 unreadable).
NSDictionary<NSString *, NSNumber *> *pp_memory_system(void);
/// Ordinary app memory (this task's own footprint), every byte written with incompressible words; NULL if refused.
void * _Nullable pp_memory_ordinary(uint64_t bytes, uint64_t seed);
void pp_memory_ordinary_release(void * _Nullable address, uint64_t bytes);
/// Runtime mappings belong to Wine, not the transport object's destructor.
bool pp_memory_map_backing(PPMemoryRegion *region, void *address, int protection);
/// Maps bytes of the object from offset at address (RW, shared, replacing what is there:
/// VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE); 0 or the kern_return_t. The mapping is the caller's.
int pp_memory_map_range(PPMemoryRegion *region, uint64_t offset, uint64_t bytes, void *address);
/// Purges a purgeable object's pages (VM_PURGABLE_EMPTY) and makes it non-volatile again, so
/// every page reads zero; 0 or the kern_return_t. Every view of it then reads zero.
int pp_memory_empty(PPMemoryRegion *region);
/// Authorization control: hiding an object's footprint must not be assumed possible.
int pp_memory_nofootprint_control(void);
/// Incompressible deterministic content, covering every byte, not just lazy VM reservations.
bool pp_memory_fill(PPMemoryRegion *region, uint64_t seed);
bool pp_memory_verify(PPMemoryRegion *region, uint64_t seed);
/// Whether bytes of the object from offset all read zero (through its own view).
bool pp_memory_is_zero(PPMemoryRegion *region, uint64_t offset, uint64_t bytes);
/// memset(0) of the whole object through its own view: the nanoseconds it took, -1 if unmappable.
int64_t pp_memory_clear(PPMemoryRegion *region);
/// Zeroes bytes of the object from offset through its own view: method 0 memset, 1
/// madvise(MADV_ZERO), 2 madvise(MADV_FREE_REUSABLE) then memset; method 3 is
/// MADV_FREE_REUSABLE alone, which only gives the pages back (no zeroing promised). The
/// nanoseconds it took, or -1 with *error the errno.
int64_t pp_memory_zero_range(PPMemoryRegion *region, uint64_t offset, uint64_t bytes, int method, int *error);
/// pp_memory_fill's words at an address; pp_memory_verify_range reads them in the object from offset.
void pp_memory_fill_address(void *address, uint64_t bytes, uint64_t seed);
bool pp_memory_verify_range(PPMemoryRegion *region, uint64_t offset, uint64_t bytes, uint64_t seed);
NS_ASSUME_NONNULL_END
#import "GuestPool.h"

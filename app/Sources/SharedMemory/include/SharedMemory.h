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
/// Authorization control: hiding an object's footprint must not be assumed possible.
int pp_memory_nofootprint_control(void);
/// Incompressible deterministic content, covering every byte, not just lazy VM reservations.
bool pp_memory_fill(PPMemoryRegion *region, uint64_t seed);
bool pp_memory_verify(PPMemoryRegion *region, uint64_t seed);
NS_ASSUME_NONNULL_END

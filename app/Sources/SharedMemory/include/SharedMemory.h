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
NSDictionary<NSString *, NSNumber *> *pp_memory_snapshot(void);
/// Authorization control: hiding an object's footprint must not be assumed possible.
int pp_memory_nofootprint_control(void);
/// Incompressible deterministic content, covering every byte, not just lazy VM reservations.
bool pp_memory_fill(PPMemoryRegion *region, uint64_t seed);
bool pp_memory_verify(PPMemoryRegion *region, uint64_t seed);
NS_ASSUME_NONNULL_END

// SPDX-License-Identifier: GPL-3.0-or-later
#import "SharedMemory.h"
#include <mach/mach.h>
// iOS's SDK deliberately omits these two Mach interfaces; libsystem_kernel
// exports them. Their MIG ABI is the same as the public kernel declarations.
extern kern_return_t mach_memory_entry_get_page_counts(mach_port_t, uint64_t *, uint64_t *, uint64_t *);
extern kern_return_t mach_memory_entry_ownership(mach_port_t, mach_port_t, int, int);
#include <mach/memory_object_types.h>
#include <mach/vm_statistics.h>
#include <os/proc.h>
#include <xpc/xpc.h>
#include <stdatomic.h>
#include <sys/mman.h>

// An individually transported object is bounded; larger arenas use chunks.
static const uint64_t maxBytes = 256ULL << 20;
static NSError *failure(kern_return_t code, NSString *operation) {
    return [NSError errorWithDomain:@"PlayportSharedMemory" code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %s (%d)", operation, mach_error_string(code), code]}];
}

@interface PPMemoryRegion ()
- (instancetype)initWithPort:(mach_port_t)port bytes:(uint64_t)bytes token:(uint64_t)token;
- (int)requestNoFootprint;
- (bool)mapBackingAt:(void *)address protection:(int)protection;
@end
@implementation PPMemoryRegion {
    mach_port_t _entry;
    vm_address_t _address;
    uint64_t _byteCount, _token;
}
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithPort:(mach_port_t)port bytes:(uint64_t)bytes token:(uint64_t)token {
    if ((self = [super init])) { _entry = port; _byteCount = bytes; _token = token; }
    return self;
}
- (uint64_t)byteCount { return _byteCount; }
- (uint64_t)token { return _token; }
- (void)encodeWithCoder:(NSCoder *)coder {
    if (![coder isKindOfClass:[NSXPCCoder class]]) {
        [NSException raise:NSInvalidArgumentException format:@"Shared RAM requires an XPC coder"];
    }
    xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_mach_send(dictionary, "entry", _entry);
    xpc_dictionary_set_uint64(dictionary, "bytes", _byteCount);
    xpc_dictionary_set_uint64(dictionary, "token", _token);
    [(NSXPCCoder *)coder encodeXPCObject:dictionary forKey:@"region"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if (![coder isKindOfClass:[NSXPCCoder class]]) { return nil; }
    xpc_object_t dictionary = [(NSXPCCoder *)coder decodeXPCObjectOfType:XPC_TYPE_DICTIONARY forKey:@"region"];
    if (!dictionary) { return nil; }
    uint64_t bytes = xpc_dictionary_get_uint64(dictionary, "bytes");
    uint64_t token = xpc_dictionary_get_uint64(dictionary, "token");
    mach_port_t port = xpc_dictionary_copy_mach_send(dictionary, "entry");
    if (!MACH_PORT_VALID(port) || !bytes || bytes > maxBytes || bytes % vm_page_size) {
        if (MACH_PORT_VALID(port)) { mach_port_deallocate(mach_task_self(), port); }
        return nil;
    }
    return [self initWithPort:port bytes:bytes token:token];
}
- (void *)mapWithError:(NSError **)error {
    if (_address) { return (void *)(uintptr_t)_address; }
    kern_return_t kr = vm_map(mach_task_self(), &_address, _byteCount, 0,
        VM_FLAGS_ANYWHERE, _entry, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE,
        VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        _address = 0;
        if (error) { *error = failure(kr, @"map shared RAM"); }
        return NULL;
    }
    return (void *)(uintptr_t)_address;
}
- (NSDictionary *)pageCounts {
    uint64_t resident = 0, dirty = 0, swapped = 0;
    kern_return_t kr = mach_memory_entry_get_page_counts(_entry, &resident, &dirty, &swapped);
    return @{@"kr": @(kr), @"resident": @(resident * vm_page_size),
             @"dirty": @(dirty * vm_page_size), @"swapped": @(swapped * vm_page_size)};
}
- (bool)mapBackingAt:(void *)address protection:(int)protection {
    if (!address || (uintptr_t)address % vm_page_size || protection != (PROT_READ | PROT_WRITE)) { return false; }
    vm_address_t target = (vm_address_t)address;
    kern_return_t kr = vm_map(mach_task_self(), &target, _byteCount, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, _entry, 0, FALSE,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    // Deliberately do not record target in _address: Wine owns this mapping.
    return kr == KERN_SUCCESS && target == (vm_address_t)address;
}
- (int)requestNoFootprint {
    return mach_memory_entry_ownership(_entry, MACH_PORT_NULL, VM_LEDGER_TAG_DEFAULT, VM_LEDGER_FLAG_NO_FOOTPRINT);
}
- (void)dealloc {
    if (_address) { vm_deallocate(mach_task_self(), _address, _byteCount); }
    if (MACH_PORT_VALID(_entry)) { mach_port_deallocate(mach_task_self(), _entry); }
}
@end

PPMemoryRegion *pp_memory_create(uint64_t bytes, uint64_t token, NSError **error) {
    if (!bytes || bytes > maxBytes || bytes % vm_page_size) {
        if (error) { *error = failure(KERN_INVALID_ARGUMENT, @"shared RAM size"); }
        return nil;
    }
    memory_object_size_t size = bytes;
    mach_port_t entry = MACH_PORT_NULL;
    kern_return_t kr = mach_make_memory_entry_64(mach_task_self(), &size, 0,
        MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED | VM_PROT_READ | VM_PROT_WRITE,
        &entry, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS || size != bytes) {
        if (MACH_PORT_VALID(entry)) { mach_port_deallocate(mach_task_self(), entry); }
        if (error) { *error = failure(kr ? kr : KERN_INVALID_ARGUMENT, @"create shared RAM"); }
        return nil;
    }
    return [[PPMemoryRegion alloc] initWithPort:entry bytes:bytes token:token];
}

bool pp_memory_map_backing(PPMemoryRegion *region, void *address, int protection) {
    return [region mapBackingAt:address protection:protection];
}
static _Atomic(PPMemoryBackingProvider) backingProvider;
void pp_memory_set_backing_provider(PPMemoryBackingProvider provider) {
    atomic_store_explicit(&backingProvider, provider, memory_order_release);
}
int playport_memory_backing(void *address, size_t bytes, int protection) {
    PPMemoryBackingProvider provider = atomic_load_explicit(&backingProvider, memory_order_acquire);
    return provider ? provider(address, bytes, protection) : 0;
}

NSDictionary *pp_memory_snapshot(void) {
    struct task_vm_info info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return @{@"pid": @(getpid()), @"kr": @(kr), @"footprint": @(info.phys_footprint),
             @"resident": @(info.resident_size), @"compressed": @(info.compressed),
             @"internal": @(info.internal), @"external": @(info.external),
             @"available": @(os_proc_available_memory())};
}
int pp_memory_nofootprint_control(void) {
    NSError *error = nil;
    PPMemoryRegion *region = pp_memory_create(vm_page_size, 0, &error);
    if (!region) { return (int)error.code; }
    return [region requestNoFootprint];
}

// SplitMix64's bijection: random-looking independent words, cheaply reproduced.
static uint64_t word(uint64_t i, uint64_t seed) {
    uint64_t z = i + seed + UINT64_C(0x9e3779b97f4a7c15);
    z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
    return z ^ (z >> 31);
}
bool pp_memory_fill(PPMemoryRegion *region, uint64_t seed) {
    volatile uint64_t *p = [region mapWithError:NULL];
    if (!p) { return false; }
    for (uint64_t i = 0, n = region.byteCount / 8; i < n; ++i) { p[i] = word(i, seed); }
    return true;
}
bool pp_memory_verify(PPMemoryRegion *region, uint64_t seed) {
    const volatile uint64_t *p = [region mapWithError:NULL];
    if (!p) { return false; }
    for (uint64_t i = 0, n = region.byteCount / 8; i < n; ++i) {
        if (p[i] != word(i, seed)) { return false; }
    }
    return true;
}

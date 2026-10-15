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
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <string.h>
#include <errno.h>
#include <time.h>

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
- (kern_return_t)mapRange:(uint64_t)offset bytes:(uint64_t)bytes at:(void *)address;
- (kern_return_t)empty;
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
- (kern_return_t)mapRange:(uint64_t)offset bytes:(uint64_t)bytes at:(void *)address {
    if (!address || (uintptr_t)address % vm_page_size || offset % vm_page_size || !bytes || bytes % vm_page_size
        || offset > _byteCount || bytes > _byteCount - offset) { return KERN_INVALID_ARGUMENT; }
    vm_address_t target = (vm_address_t)address;
    kern_return_t kr = vm_map(mach_task_self(), &target, bytes, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, _entry, offset, FALSE,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    // Wine owns this mapping; _address is this object's own view, not it.
    return kr == KERN_SUCCESS && target != (vm_address_t)address ? KERN_FAILURE : kr;
}
- (kern_return_t)empty {
    // vm_purgable_control names the object by an address in this task: a
    // temporary view of the whole object, no page touched.
    vm_address_t view = 0;
    kern_return_t kr = vm_map(mach_task_self(), &view, _byteCount, 0, VM_FLAGS_ANYWHERE, _entry, 0, FALSE,
        VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) { return kr; }
    int state = VM_PURGABLE_EMPTY;
    kr = vm_purgable_control(mach_task_self(), view, VM_PURGABLE_SET_STATE, &state);
    if (kr == KERN_SUCCESS) {
        state = VM_PURGABLE_NONVOLATILE;
        kr = vm_purgable_control(mach_task_self(), view, VM_PURGABLE_SET_STATE, &state);
    }
    vm_deallocate(mach_task_self(), view, _byteCount);
    return kr;
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

PPMemoryRegion *pp_memory_create_purgeable(uint64_t bytes, uint64_t token, NSError **error) {
    if (!bytes || bytes > maxBytes || bytes % vm_page_size) {
        if (error) { *error = failure(KERN_INVALID_ARGUMENT, @"purgeable RAM size"); }
        return nil;
    }
    // vm_allocate is mach_vm_allocate on a 64-bit task; the SDK refuses mach_vm.h.
    vm_address_t address = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &address, bytes, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
    if (kr != KERN_SUCCESS) {
        if (error) { *error = failure(kr, @"allocate purgeable RAM"); }
        return nil;
    }
    int state = VM_PURGABLE_NONVOLATILE;
    kr = vm_purgable_control(mach_task_self(), address, VM_PURGABLE_SET_STATE, &state);
    memory_object_size_t size = bytes;
    mach_port_t entry = MACH_PORT_NULL;
    if (kr == KERN_SUCCESS) {
        // No copy flag: the entry names the purgeable object itself, so this task stays its owner.
        kr = mach_make_memory_entry_64(mach_task_self(), &size, address,
            VM_PROT_READ | VM_PROT_WRITE, &entry, MACH_PORT_NULL);
    }
    // The entry holds the object; this task's own mapping is not needed.
    vm_deallocate(mach_task_self(), address, bytes);
    if (kr != KERN_SUCCESS || size != bytes) {
        if (MACH_PORT_VALID(entry)) { mach_port_deallocate(mach_task_self(), entry); }
        if (error) { *error = failure(kr ? kr : KERN_INVALID_ARGUMENT, @"purgeable RAM entry"); }
        return nil;
    }
    return [[PPMemoryRegion alloc] initWithPort:entry bytes:bytes token:token];
}

int pp_memory_purgeable_state(PPMemoryRegion *region) {
    void *address = [region mapWithError:NULL];
    if (!address) { return -1; }
    int state = 0;
    kern_return_t kr = vm_purgable_control(mach_task_self(), (vm_address_t)address, VM_PURGABLE_GET_STATE, &state);
    return kr == KERN_SUCCESS ? state : -1000 - kr;
}

int pp_memory_map_range(PPMemoryRegion *region, uint64_t offset, uint64_t bytes, void *address) {
    return [region mapRange:offset bytes:bytes at:address];
}
int pp_memory_empty(PPMemoryRegion *region) {
    return [region empty];
}

bool pp_memory_map_backing(PPMemoryRegion *region, void *address, int protection) {
    return [region mapBackingAt:address protection:protection];
}

NSDictionary *pp_memory_snapshot(void) {
    struct task_vm_info info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return @{@"pid": @(getpid()), @"kr": @(kr), @"footprint": @(info.phys_footprint),
             @"resident": @(info.resident_size), @"compressed": @(info.compressed),
             @"internal": @(info.internal), @"external": @(info.external),
             @"available": @(os_proc_available_memory()),
             @"graphics": @(info.ledger_tag_graphics_footprint + info.ledger_tag_graphics_footprint_compressed),
             @"graphics_nofootprint": @(info.ledger_tag_graphics_nofootprint
                                        + info.ledger_tag_graphics_nofootprint_compressed),
             @"purgeable_nonvolatile": @(info.ledger_purgeable_nonvolatile
                                         + info.ledger_purgeable_novolatile_compressed)};
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

bool pp_memory_is_zero(PPMemoryRegion *region, uint64_t offset, uint64_t bytes) {
    const volatile uint64_t *p = [region mapWithError:NULL];
    if (!p || offset % 8 || offset > region.byteCount || bytes > region.byteCount - offset) { return false; }
    p += offset / 8;
    for (uint64_t i = 0, n = bytes / 8; i < n; ++i) {
        if (p[i]) { return false; }
    }
    return true;
}
int64_t pp_memory_clear(PPMemoryRegion *region) {
    void *p = [region mapWithError:NULL];
    if (!p) { return -1; }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    memset(p, 0, region.byteCount);
    return (int64_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0);
}
int64_t pp_memory_zero_range(PPMemoryRegion *region, uint64_t offset, uint64_t bytes, int method, int *error) {
    char *p = [region mapWithError:NULL];
    *error = 0;
    if (!p || offset % vm_page_size || bytes % vm_page_size || offset > region.byteCount
        || bytes > region.byteCount - offset) { *error = EINVAL; return -1; }
    p += offset;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (method >= 1 && method <= 3) {
        if (madvise(p, bytes, method == 1 ? MADV_ZERO : MADV_FREE_REUSABLE)) { *error = errno; return -1; }
    }
    if (method == 0 || method == 2) { memset(p, 0, bytes); }
    return (int64_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0);
}
void pp_memory_fill_address(void *address, uint64_t bytes, uint64_t seed) {
    volatile uint64_t *p = address;
    for (uint64_t i = 0, n = bytes / 8; i < n; ++i) { p[i] = word(i, seed); }
}
bool pp_memory_reads_byte(const void *address, uint64_t bytes, uint8_t value) {
    const volatile uint64_t *p = address;
    uint64_t word = value * UINT64_C(0x0101010101010101);
    if (!p || (uintptr_t)address % 8 || bytes % 8) { return false; }
    for (uint64_t i = 0, n = bytes / 8; i < n; ++i) {
        if (p[i] != word) { return false; }
    }
    return true;
}
bool pp_memory_verify_range(PPMemoryRegion *region, uint64_t offset, uint64_t bytes, uint64_t seed) {
    const volatile uint64_t *p = [region mapWithError:NULL];
    if (!p || offset % 8 || offset > region.byteCount || bytes > region.byteCount - offset) { return false; }
    p += offset / 8;
    for (uint64_t i = 0, n = bytes / 8; i < n; ++i) {
        if (p[i] != word(i, seed)) { return false; }
    }
    return true;
}

static int64_t sysctlInt(const char *name) {
    int value = 0;
    size_t size = sizeof value;
    return sysctlbyname(name, &value, &size, NULL, 0) == 0 ? value : -1;
}
NSDictionary *pp_memory_system(void) {
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count);
    uint64_t page = vm_kernel_page_size;
    return @{@"kr": @(kr), @"free": @(vm.free_count * page), @"active": @(vm.active_count * page),
             @"inactive": @(vm.inactive_count * page), @"speculative": @(vm.speculative_count * page),
             @"wired": @(vm.wire_count * page), @"purgeable": @(vm.purgeable_count * page),
             @"internal": @(vm.internal_page_count * page), @"external": @(vm.external_page_count * page),
             @"compressor": @(vm.compressor_page_count * page),
             @"compressed_data": @(vm.total_uncompressed_pages_in_compressor * page),
             @"compressions": @(vm.compressions), @"decompressions": @(vm.decompressions),
             @"swapins": @(vm.swapins), @"swapouts": @(vm.swapouts),
             @"level": @(sysctlInt("kern.memorystatus_level")),
             @"pressure": @(sysctlInt("kern.memorystatus_vm_pressure_level"))};
}
void *pp_memory_ordinary(uint64_t bytes, uint64_t seed) {
    vm_address_t address = 0;
    if (vm_allocate(mach_task_self(), &address, bytes, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) { return NULL; }
    volatile uint64_t *p = (volatile uint64_t *)address;
    for (uint64_t i = 0, n = bytes / 8; i < n; ++i) { p[i] = word(i, seed); }
    return (void *)address;
}
void pp_memory_ordinary_release(void *address, uint64_t bytes) {
    if (address) { vm_deallocate(mach_task_self(), (vm_address_t)address, bytes); }
}

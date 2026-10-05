/* Production native VM core, routing, protection transaction and Wine's
 * protection conversions; real mappings, mock Wine view/page metadata.
 * No wineserver/rbtree/Mach handler or PE thunk execution.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define main views_test_main
#define set_page_vprot views_set_page_vprot
#define get_unix_prot views_get_unix_prot
#include "views_test.c"
#undef main
#undef set_page_vprot
#undef get_unix_prot
#include <string.h>

typedef int BOOL;
typedef uint32_t ULONG, DWORD;
typedef unsigned char BYTE;
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
typedef void *HANDLE;
#define TRUE 1
#define FALSE 0
#define STATUS_NOT_COMMITTED 6
#define STATUS_INVALID_PARAMETER_3 7
#define PAGE_NOACCESS 1
#define PAGE_READONLY 2
#define PAGE_READWRITE 4
#define PAGE_EXECUTE 0x10
#define PAGE_EXECUTE_READ 0x20
#define PAGE_EXECUTE_READWRITE 0x40
#define PAGE_WRITECOPY 8
#define PAGE_EXECUTE_WRITECOPY 0x80
#define PAGE_GUARD 0x100
#define PAGE_NOCACHE 0x200
#define SEC_IMAGE 0x1000000
#define SEC_NOCACHE 0x10000000
#define VPROT_WOW64_IMAGE 0x2000
#define VPROT_WRITECOPY 8
#define VPROT_GUARD 0x10
#define VPROT_WRITEWATCH 0x40
#define STATUS_INVALID_PAGE_PROTECTION 14
#define STATUS_ACCESS_VIOLATION 17
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define MEM_DECOMMIT 0x4000
#define MEM_RELEASE 0x8000
#define MEM_TOP_DOWN 0x100000
#define VPROT_EXEC 4
#define VPROT_WOW64_VM 0x4000
#define IMAGE_FILE_LARGE_ADDRESS_AWARE 0x20
#define max(a,b) ((a) > (b) ? (a) : (b))
#define min(a,b) ((a) < (b) ? (a) : (b))
static const size_t page_size = 0x1000, page_mask = 0xfff, host_page_size = 0x4000;
static uintptr_t bases[2];
static unsigned char pages[2][0x100000];
static int fail_replace;
static void *current_owner;
typedef struct
{
    unsigned int ImageCharacteristics;
    SIZE_T MaximumStackSize, CommittedStackSize;
} SECTION_IMAGE_INFORMATION;
static SECTION_IMAGE_INFORMATION image;
static void *ios_jit_current_peb(void) { return current_owner; }
#define ios_cur_image_info() (&image)
#define NtCurrentProcess() ((HANDLE)(intptr_t)-1)
static void set_page_vprot(const void *addr, size_t size, unsigned int prot)
{
    uintptr_t p = (uintptr_t)addr;
    for (unsigned i = 0; i < 2; ++i)
        if (p >= bases[i] && p - bases[i] < IOS_WOW64_WINDOW_SIZE)
        {
            assert(size <= IOS_WOW64_WINDOW_SIZE - (p - bases[i]));
            memset(pages[i] + (p - bases[i]) / page_size, prot, size / page_size);
            ++page_updates;
            return;
        }
    abort();
}
static unsigned int get_page_vprot(const void *addr)
{
    uintptr_t p = (uintptr_t)addr;
    for (unsigned i = 0; i < 2; ++i)
        if (p >= bases[i] && p - bases[i] < IOS_WOW64_WINDOW_SIZE)
            return pages[i][(p - bases[i]) / page_size];
    abort();
}
#include "wow64_vprot.h"
static void *test_mmap(void *addr, size_t size, int prot, int flags, int fd, off_t off)
{
    if (fail_replace) return MAP_FAILED;
    return mmap(addr, size, prot, flags, fd, off);
}
#define mprotect test_mprotect
#define mmap test_mmap
#include "wow64_vm.h"
#undef mmap
#undef mprotect
#define dprintf(...) ((void)0)
#include "vm_api.h"
#undef dprintf

static NTSTATUS routed_bits(unsigned op, void **addr, size_t *size, ULONG type, ULONG prot,
                            uintptr_t bits, ULONG *old)
{
    NTSTATUS status = -1;
    assert(ios_wow64_route_vm(op, NtCurrentProcess(), addr, size, type, prot, bits, old, &status));
    return status;
}
static NTSTATUS routed(unsigned op, void **addr, size_t *size, ULONG type, ULONG prot, ULONG *old)
{
    return routed_bits(op, addr, size, type, prot, 0, old);
}
static void inaccessible(void *addr, int execute)
{
    pid_t child = fork();
    assert(child >= 0);
    if (!child)
    {
        signal(SIGSEGV, SIG_DFL);
        if (execute) ((void (*)(void))addr)();
        else *(volatile char *)addr = 1;
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
}
#ifdef WOW64_VM_HELPERS_ONLY
int vm_test_main(void)
#else
int main(void)
#endif
{
    struct rlimit core = {0, 0};
    assert(!setrlimit(RLIMIT_CORE, &core));
    bases[0] = reserve(); bases[1] = reserve();
    int owner_a, owner_b;
    ios_wow64_windows[0].owner = &owner_a; ios_wow64_windows[0].base = bases[0];
    ios_wow64_windows[1].owner = &owner_b; ios_wow64_windows[1].base = bases[1];
    current_owner = &owner_a;
    /* Guest limits are independent of the high base and count/mask form. */
    uint64_t end;
    for (unsigned bits = 1; bits <= 21; ++bits)
    {
        end = IOS_WOW64_WINDOW_SIZE;
        assert(!ios_wow64_vm_limit(bits, &end));
        assert(end == (UINT64_C(1) << (32 - bits)));
    }
    const uintptr_t masks[] = {32, 0xffff, 0x10001, 0x7fffffff, 0x80000000, UINT32_MAX,
                              UINT64_C(0x1ffffffff), UINTPTR_MAX};
    const uint64_t ends[] = {64, 0x10000, 0x20000, 0x80000000, 0x100000000,
                             0x100000000, 0x100000000, 0x100000000};
    for (unsigned i = 0; i < sizeof(masks) / sizeof(*masks); ++i)
    {
        end = IOS_WOW64_WINDOW_SIZE;
        assert(!ios_wow64_vm_limit(masks[i], &end) && end == ends[i]);
    }
    for (unsigned bits = 22; bits < 32; ++bits)
    {
        end = IOS_WOW64_WINDOW_SIZE;
        assert(ios_wow64_vm_limit(bits, &end) == STATUS_INVALID_PARAMETER_3);
        assert(end == IOS_WOW64_WINDOW_SIZE);
    }
    end = IOS_WOW64_WINDOW_SIZE;
    assert(ios_wow64_vm_limit(33, &end) == STATUS_INVALID_PARAMETER_3 && end == IOS_WOW64_WINDOW_SIZE);
    void *slots[3] = {0};
    size_t lengths[3] = {1, 1, 1};
    unsigned gap_updates = page_updates;
    int gap_descriptors = descriptor_count;
    fail_after = 0;
    assert(routed_bits(0, &slots[0], &lengths[0], MEM_COMMIT, PAGE_READWRITE, 14, NULL) == STATUS_NO_MEMORY);
    assert(!slots[0] && lengths[0] == 1 && page_updates == gap_updates && descriptor_count == gap_descriptors);
    fail_after = -1; fail_protect = 1;
    assert(routed_bits(0, &slots[0], &lengths[0], MEM_COMMIT, PAGE_READWRITE, 14, NULL) == STATUS_ACCESS_DENIED);
    assert(!slots[0] && lengths[0] == 1 && descriptor_count == gap_descriptors);
    fail_protect = 0;
    assert(!routed_bits(0, &slots[0], &lengths[0], MEM_COMMIT, PAGE_READWRITE, 14, NULL));
    assert(!routed_bits(0, &slots[1], &lengths[1], MEM_RESERVE, PAGE_READWRITE, 14, NULL));
    assert(!routed_bits(0, &slots[2], &lengths[2], MEM_COMMIT | MEM_TOP_DOWN, PAGE_EXECUTE_READWRITE, 14, NULL));
    assert(slots[0] == (void *)(bases[0] + 0x10000) && slots[1] == (void *)(bases[0] + 0x20000));
    assert(slots[2] == (void *)(bases[0] + 0x30000));
    assert(lengths[0] == 0x4000 && lengths[1] == 0x4000 && lengths[2] == 0x4000);
    *(int *)slots[0] = 11; *(int *)slots[2] = 22;
    inaccessible(slots[1], 0); inaccessible(slots[2], 1);
    void *gap = NULL;
    size_t gap_size = 1;
    assert(routed_bits(0, &gap, &gap_size, MEM_RESERVE, PAGE_READWRITE, 14, NULL) == STATUS_CONFLICTING_ADDRESSES);
    assert(!gap && gap_size == 1);
    assert(routed_bits(0, &gap, &gap_size, MEM_COMMIT, PAGE_READWRITE, 16, NULL) == STATUS_CONFLICTING_ADDRESSES);
    assert(routed_bits(0, &gap, &gap_size, MEM_COMMIT, PAGE_READWRITE, 22, NULL) == STATUS_INVALID_PARAMETER_3);
    assert(routed_bits(0, &gap, &gap_size, MEM_COMMIT, PAGE_READWRITE, 33, NULL) == STATUS_INVALID_PARAMETER_3);
    assert(routed_bits(0, &gap, &gap_size, MEM_COMMIT | MEM_TOP_DOWN | 0x400000, PAGE_READWRITE, 14, NULL) == STATUS_NOT_SUPPORTED);
    gap_size = SIZE_MAX;
    assert(routed_bits(0, &gap, &gap_size, MEM_COMMIT, PAGE_READWRITE, 14, NULL) == STATUS_INVALID_PARAMETER);
    assert(!gap && gap_size == SIZE_MAX);
    NTSTATUS remote_status = -1;
    gap_size = 1;
    assert(ios_wow64_route_vm(0, (HANDLE)123, &gap, &gap_size, MEM_COMMIT, PAGE_READWRITE, 14, NULL, &remote_status));
    assert(remote_status == STATUS_ACCESS_DENIED && !gap && gap_size == 1);
    /* Same logical allocation in a disjoint owner cannot see these contents. */
    current_owner = &owner_b;
    assert(!routed_bits(0, &gap, &gap_size, MEM_COMMIT, PAGE_READWRITE, 14, NULL));
    assert(gap == (void *)(bases[1] + 0x10000) && !*(int *)gap);
    *(int *)gap = 33;
    current_owner = &owner_a;
    for (unsigned i = 0; i < 3; ++i)
    {
        size_t release = 0;
        assert(!routed(1, &slots[i], &release, MEM_RELEASE, 0, NULL));
    }
    assert(*(int *)gap == 33);
    current_owner = &owner_b;
    size_t release = 0;
    assert(!routed(1, &gap, &release, MEM_RELEASE, 0, NULL));
    current_owner = &owner_a;
    assert(descriptor_count == gap_descriptors);
    assert(find_view((void *)bases[0], IOS_WOW64_WINDOW_SIZE)->protect == VPROT_WOW64_HOLE);
    /* Counts/masks apply to explicit host-window storage as guest offsets. */
    gap = (void *)(bases[0] + 0x10000); gap_size = 1;
    assert(!routed_bits(0, &gap, &gap_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, 15, NULL));
    void *past = (void *)(bases[0] + 0x1ffff); size_t past_size = 2;
    assert(routed_bits(0, &past, &past_size, MEM_COMMIT, PAGE_READWRITE, 15, NULL) == STATUS_INVALID_PARAMETER);
    release = 0;
    assert(!routed(1, &gap, &release, MEM_RELEASE, 0, NULL));
    gap = (void *)(bases[0] + 0x7fffffff); gap_size = 2;
    assert(routed(0, &gap, &gap_size, MEM_RESERVE, PAGE_READWRITE, NULL) == STATUS_INVALID_PARAMETER);
    /* LAA NULL top-down allocation can reach the final host page below 4 GiB. */
    image.ImageCharacteristics = IMAGE_FILE_LARGE_ADDRESS_AWARE;
    gap = NULL; gap_size = 0x10000;
    assert(!routed_bits(0, &gap, &gap_size, MEM_COMMIT | MEM_TOP_DOWN, PAGE_READWRITE, UINT32_MAX, NULL));
    assert(gap == (void *)(bases[0] + 0xffff0000) && gap_size == 0x10000);
    release = 0;
    assert(!routed(1, &gap, &release, MEM_RELEASE, 0, NULL));
    image.ImageCharacteristics = 0;
    void *addr = (void *)(bases[0] + 0x410003), *orig = addr;
    size_t size = 0x8001;
    int descriptors = descriptor_count;
    unsigned updates = page_updates;
    fail_after = 0;
    assert(routed(0, &addr, &size, MEM_RESERVE, PAGE_READWRITE, NULL) == STATUS_NO_MEMORY);
    assert(addr == orig && size == 0x8001 && descriptor_count == descriptors && page_updates == updates);
    fail_after = -1;
    fail_protect = 1;
    assert(routed(0, &addr, &size, MEM_RESERVE, PAGE_READWRITE, NULL) == STATUS_ACCESS_DENIED);
    assert(addr == orig && size == 0x8001 && descriptor_count == descriptors);
    fail_protect = 0;
    assert(!routed(0, &addr, &size, MEM_RESERVE, PAGE_READWRITE, NULL));
    assert(addr == (void *)(bases[0] + 0x410000) && size == 0xc000);
    assert(!(get_page_vprot(addr) & VPROT_COMMITTED));
    inaccessible(addr, 0);
    ULONG old = 0xdead;
    assert(routed(2, &addr, &size, 0, PAGE_READWRITE, &old) == STATUS_NOT_COMMITTED && old == 0xdead);
    void *sub = (char *)addr + 0x4003;
    size_t subsize = 1;
    assert(!routed(0, &sub, &subsize, MEM_COMMIT, PAGE_EXECUTE_READWRITE, NULL));
    assert(sub == (char *)addr + 0x4000 && subsize == 0x4000);
    assert(get_page_vprot(sub) == (VPROT_READ | VPROT_WRITE | VPROT_EXEC | VPROT_COMMITTED));
    memset(sub, 0xcc, subsize);
    inaccessible(sub, 1); /* Native NX even with logical EXEC. */
    assert(routed(2, &addr, &size, 0, PAGE_READONLY, &old) == STATUS_NOT_COMMITTED);
    assert(old == 0xdead);
    fail_protect = 1;
    assert(routed(2, &sub, &subsize, 0, PAGE_READONLY, &old) == STATUS_ACCESS_DENIED);
    assert(old == 0xdead && get_page_vprot(sub) & VPROT_WRITE);
    fail_protect = 0;
    assert(!routed(2, &sub, &subsize, 0, PAGE_READONLY, &old));
    assert(old == PAGE_EXECUTE_READWRITE && get_page_vprot(sub) == (VPROT_READ | VPROT_COMMITTED));
    inaccessible(sub, 0);
    assert(!routed(2, &sub, &subsize, 0, PAGE_EXECUTE, &old));
    assert(old == PAGE_READONLY && get_page_vprot(sub) == (VPROT_EXEC | VPROT_COMMITTED));
    assert(*(unsigned char *)sub == 0xcc); /* Decoder can read execute-only pages. */
    inaccessible(sub, 0); inaccessible(sub, 1);
    fail_replace = 1;
    assert(routed(1, &sub, &subsize, MEM_DECOMMIT, 0, NULL) == STATUS_NO_MEMORY);
    assert(get_page_vprot(sub) & VPROT_COMMITTED);
    fail_replace = 0;
    assert(!routed(1, &sub, &subsize, MEM_DECOMMIT, 0, NULL));
    inaccessible(sub, 0);
    assert(!get_page_vprot(sub));
    assert(!routed(0, &sub, &subsize, MEM_COMMIT, PAGE_READWRITE, NULL));
    for (unsigned i = 0; i < subsize; ++i) assert(!((unsigned char *)sub)[i]);
    /* Native pointers in another owner's window never reach native unmap. */
    void *other = (void *)(bases[1] + 0x410000);
    size_t other_size = 0x4000;
    assert(routed(0, &other, &other_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL) == STATUS_ACCESS_DENIED);
    NTSTATUS status = -1;
    assert(ios_wow64_route_vm(1, (HANDLE)123, &addr, &size, MEM_RELEASE, 0, 0, NULL, &status));
    assert(status == STATUS_ACCESS_DENIED);
    current_owner = NULL;
    assert(routed(1, &addr, &size, MEM_RELEASE, 0, NULL) == STATUS_ACCESS_DENIED);
    current_owner = &owner_b;
    assert(!routed(0, &other, &other_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL));
    *(int *)other = 42;
    current_owner = &owner_a;
    assert(routed(3, &addr, &size, 0, 0, NULL) == STATUS_NOT_SUPPORTED);
    assert(routed(0, &sub, &subsize, MEM_COMMIT | 0x400000, PAGE_READWRITE, NULL) == STATUS_NOT_SUPPORTED);
    assert(routed(0, &sub, &subsize, MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD, NULL) == STATUS_NOT_SUPPORTED);
    assert(routed(1, &addr, &size, MEM_RELEASE, 0, NULL) == STATUS_INVALID_PARAMETER);
    size_t zero = 0;
    assert(routed(1, &sub, &zero, MEM_RELEASE, 0, NULL) == STATUS_INVALID_PARAMETER && !zero);
    fail_replace = 1;
    assert(routed(1, &addr, &zero, MEM_RELEASE, 0, NULL) == STATUS_NO_MEMORY && !zero);
    fail_replace = 0;
    assert(!routed(1, &addr, &zero, MEM_RELEASE, 0, NULL) && zero == 0xc000);
    assert(find_view((void *)bases[0], IOS_WOW64_WINDOW_SIZE)->protect == VPROT_WOW64_HOLE);
    assert(descriptor_count == descriptors + 2); /* Other owner's live allocation. */
    assert(*(int *)other == 42);
    inaccessible(sub, 0);
    /* Released/adjacent holdbacks can be reused as one larger allocation. */
    size = 0x20000;
    assert(!routed(0, &addr, &size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL));
    for (size_t i = 0; i < size; ++i) assert(!((unsigned char *)addr)[i]);
    size_t decommit_all = 0;
    memset(addr, 0x55, size);
    assert(!routed(1, &addr, &decommit_all, MEM_DECOMMIT, 0, NULL) && decommit_all == size);
    assert(!routed(0, &addr, &size, MEM_COMMIT, PAGE_READWRITE, NULL));
    for (size_t i = 0; i < size; ++i) assert(!((unsigned char *)addr)[i]);
    /* Guard, overrun, overflow, cross-view and 2/4 GiB limits. */
    void *bad = (void *)(bases[0] + 0xffff);
    size_t n = 1;
    assert(routed(0, &bad, &n, MEM_RESERVE, PAGE_READWRITE, NULL) == STATUS_INVALID_PARAMETER);
    bad = (void *)(bases[0] + 0xffff0000); n = 0x14000;
    assert(routed(0, &bad, &n, MEM_RESERVE, PAGE_READWRITE, NULL) == STATUS_INVALID_PARAMETER);
    bad = (void *)(bases[0] + 0x80000000); n = 0x4000;
    assert(routed(0, &bad, &n, MEM_RESERVE, PAGE_READWRITE, NULL) == STATUS_INVALID_PARAMETER);
    image.ImageCharacteristics = IMAGE_FILE_LARGE_ADDRESS_AWARE;
    assert(!routed(0, &bad, &n, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL));
    bad = addr; n = SIZE_MAX;
    assert(routed(0, &bad, &n, MEM_COMMIT, PAGE_READWRITE, NULL) == STATUS_INVALID_PARAMETER);
    bad = (char *)addr + size - 1; n = 2;
    assert(routed(0, &bad, &n, MEM_COMMIT, PAGE_READWRITE, NULL) == STATUS_CONFLICTING_ADDRESSES);
    /* Paired bootstrap storage cannot be released, committed or protected. */
    struct file_view *bootstrap;
    assert(!ios_wow64_claim_view(bases[0], 0x7ff00000, 0x4000,
                                VPROT_READ | VPROT_WRITE | VPROT_COMMITTED, &bootstrap));
    bad = bootstrap->base; n = 0;
    assert(routed(1, &bad, &n, MEM_RELEASE, 0, NULL) == STATUS_NOT_SUPPORTED);
    n = 0x4000;
    assert(routed(2, &bad, &n, 0, PAGE_READONLY, &old) == STATUS_NOT_SUPPORTED);
    assert(routed(0, &bad, &n, MEM_COMMIT, PAGE_READWRITE, NULL) == STATUS_CONFLICTING_ADDRESSES);
    void *native = (void *)0x100000000, *guest = (void *)0x400000, *null = NULL;
    status = -1;
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &native, &n, 0, 0, 0, NULL, &status));
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &guest, &n, 0, 0, UINT32_MAX, NULL, &status));
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &null, &n, 0, 0, 0, NULL, &status));
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &null, &n, 0, 0, UINT64_C(0x1ffffffff), NULL, &status));
    current_owner = NULL;
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &null, &n, 0, 0, UINT32_MAX, NULL, &status));
    current_owner = &owner_a;
    assert(status == -1);
    /* The initial thread's 32-bit stack (ios_wow64_alloc_stack32): Wine's
     * sizes and guard layout in the owner's window, guest results only. */
    ULONG stack_base = 1, stack_limit = 2, stack_dealloc = 3;
    image.ImageCharacteristics = 0;
    image.MaximumStackSize = 0x100000; image.CommittedStackSize = 0x1000;
    current_owner = &owner_b;
    assert(ios_wow64_alloc_stack32(&owner_a, 0, 0, &stack_base, &stack_limit, &stack_dealloc) ==
           STATUS_ACCESS_DENIED);
    int owner_c;
    current_owner = &owner_c;
    assert(ios_wow64_alloc_stack32(&owner_c, 0, 0, &stack_base, &stack_limit, &stack_dealloc) ==
           STATUS_NOT_SUPPORTED);
    assert(stack_base == 1 && stack_limit == 2 && stack_dealloc == 3);
    current_owner = &owner_a;
    assert(!ios_wow64_alloc_stack32(&owner_a, 0, 0, &stack_base, &stack_limit, &stack_dealloc));
    assert(stack_base - stack_dealloc == 0x800000 && stack_limit == stack_dealloc + 2 * host_page_size);
    assert(!(stack_dealloc & granularity_mask) && stack_dealloc >= IOS_WOW64_NULL_GUARD &&
           stack_base <= UINT32_C(0x80000000));
    char *stack = (char *)(bases[0] + stack_dealloc);
    for (size_t off = 0; off < host_page_size; off += page_size)
    {
        assert(!(get_page_vprot(stack + off) & (VPROT_READ | VPROT_WRITE | VPROT_GUARD)));
        assert((get_page_vprot(stack + host_page_size + off) & (VPROT_GUARD | VPROT_READ | VPROT_WRITE)) ==
               (VPROT_GUARD | VPROT_READ | VPROT_WRITE));
    }
    inaccessible(stack, 0);
    inaccessible(stack + host_page_size, 0);
    stack[stack_limit - stack_dealloc] = 1;
    stack[stack_base - stack_dealloc - 1] = 1;
    inaccessible(stack, 1);
    /* A larger reserve keeps its size; LAA images may use the upper 2 GiB. */
    ULONG big_base, big_limit, big_dealloc;
    image.ImageCharacteristics = IMAGE_FILE_LARGE_ADDRESS_AWARE;
    assert(!ios_wow64_alloc_stack32(&owner_a, 0x900000, 0x2000, &big_base, &big_limit, &big_dealloc));
    assert(big_base - big_dealloc == 0x900000 && big_dealloc != stack_dealloc);
    check_cover(bases[0]); check_cover(bases[1]);
    check_guard(bases[0]); check_guard(bases[1]);
    ios_wow64_delete_views(bases[0]);
    assert(*(int *)other == 42);
    ios_wow64_delete_views(bases[1]);
    assert(!descriptor_count);
    puts("WoW64 VM: constrained NULL/gap/top-down, zero-bits/limits, NX, zero/reuse, owner routing and 32-bit stacks pass");
    return 0;
}

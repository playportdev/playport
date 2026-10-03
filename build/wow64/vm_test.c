/* Production native VM core and routing, real mappings, mock Wine view/page
 * metadata. No wineserver/rbtree/Mach handler or PE thunk execution.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define main views_test_main
#define set_page_vprot views_set_page_vprot
#include "views_test.c"
#undef main
#undef set_page_vprot
#include <string.h>

typedef int BOOL;
typedef uint32_t ULONG;
typedef size_t SIZE_T;
typedef void *HANDLE;
#define TRUE 1
#define FALSE 0
#define STATUS_NOT_COMMITTED 6
#define PAGE_NOACCESS 1
#define PAGE_READONLY 2
#define PAGE_READWRITE 4
#define PAGE_EXECUTE 0x10
#define PAGE_EXECUTE_READ 0x20
#define PAGE_EXECUTE_READWRITE 0x40
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define MEM_DECOMMIT 0x4000
#define MEM_RELEASE 0x8000
#define VPROT_EXEC 4
#define VPROT_WOW64_VM 0x4000
#define IMAGE_FILE_LARGE_ADDRESS_AWARE 0x20
#define max(a,b) ((a) > (b) ? (a) : (b))
#define min(a,b) ((a) < (b) ? (a) : (b))
static const size_t page_size = 0x1000;
static uintptr_t bases[2];
static unsigned char pages[2][0x100000];
static int fail_replace;
static void *current_owner;
static struct { unsigned int ImageCharacteristics; } image;
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
static NTSTATUS get_vprot_flags(ULONG protect, unsigned int *vprot, BOOL is_image)
{
    assert(!is_image);
    switch (protect)
    {
    case PAGE_NOACCESS: *vprot = 0; break;
    case PAGE_READONLY: *vprot = VPROT_READ; break;
    case PAGE_READWRITE: *vprot = VPROT_READ | VPROT_WRITE; break;
    case PAGE_EXECUTE: *vprot = VPROT_EXEC; break;
    case PAGE_EXECUTE_READ: *vprot = VPROT_READ | VPROT_EXEC; break;
    case PAGE_EXECUTE_READWRITE: *vprot = VPROT_READ | VPROT_WRITE | VPROT_EXEC; break;
    default: return STATUS_INVALID_PARAMETER;
    }
    return 0;
}
static ULONG get_win32_prot(unsigned int vprot, unsigned int map_prot)
{
    (void)map_prot;
    return vprot & VPROT_EXEC ? (vprot & VPROT_WRITE ? PAGE_EXECUTE_READWRITE :
                                      vprot & VPROT_READ ? PAGE_EXECUTE_READ : PAGE_EXECUTE) :
           vprot & VPROT_WRITE ? PAGE_READWRITE : vprot & VPROT_READ ? PAGE_READONLY : PAGE_NOACCESS;
}
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

static NTSTATUS routed(unsigned op, void **addr, size_t *size, ULONG type, ULONG prot, ULONG *old)
{
    NTSTATUS status = -1;
    assert(ios_wow64_route_vm(op, NtCurrentProcess(), addr, size, type, prot, old, &status));
    return status;
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
int main(void)
{
    struct rlimit core = {0, 0};
    assert(!setrlimit(RLIMIT_CORE, &core));
    bases[0] = reserve(); bases[1] = reserve();
    int owner_a, owner_b;
    ios_wow64_windows[0].owner = &owner_a; ios_wow64_windows[0].base = bases[0];
    ios_wow64_windows[1].owner = &owner_b; ios_wow64_windows[1].base = bases[1];
    current_owner = &owner_a;
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
    assert(ios_wow64_route_vm(1, (HANDLE)123, &addr, &size, MEM_RELEASE, 0, NULL, &status));
    assert(status == STATUS_ACCESS_DENIED);
    current_owner = NULL;
    assert(routed(1, &addr, &size, MEM_RELEASE, 0, NULL) == STATUS_ACCESS_DENIED);
    current_owner = &owner_b;
    assert(!routed(0, &other, &other_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL));
    *(int *)other = 42;
    current_owner = &owner_a;
    assert(routed(3, &addr, &size, 0, 0, NULL) == STATUS_NOT_SUPPORTED);
    assert(routed(0, &sub, &subsize, MEM_COMMIT | 0x100000, PAGE_READWRITE, NULL) == STATUS_NOT_SUPPORTED);
    assert(routed(0, &sub, &subsize, MEM_COMMIT, PAGE_READWRITE | 0x100, NULL) == STATUS_INVALID_PARAMETER);
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
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &native, &n, 0, 0, NULL, &status));
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &guest, &n, 0, 0, NULL, &status));
    assert(!ios_wow64_route_vm(0, NtCurrentProcess(), &null, &n, 0, 0, NULL, &status));
    assert(status == -1);
    check_cover(bases[0]); check_cover(bases[1]);
    check_guard(bases[0]); check_guard(bases[1]);
    ios_wow64_delete_views(bases[0]);
    assert(*(int *)other == 42);
    ios_wow64_delete_views(bases[1]);
    assert(!descriptor_count);
    puts("WoW64 native VM: reserve/commit/protect/decommit/release, NX, zero/reuse and owner routing pass");
    return 0;
}

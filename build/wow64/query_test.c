/* Production query core and registry router, using the VM tests' real mappings,
 * Wine's real protection conversions and mock Wine views/page bytes/owner
 * identity. No wineserver/rbtree, actual Wine layouts, APC delivery, alias
 * translator or PE thunk execution.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define WOW64_VM_HELPERS_ONLY
#include "vm_test.c"

#define STATUS_INVALID_ADDRESS 8
#define STATUS_INFO_LENGTH_MISMATCH 10
#define MEM_FREE 0x10000
#define MEM_PRIVATE 0x20000
#define MEM_IMAGE 0x1000000
#define SEC_IMAGE 0x1000000
#define SEC_FILE 0x800000
#define SEC_RESERVE 0x4000000
#define SEC_COMMIT 0x8000000
#define SEC_NOCACHE 0x10000000
#define PAGE_GUARD 0x100
#define PAGE_NOCACHE 0x200
#define PAGE_WRITECOPY 8
#define PAGE_EXECUTE_WRITECOPY 0x80
#define VPROT_WRITECOPY 8
#define VPROT_GUARD 0x10
#define VPROT_WRITEWATCH 0x40
#define VPROT_GUEST_RO 0x80
#define VPROT_WOW64_IMAGE 0x2000
typedef struct {
    void *BaseAddress, *AllocationBase;
    ULONG AllocationProtect;
    unsigned short PartitionId;
    SIZE_T RegionSize;
    ULONG State, Protect, Type;
} MEMORY_BASIC_INFORMATION;
typedef struct { void *VirtualAddress; uintptr_t VirtualAttributes; } MEMORY_WORKING_SET_EX_INFORMATION;
typedef struct { void *ImageBase; size_t SizeOfImage; unsigned int ImageSigningLevel; } MEMORY_IMAGE_INFORMATION;
typedef enum {
    MemoryBasicInformation, MemoryWorkingSetExInformation, MemoryRegionInformation,
    MemoryImageInformation, MemoryMappedFilenameInformation, MemoryWineLoadUnixLib
} MEMORY_INFORMATION_CLASS;
/* Wine's own protection table (wow64_vprot.h), not a mock. */
#include "wow64_query.h"
#include "query_api.h"

static MEMORY_BASIC_INFORMATION query(uintptr_t address)
{
    MEMORY_BASIC_INFORMATION info;
    memset(&info, 0xab, sizeof(info));
    size_t returned = 0xdead;
    NTSTATUS status = -1;
    assert(ios_wow64_route_query(NtCurrentProcess(), (void *)address, MemoryBasicInformation,
                                  &info, sizeof(info) + 16, &returned, &status));
    assert(!status && returned == sizeof(info));
    assert(!info.PartitionId);
    return info;
}
static void reject(HANDLE process, uintptr_t address, MEMORY_INFORMATION_CLASS cls,
                   size_t len, NTSTATUS expected)
{
    MEMORY_BASIC_INFORMATION before, info;
    memset(&before, 0xa5, sizeof(before)); info = before;
    size_t returned = 0xdead;
    NTSTATUS status = -1;
    assert(ios_wow64_route_query(process, (void *)address, cls, &info, len, &returned, &status));
    assert(status == expected && returned == 0xdead && !memcmp(&info, &before, sizeof(info)));
}
static void region(uintptr_t at, void *allocation, size_t size, ULONG state, ULONG prot,
                   ULONG alloc_prot, ULONG type)
{
    MEMORY_BASIC_INFORMATION i = query(at);
    assert(i.BaseAddress == (void *)(at & ~page_mask) && i.AllocationBase == allocation);
    if (i.RegionSize != size || i.State != state || i.Protect != prot)
        fprintf(stderr, "query at %#lx: size %#lx/%#lx state %#x/%#x protect %#x/%#x\n",
                (unsigned long)at, (unsigned long)i.RegionSize, (unsigned long)size,
                i.State, state, i.Protect, prot);
    assert(i.RegionSize == size && i.State == state && i.Protect == prot);
    assert(i.AllocationProtect == alloc_prot && i.Type == type);
}
static void *concurrent_query(void *arg)
{
    uintptr_t base = *(uintptr_t *)arg;
    for (unsigned n = 0; n < 1000; ++n)
    {
        MEMORY_BASIC_INFORMATION i = query(base);
        assert(i.AllocationBase == (void *)base && i.State == MEM_COMMIT);
        assert(i.Protect == PAGE_READONLY || i.Protect == PAGE_READWRITE);
        assert(i.RegionSize == 0x10000);
    }
    return NULL;
}
#ifdef WOW64_QUERY_HELPERS_ONLY
int query_test_main(void)
#else
int main(void)
#endif
{
    int a, b, missing;
    bases[0] = reserve(); bases[1] = reserve();
    ios_wow64_windows[0].owner = &a; ios_wow64_windows[0].base = bases[0];
    ios_wow64_windows[1].owner = &b; ios_wow64_windows[1].base = bases[1];
    current_owner = &a;
    uintptr_t w = bases[0];
    region(w + 1, (void *)w, 0x10000, MEM_RESERVE, 0, PAGE_NOACCESS, MEM_PRIVATE);
    region(w + 0xffff, (void *)w, 0x1000, MEM_RESERVE, 0, PAGE_NOACCESS, MEM_PRIVATE);
    region(w + 0x10001, NULL, IOS_WOW64_WINDOW_SIZE - 0x10000, MEM_FREE, PAGE_NOACCESS, 0, 0);
    region(w + IOS_WOW64_WINDOW_SIZE - 1, NULL, 0x1000, MEM_FREE, PAGE_NOACCESS, 0, 0);
    /* Artificial adjacent holdback descriptors must merge, including at guard. */
    struct file_view *hole = find_view((void *)w, 1), *tail = alloc_view();
    unregister_view(hole); hole->size = 0x20000; register_view(hole);
    tail->base = (void *)(w + 0x20000); tail->size = IOS_WOW64_WINDOW_SIZE - 0x20000;
    tail->protect = VPROT_WOW64_HOLE; register_view(tail);
    region(w + 0x10000, NULL, IOS_WOW64_WINDOW_SIZE - 0x10000, MEM_FREE, PAGE_NOACCESS, 0, 0);
    void *addr = (void *)(w + 0x400000); size_t size = 0x10000;
    assert(!routed(0, &addr, &size, MEM_RESERVE, PAGE_EXECUTE_READWRITE, NULL));
    region(w + 0x10000, NULL, 0x3f0000, MEM_FREE, PAGE_NOACCESS, 0, 0);
    region(w + 0x400003, addr, size, MEM_RESERVE, 0, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    void *sub = (char *)addr + 0x4000; size_t n = 0x8000;
    assert(!routed(0, &sub, &n, MEM_COMMIT, PAGE_EXECUTE_READWRITE, NULL));
    region(w + 0x400000, addr, 0x4000, MEM_RESERVE, 0, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    region(w + 0x404001, addr, 0x8000, MEM_COMMIT, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    region(w + 0x405fff, addr, 0x7000, MEM_COMMIT, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    ULONG old; n = 0x4000;
    assert(!routed(2, &sub, &n, 0, PAGE_READONLY, &old));
    region(w + 0x404000, addr, 0x4000, MEM_COMMIT, PAGE_READONLY, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    region(w + 0x408000, addr, 0x4000, MEM_COMMIT, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    assert(!routed(1, &sub, &n, MEM_DECOMMIT, 0, NULL));
    region(w + 0x400000, addr, 0x8000, MEM_RESERVE, 0, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    assert(!routed(0, &sub, &n, MEM_COMMIT, PAGE_EXECUTE_READWRITE, NULL));
    region(w + 0x404000, addr, 0x8000, MEM_COMMIT, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    /* Report guard/writecopy/cache logically; ignore private page bookkeeping. */
    set_page_vprot(sub, 0x4000, VPROT_READ | VPROT_WRITECOPY | VPROT_GUARD | VPROT_COMMITTED);
    region(w + 0x404000, addr, 0x4000, MEM_COMMIT, PAGE_WRITECOPY | PAGE_GUARD, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    set_page_vprot(sub, 0x4000, VPROT_READ | VPROT_WRITE | VPROT_EXEC | VPROT_COMMITTED | VPROT_WRITEWATCH | VPROT_GUEST_RO);
    region(w + 0x404000, addr, 0x8000, MEM_COMMIT, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    /* Separate allocations with identical protections cannot merge. */
    void *adj = (char *)addr + size; n = 0x10000;
    assert(!routed(0, &adj, &n, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL));
    assert(!routed(0, &addr, &size, MEM_COMMIT, PAGE_READWRITE, NULL));
    region(w + 0x400000, addr, size, MEM_COMMIT, PAGE_READWRITE, PAGE_EXECUTE_READWRITE, MEM_PRIVATE);
    region(w + 0x410000, adj, n, MEM_COMMIT, PAGE_READWRITE, PAGE_READWRITE, MEM_PRIVATE);
    pthread_t thread; uintptr_t address = (uintptr_t)adj;
    assert(!pthread_create(&thread, NULL, concurrent_query, &address));
    for (unsigned i = 0; i < 1000; ++i)
        assert(!routed(2, &adj, &n, 0, i & 1 ? PAGE_READONLY : PAGE_READWRITE, &old));
    assert(!pthread_join(thread, NULL));
    /* Bootstrap is private; image identity comes from SEC_IMAGE, not EXEC. */
    struct file_view *v;
    assert(!ios_wow64_claim_view(w, 0x7ff00000, 0x4000, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED, &v));
    /* The reused splitter fixture only counts page updates; seed the query
     * fixture's page-byte array for this non-VM bootstrap claim. */
    set_page_vprot(v->base, v->size, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED);
    region(w + 0x7ff00000, v->base, 0x4000, MEM_COMMIT, PAGE_READWRITE, PAGE_READWRITE, MEM_PRIVATE);
    assert(!ios_wow64_claim_view(w, 0x600000, 0x8000, VPROT_READ | VPROT_COMMITTED, &v));
    v->protect |= SEC_IMAGE | SEC_FILE | VPROT_WOW64_IMAGE;
    v->wow64_registered = TRUE;
    v->wow64_size = v->size;
    set_page_vprot(v->base, 0x8000, VPROT_READ | VPROT_EXEC | VPROT_COMMITTED);
    region(w + 0x600001, v->base, 0x8000, MEM_COMMIT, PAGE_EXECUTE_READ, PAGE_READONLY, MEM_IMAGE);
    MEMORY_IMAGE_INFORMATION ii = {0}; size_t ilen = 0; NTSTATUS istatus;
    assert(ios_wow64_route_query(NtCurrentProcess(), (char *)v->base + 1, MemoryImageInformation,
                                &ii, sizeof(ii), &ilen, &istatus));
    assert(!istatus && ilen == sizeof(ii) && ii.ImageBase == v->base &&
           ii.SizeOfImage == v->size && !ii.ImageSigningLevel);
    for (size_t short_len = 0; short_len < sizeof(ii); ++short_len)
        reject(NtCurrentProcess(), (uintptr_t)v->base, MemoryImageInformation,
               short_len, STATUS_INFO_LENGTH_MISMATCH);
    v->wow64_registered = FALSE;
    reject(NtCurrentProcess(), (uintptr_t)v->base, MemoryImageInformation, sizeof(ii), STATUS_INVALID_ADDRESS);
    v->wow64_registered = TRUE;
    v->protect |= SEC_NOCACHE;
    region(w + 0x600001, v->base, 0x8000, MEM_COMMIT, PAGE_EXECUTE_READ | PAGE_NOCACHE, PAGE_READONLY | PAGE_NOCACHE, MEM_IMAGE);
    set_page_vprot((char *)v->base + 0x4000, 0x4000, 0);
    region(w + 0x600000, v->base, 0x4000, MEM_COMMIT, PAGE_EXECUTE_READ | PAGE_NOCACHE, PAGE_READONLY | PAGE_NOCACHE, MEM_IMAGE);
    region(w + 0x604000, v->base, 0x4000, MEM_RESERVE, 0, PAGE_READONLY | PAGE_NOCACHE, MEM_IMAGE);
    /* Missing/corrupt view metadata fails without partial caller output. */
    unregister_view(v);
    reject(NtCurrentProcess(), w + 0x500000, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_INVALID_ADDRESS);
    reject(NtCurrentProcess(), w + 0x600000, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_INVALID_ADDRESS);
    register_view(v);
    size_t saved = v->size; v->size = IOS_WOW64_WINDOW_SIZE;
    reject(NtCurrentProcess(), w + 0x600000, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_INVALID_ADDRESS);
    v->size = saved;
    v->protect = SEC_RESERVE;
    reject(NtCurrentProcess(), w + 0x600000, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_NOT_SUPPORTED);
    v->protect = SEC_IMAGE | VPROT_WOW64_IMAGE;
    for (size_t len = 0; len < sizeof(MEMORY_BASIC_INFORMATION); ++len)
        reject(NtCurrentProcess(), w, MemoryBasicInformation, len, STATUS_INFO_LENGTH_MISMATCH);
    NTSTATUS status = -1; size_t returned = 0xdead;
    assert(ios_wow64_route_query(NtCurrentProcess(), addr, MemoryBasicInformation, NULL,
                                 sizeof(MEMORY_BASIC_INFORMATION), &returned, &status));
    assert(status == STATUS_ACCESS_VIOLATION && returned == 0xdead);
    for (unsigned cls = MemoryRegionInformation; cls <= MemoryWineLoadUnixLib; ++cls)
        reject(NtCurrentProcess(), w, cls, sizeof(MEMORY_BASIC_INFORMATION),
               cls == MemoryImageInformation ? STATUS_INVALID_ADDRESS : STATUS_NOT_SUPPORTED);
    reject((HANDLE)123, w, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_ACCESS_DENIED);
    current_owner = NULL;
    reject(NtCurrentProcess(), w, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_ACCESS_DENIED);
    current_owner = &missing;
    reject(NtCurrentProcess(), w, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_ACCESS_DENIED);
    current_owner = &b;
    reject(NtCurrentProcess(), w, MemoryBasicInformation, sizeof(MEMORY_BASIC_INFORMATION), STATUS_ACCESS_DENIED);
    region(bases[1] + 0x400000, NULL, IOS_WOW64_WINDOW_SIZE - 0x400000, MEM_FREE, PAGE_NOACCESS, 0, 0);
    current_owner = &a;
    /* WorkingSetEx addr may be native/NULL while the array names a window. */
    MEMORY_WORKING_SET_EX_INFORMATION entries[2] = {{(void *)0x400000, 0xdead}, {addr, 0xbeef}}, before[2];
    memcpy(before, entries, sizeof(entries));
    assert(ios_wow64_route_query(NtCurrentProcess(), NULL, MemoryWorkingSetExInformation,
                                  entries, sizeof(entries), &returned, &status));
    assert(status == STATUS_NOT_SUPPORTED && returned == 0xdead && !memcmp(before, entries, sizeof(entries)));
    entries[1].VirtualAddress = (void *)bases[1];
    assert(ios_wow64_route_query(NtCurrentProcess(), NULL, MemoryWorkingSetExInformation,
                                  entries, sizeof(entries), &returned, &status) && status == STATUS_ACCESS_DENIED);
    entries[1].VirtualAddress = (void *)0x800000;
    status = -1;
    assert(!ios_wow64_route_query(NtCurrentProcess(), NULL, MemoryWorkingSetExInformation,
                                   entries, sizeof(entries), &returned, &status) && status == -1);
    /* Remote WorkingSetEx does not inspect an ignored/non-window addr's
     * buffer: the unchanged native path already rejects remote queries. */
    assert(!ios_wow64_route_query((HANDLE)123, NULL, MemoryWorkingSetExInformation,
                                   (void *)1, sizeof(entries), &returned, &status) && status == -1);
    MEMORY_BASIC_INFORMATION info;
    assert(ios_wow64_route_query(NtCurrentProcess(), addr, MemoryBasicInformation,
                                  &info, sizeof(info), NULL, &status) && !status);
    status = -1;
    /* All non-window addresses fall through with outputs/status untouched. */
    uintptr_t outside[] = {0, 0x400000, w - 1, w + IOS_WOW64_WINDOW_SIZE, UINTPTR_MAX};
    for (unsigned i = 0; i < sizeof(outside) / sizeof(*outside); ++i)
    {
        if (find_view((void *)outside[i], 1)) continue; /* second mapping may abut */
        assert(!ios_wow64_route_query(NtCurrentProcess(), (void *)outside[i], MemoryBasicInformation,
                                       NULL, 0, &returned, &status) && status == -1 && returned == 0xdead);
    }
    size_t release = 0;
    assert(!routed(1, &addr, &release, MEM_RELEASE, 0, NULL)); release = 0;
    assert(!routed(1, &adj, &release, MEM_RELEASE, 0, NULL));
    region(w + 0x400000, NULL, 0x200000, MEM_FREE, PAGE_NOACCESS, 0, 0);
    image.ImageCharacteristics = IMAGE_FILE_LARGE_ADDRESS_AWARE;
    addr = (void *)(w + 0xffff0000); size = 0x10000;
    assert(!routed(0, &addr, &size, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE, NULL));
    region(w + IOS_WOW64_WINDOW_SIZE - 1, addr, 0x1000, MEM_COMMIT, PAGE_EXECUTE, PAGE_EXECUTE, MEM_PRIVATE);
    ios_wow64_delete_views(w); ios_wow64_delete_views(bases[1]);
    assert(!descriptor_count);
    puts("WoW64 query: owners, logical regions/types, guard/holes, bounds/failures and native fall-through pass");
    return 0;
}

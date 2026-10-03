/* The shared DC_ATTR arena (madeira-unix 0065) and i386 gdi32's mapping of a
 * host UserPointer into its window alias (wine-pe 0019), compiled from the
 * patches, with real 4 GiB windows and a mocked Wine view tree.
 * vm_remap is Mach-only: here a shared anonymous arena and Linux mremap with
 * old size 0 stand in for it (both alias the same pages).
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include "wow64_window.h"

typedef int NTSTATUS;
typedef size_t SIZE_T;
typedef uint64_t UINT64;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 1
#define STATUS_CONFLICTING_ADDRESSES 2
#define STATUS_NO_MEMORY 3
#define STATUS_ACCESS_DENIED 4
#define VPROT_READ 1
#define VPROT_WRITE 2
#define VPROT_COMMITTED 0x20
#define FALSE 0
static const size_t granularity_mask = 0xffff, host_page_mask = 0x3fff;
struct file_view { void *base; size_t size; unsigned int protect; int registered, arena; };
static struct file_view *views[128];
static int descriptor_count;
static struct file_view *alloc_view(void)
{
    struct file_view *v = calloc(1, sizeof(*v));
    assert(v);
    ++descriptor_count;
    return v;
}
static void free_view(struct file_view *v)
{
    assert(!v->registered);
    --descriptor_count;
    free(v);
}
static void register_view(struct file_view *v)
{
    for (unsigned i = 0; i < 128; ++i)
        if (views[i]) assert((uintptr_t)v->base + v->size <= (uintptr_t)views[i]->base ||
                            (uintptr_t)views[i]->base + views[i]->size <= (uintptr_t)v->base);
    for (unsigned i = 0; i < 128; ++i)
        if (!views[i]) { views[i] = v; v->registered = 1; return; }
    abort();
}
static void unregister_view(struct file_view *v)
{
    for (unsigned i = 0; i < 128; ++i)
        if (views[i] == v) { views[i] = NULL; v->registered = 0; return; }
    abort();
}
static struct file_view *find_view(const void *addr, size_t size)
{
    uintptr_t a = (uintptr_t)addr;
    for (unsigned i = 0; i < 128; ++i)
        if (views[i] && a >= (uintptr_t)views[i]->base &&
            a - (uintptr_t)views[i]->base < views[i]->size &&
            size <= views[i]->size - (a - (uintptr_t)views[i]->base)) return views[i];
    return NULL;
}
static struct file_view *find_view_range(const void *addr, size_t size)
{
    uintptr_t a = (uintptr_t)addr;
    for (unsigned i = 0; i < 128; ++i)
        if (views[i] && (uintptr_t)views[i]->base < a + size &&
            (uintptr_t)views[i]->base + views[i]->size > a) return views[i];
    return NULL;
}
static void delete_view(struct file_view *v)
{
    assert(!munmap(v->base, v->size));
    unregister_view(v);
    free_view(v);
}
static int get_unix_prot(unsigned int p)
{
    return !(p & VPROT_COMMITTED) ? PROT_NONE :
           ((p & VPROT_READ) ? PROT_READ : 0) | ((p & VPROT_WRITE) ? PROT_WRITE : 0);
}
static void set_page_vprot(void *p, size_t size, unsigned int prot)
{
    assert(!((uintptr_t)p & host_page_mask) && !(size & host_page_mask));
    assert(!(prot & ~0x23u));
}
#include "wow64_views.h"

static unsigned int coalesced;
static void ios_wow64_vm_coalesce(uintptr_t window, struct file_view *view)
{
    assert((uintptr_t)view->base - window < IOS_WOW64_WINDOW_SIZE && view->protect == VPROT_WOW64_HOLE);
    ++coalesced;
}

/* Mach stand-ins */
typedef uintptr_t vm_address_t;
typedef int vm_prot_t, kern_return_t;
#define KERN_SUCCESS 0
#define KERN_FAILURE 5
#define VM_FLAGS_FIXED 1
#define VM_FLAGS_OVERWRITE 2
#define VM_INHERIT_NONE 2
#define VM_PROT_READ PROT_READ
#define VM_PROT_WRITE PROT_WRITE
static int mach_task_self(void) { return 1; }
static int fail_remap;
static kern_return_t vm_remap(int task, vm_address_t *target, size_t size, size_t mask, int flags,
                              int src_task, vm_address_t src, int copy, vm_prot_t *cur,
                              vm_prot_t *max, int inherit)
{
    assert(task == 1 && src_task == 1 && !mask && !copy && inherit == VM_INHERIT_NONE &&
           flags == (VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE));
    if (fail_remap) return KERN_FAILURE;
    void *p = mremap((void *)src, 0, size, MREMAP_MAYMOVE | MREMAP_FIXED, (void *)*target);
    assert(p == (void *)*target);
    *cur = *max = PROT_READ | PROT_WRITE;
    return KERN_SUCCESS;
}
static kern_return_t vm_protect(int task, vm_address_t addr, size_t size, int set_max, vm_prot_t prot)
{
    assert(task == 1 && !set_max);
    return mprotect((void *)addr, size, prot) ? KERN_FAILURE : KERN_SUCCESS;
}
#include "pair_layout.h"  /* wow64_pair.h's guest layout */
#include "wow64_dc_attr.h"

/* ntdll's arena creation and win32u's entry, from the patch */
static pthread_mutex_t ios_wow64_windows_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t virtual_mutex = PTHREAD_MUTEX_INITIALIZER;
static void server_enter_uninterrupted_section(pthread_mutex_t *mutex, sigset_t *set)
{
    (void)set;
    assert(!pthread_mutex_lock(mutex));
}
static void server_leave_uninterrupted_section(pthread_mutex_t *mutex, sigset_t *set)
{
    (void)set;
    assert(!pthread_mutex_unlock(mutex));
}
static unsigned int arena_maps;
static int fail_map;
static NTSTATUS map_view(struct file_view **ret, void *base, size_t size, unsigned int type,
                         unsigned int vprot, uintptr_t low, uintptr_t high, size_t align)
{
    assert(!base && !type && !low && !high && !align);
    assert(vprot == (VPROT_READ | VPROT_WRITE | VPROT_COMMITTED));
    if (fail_map) return STATUS_NO_MEMORY;
    char *raw = mmap(NULL, size + granularity_mask, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(raw != MAP_FAILED);
    char *p = (char *)(((uintptr_t)raw + granularity_mask) & ~(uintptr_t)granularity_mask);
    if (p != raw) assert(!munmap(raw, p - raw));
    if (granularity_mask - (size_t)(p - raw)) assert(!munmap(p + size, granularity_mask - (p - raw)));
    struct file_view *v = alloc_view();
    v->base = p; v->size = size; v->protect = vprot; v->arena = 1;
    register_view(v);
    ++arena_maps;
    *ret = v;
    return STATUS_SUCCESS;
}
static void *ios_wow64_dc_attr_host;
#include "dc_attr_api.h"

static uintptr_t reserve(void)
{
    size_t size = IOS_WOW64_WINDOW_SIZE + 0x10000;
    void *p = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    assert(p != MAP_FAILED);
    uintptr_t base = ((uintptr_t)p + 0xffff) & ~(uintptr_t)0xffff;
    if (base != (uintptr_t)p) assert(!munmap(p, base - (uintptr_t)p));
    size_t tail = (uintptr_t)p + size - (base + IOS_WOW64_WINDOW_SIZE);
    if (tail) assert(!munmap((void *)(base + IOS_WOW64_WINDOW_SIZE), tail));
    struct file_view *v = alloc_view();
    v->base = (void *)base; v->size = IOS_WOW64_WINDOW_SIZE; v->protect = VPROT_WOW64_HOLE;
    register_view(v);
    return base;
}
/* the bootstrap views reservation makes before the arena alias */
static void bootstrap(uintptr_t window)
{
    struct file_view *v;
    const unsigned int rw = VPROT_READ | VPROT_WRITE | VPROT_COMMITTED;
    assert(!ios_wow64_claim_view(window, IOS_WOW64_PEB_GUEST, 0x4000, rw, &v));
    assert(!ios_wow64_claim_view(window, IOS_WOW64_TEB_GUEST, IOS_WOW64_PAIR_SIZE, rw, &v));
}
static void faults(uintptr_t addr)
{
    pid_t pid = fork();
    assert(pid >= 0);
    if (!pid)
    {
        signal(SIGSEGV, SIG_DFL);
        (void)*(volatile char *)addr;
        _exit(0);
    }
    int status;
    assert(waitpid(pid, &status, 0) == pid && WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
}

int main(void)
{
    struct rlimit core = {0, 0};
    assert(!setrlimit(RLIMIT_CORE, &core));
    /* The guest range sits below the TEB pair, inside a 2 GiB guest, in whole granules. */
    assert(IOS_WOW64_DC_ATTR_GUEST >= IOS_WOW64_NULL_GUARD);
    assert(IOS_WOW64_DC_ATTR_GUEST + IOS_WOW64_DC_ATTR_SIZE <= IOS_WOW64_TEB_GUEST);
    assert(IOS_WOW64_TEB_GUEST < IOS_WOW64_PEB_GUEST && IOS_WOW64_PEB_GUEST < 0x80000000u);
    assert(!(IOS_WOW64_DC_ATTR_GUEST & granularity_mask) && !(IOS_WOW64_DC_ATTR_SIZE & granularity_mask));
    assert(IOS_WOW64_DC_ATTR_HEADER >= sizeof(struct ios_wow64_dc_attr_header));

    /* A failed arena allocation is retried later and leaves windows without a list. */
    SIZE_T size = 1;
    fail_map = 1;
    assert(!ios_wow64_dc_attr_arena(&size) && !size && !arena_maps);
    uintptr_t a = reserve(), b = reserve(), c = reserve();
    bootstrap(a); bootstrap(b); bootstrap(c);
    assert(!ios_wow64_alias_dc_attr(c, ios_wow64_dc_attr_create()));
    assert(find_view((void *)(c + IOS_WOW64_DC_ATTR_GUEST), 1)->protect == VPROT_WOW64_HOLE);
    fail_map = 0;

    /* win32u's first bucket makes the arena; windows then alias the same one. */
    char *buckets = ios_wow64_dc_attr_arena(&size);
    char *arena = ios_wow64_dc_attr_host;
    assert(buckets == arena + IOS_WOW64_DC_ATTR_HEADER && size == IOS_WOW64_DC_ATTR_SIZE - IOS_WOW64_DC_ATTR_HEADER);
    assert(ios_wow64_dc_attr_arena(&size) == buckets && arena_maps == 1);
    const struct ios_wow64_dc_attr_header *header = (void *)arena;
    assert(header->host == (uintptr_t)arena && header->size == IOS_WOW64_DC_ATTR_SIZE);
    assert(ios_wow64_alias_dc_attr(a, ios_wow64_dc_attr_create()) == IOS_WOW64_DC_ATTR_GUEST);
    assert(ios_wow64_alias_dc_attr(b, ios_wow64_dc_attr_create()) == IOS_WOW64_DC_ATTR_GUEST);
    assert(arena_maps == 1);
    struct file_view *va = find_view((void *)(a + IOS_WOW64_DC_ATTR_GUEST), IOS_WOW64_DC_ATTR_SIZE);
    assert(va && va->base == (void *)(a + IOS_WOW64_DC_ATTR_GUEST) && va->size == IOS_WOW64_DC_ATTR_SIZE &&
           va->protect == (VPROT_READ | VPROT_WRITE | VPROT_COMMITTED));

    /* Coherence: what win32u writes, both guests read, and back. */
    char *alias_a = (char *)(a + IOS_WOW64_DC_ATTR_GUEST), *alias_b = (char *)(b + IOS_WOW64_DC_ATTR_GUEST);
    const struct ios_wow64_dc_attr_header *guest_header = (void *)alias_a;
    assert(guest_header->host == (uintptr_t)arena && guest_header->size == IOS_WOW64_DC_ATTR_SIZE);
    memcpy(buckets + 0x123, "session", 8);
    assert(!memcmp(alias_a + IOS_WOW64_DC_ATTR_HEADER + 0x123, "session", 8));
    assert(!memcmp(alias_b + IOS_WOW64_DC_ATTR_HEADER + 0x123, "session", 8));
    memcpy(alias_b + IOS_WOW64_DC_ATTR_SIZE - 8, "child-b", 8);
    assert(!memcmp(arena + IOS_WOW64_DC_ATTR_SIZE - 8, "child-b", 8));
    assert(!memcmp(alias_a + IOS_WOW64_DC_ATTR_SIZE - 8, "child-b", 8));

    /* i386 gdi32: a host UserPointer in the arena maps into this window's alias, nothing else does. */
    const UINT64 *list = (const UINT64 *)alias_a;
    uintptr_t host = (uintptr_t)buckets + 0x123;
    assert(client_ptr_from_dc_attr_arena(list, host) == alias_a + IOS_WOW64_DC_ATTR_HEADER + 0x123);
    assert(client_ptr_from_dc_attr_arena((const UINT64 *)alias_b, host) == alias_b + IOS_WOW64_DC_ATTR_HEADER + 0x123);
    assert(client_ptr_from_dc_attr_arena(list, (uintptr_t)arena) == alias_a);
    assert(client_ptr_from_dc_attr_arena(list, (uintptr_t)arena + IOS_WOW64_DC_ATTR_SIZE - 1) ==
           alias_a + IOS_WOW64_DC_ATTR_SIZE - 1);
    assert(!client_ptr_from_dc_attr_arena(list, (uintptr_t)arena + IOS_WOW64_DC_ATTR_SIZE));
    assert(!client_ptr_from_dc_attr_arena(list, (uintptr_t)arena - 1));
    assert(!client_ptr_from_dc_attr_arena(list, UINT64_MAX));
    assert(!client_ptr_from_dc_attr_arena(NULL, host));

    /* The guest range is claimed: a second alias, image or VM cannot land there. */
    struct file_view *v;
    assert(ios_wow64_claim_view(a, IOS_WOW64_DC_ATTR_GUEST, 0x10000, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED, &v) ==
           STATUS_CONFLICTING_ADDRESSES);
    assert(!ios_wow64_alias_dc_attr(a, arena));
    assert(!ios_wow64_alias_dc_attr(a, NULL));

    /* A failed remap gives the range back as a protected gap. */
    unsigned int count = descriptor_count;
    fail_remap = 1;
    assert(!ios_wow64_alias_dc_attr(c, arena) && coalesced == 1);
    fail_remap = 0;
    struct file_view *vc = find_view((void *)(c + IOS_WOW64_DC_ATTR_GUEST), IOS_WOW64_DC_ATTR_SIZE);
    assert(vc && vc->protect == VPROT_WOW64_HOLE && descriptor_count >= (int)count);
    faults(c + IOS_WOW64_DC_ATTR_GUEST);
    assert(ios_wow64_alias_dc_attr(c, arena) == IOS_WOW64_DC_ATTR_GUEST);

    /* A child's teardown drops its alias only: the arena and the other window keep the data. */
    ios_wow64_delete_views(a);
    assert(!find_view_range((void *)a, IOS_WOW64_WINDOW_SIZE));
    faults(a + IOS_WOW64_DC_ATTR_GUEST);
    assert(!memcmp(buckets + 0x123, "session", 8) && !memcmp(alias_b + IOS_WOW64_DC_ATTR_HEADER + 0x123, "session", 8));
    memcpy(buckets + 0x200, "later", 6);
    assert(!memcmp(alias_b + IOS_WOW64_DC_ATTR_HEADER + 0x200, "later", 6));
    ios_wow64_delete_views(b);
    ios_wow64_delete_views(c);
    assert(!memcmp(buckets + 0x200, "later", 6) && header->host == (uintptr_t)arena);
    assert(find_view(arena, IOS_WOW64_DC_ATTR_SIZE)->arena);
    puts("WoW64 DC_ATTR arena: PASS (one arena, aliases in disjoint windows, coherence, gdi32 mapping, rollback, teardown)");
    return 0;
}

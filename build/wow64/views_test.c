/* Exercise the production splitting algorithm with real PROT_NONE mappings,
 * a mocked Wine view tree, and injected descriptor/protection failures.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include "wow64_window.h"

typedef int NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 1
#define STATUS_CONFLICTING_ADDRESSES 2
#define STATUS_NO_MEMORY 3
#define STATUS_ACCESS_DENIED 4
#define STATUS_NOT_SUPPORTED 5
#define VPROT_READ 1
#define VPROT_WRITE 2
#define VPROT_COMMITTED 0x20
static const size_t granularity_mask = 0xffff, host_page_mask = 0x3fff;
struct file_view { void *base; size_t size; unsigned int protect; int registered; };
static struct file_view *views[128];
static int fail_after = -1, fail_protect, descriptor_count;
static unsigned int page_updates;
static struct file_view *alloc_view(void)
{
    if (!fail_after) return NULL;
    if (fail_after > 0) --fail_after;
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
    assert(!v->registered && v->size && !((uintptr_t)v->base & host_page_mask));
    for (unsigned i = 0; i < 128; ++i)
        if (views[i]) assert((uintptr_t)v->base + v->size <= (uintptr_t)views[i]->base ||
                            (uintptr_t)views[i]->base + views[i]->size <= (uintptr_t)v->base);
    for (unsigned i = 0; i < 128; ++i)
        if (!views[i]) { views[i] = v; v->registered = 1; return; }
    abort();
}
static void unregister_view(struct file_view *v)
{
    assert(v->registered);
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
static int test_mprotect(void *p, size_t size, int prot)
{
    if (fail_protect) return -1;
    return mprotect(p, size, prot);
}
static void set_page_vprot(void *p, size_t size, unsigned int prot)
{
    assert(!((uintptr_t)p & host_page_mask) && !(size & host_page_mask));
    assert(!(prot & ~0x23u));
    ++page_updates;
}
#define mprotect test_mprotect
#include "wow64_views.h"
#undef mprotect

#define IOS_WOW64_WINDOWS_MAX 64
static struct { void *owner; uintptr_t base; } ios_wow64_windows[IOS_WOW64_WINDOWS_MAX];
static pthread_mutex_t ios_wow64_windows_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t virtual_mutex = PTHREAD_MUTEX_INITIALIZER;
static void server_enter_uninterrupted_section(pthread_mutex_t *mutex, sigset_t *set)
{
    (void)set; /* Test locks/owner selection, not Wine's signal masking. */
    assert(!pthread_mutex_lock(mutex));
}
static void server_leave_uninterrupted_section(pthread_mutex_t *mutex, sigset_t *set)
{
    (void)set;
    assert(!pthread_mutex_unlock(mutex));
}
#include "views_api.h"

struct request { void *owner, *host; NTSTATUS status; };
static void *concurrent_claim(void *arg)
{
    struct request *r = arg;
    r->status = ios_wow64_allocate_for_peb(r->owner, 0x400000, 0x4000,
                                          VPROT_READ | VPROT_WRITE | VPROT_COMMITTED, &r->host);
    return NULL;
}

static uintptr_t reserve(void)
{
    size_t size = IOS_WOW64_WINDOW_SIZE + 0x10000;
    void *p = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
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
static void check_cover(uintptr_t base)
{
    uintptr_t pos = base;
    while (pos - base < IOS_WOW64_WINDOW_SIZE)
    {
        struct file_view *v = find_view((void *)pos, 1);
        assert(v && (uintptr_t)v->base == pos && v->size <= IOS_WOW64_WINDOW_SIZE - (pos - base));
        pos += v->size;
    }
}
static void check_guard(uintptr_t base)
{
    pid_t pid = fork();
    assert(pid >= 0);
    if (!pid)
    {
        /* UBSan installs a diagnostic SEGV handler; this child tests the
         * kernel guard, so restore the default signal disposition. */
        signal(SIGSEGV, SIG_DFL);
        *(volatile char *)(base + 0xffff) = 1;
        _exit(0);
    }
    int status;
    assert(waitpid(pid, &status, 0) == pid && WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
}
static void rejected(uintptr_t base, uint32_t guest, size_t size, unsigned int prot, int code)
{
    struct file_view *out = (void *)1;
    int count = descriptor_count;
    unsigned int updates = page_updates;
    assert(ios_wow64_claim_view(base, guest, size, prot, &out) == code);
    assert(out == (void *)1 && descriptor_count == count && page_updates == updates);
    check_cover(base);
}
int main(void)
{
    /* Do not write core files when deliberately touching the guard. */
    struct rlimit core = {0, 0};
    assert(!setrlimit(RLIMIT_CORE, &core));
    uintptr_t a = reserve(), b = reserve();
    struct file_view *v;
    int owner_a, owner_b, unknown;
    ios_wow64_windows[0].owner = &owner_a; ios_wow64_windows[0].base = a;
    ios_wow64_windows[1].owner = &owner_b; ios_wow64_windows[1].base = b;
    void *host = (void *)1;
    assert(ios_wow64_allocate_for_peb(NULL, 0x400000, 0x4000, 0, &host) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_allocate_for_peb(&owner_a, 0x400000, 0x4000, 0, NULL) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_allocate_for_peb(&unknown, 0x400000, 0x4000, 0, &host) == STATUS_NOT_SUPPORTED);
    assert(host == (void *)1);
    const unsigned int rw = VPROT_READ | VPROT_WRITE | VPROT_COMMITTED;
    rejected(a, 0, 0x4000, rw, STATUS_INVALID_PARAMETER);
    rejected(a, 0xffff, 0x4000, rw, STATUS_INVALID_PARAMETER);
    rejected(a, 0x10001, 0x4000, rw, STATUS_INVALID_PARAMETER);
    rejected(a, 0x10000, 0, rw, STATUS_INVALID_PARAMETER);
    rejected(a, 0x10000, 0x1000, rw, STATUS_INVALID_PARAMETER);
    rejected(a, 0xffff0000, 0x14000, rw, STATUS_INVALID_PARAMETER);
    rejected(a, 0x10000, SIZE_MAX, rw, STATUS_INVALID_PARAMETER);
    rejected(a, 0x10000, 0x4000, 4, STATUS_INVALID_PARAMETER);
    rejected(a, 0x10000, 0x4000, VPROT_WOW64_HOLE, STATUS_INVALID_PARAMETER);
    assert(ios_wow64_claim_view(0, 0x10000, 0x4000, rw, &v) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_claim_view(UINTPTR_MAX - IOS_WOW64_WINDOW_SIZE + 1,
                               0x10000, 0x4000, rw, &v) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_claim_view(a, 0x10000, 0x4000, rw, NULL) == STATUS_INVALID_PARAMETER);
    fail_after = 0;
    rejected(a, 0x400000, 0x4000, rw, STATUS_NO_MEMORY);
    fail_after = 1;
    rejected(a, 0x400000, 0x4000, rw, STATUS_NO_MEMORY);
    fail_after = -1; fail_protect = 1;
    rejected(a, 0x400000, 0x4000, rw, STATUS_ACCESS_DENIED);
    fail_protect = 0;
    assert(!ios_wow64_claim_view(a, 0x7ff00000, 0x4000, rw, &v));
    assert(v->base == (void *)(a + 0x7ff00000) && v->protect == rw);
    for (unsigned i = 0; i < 0x4000; ++i) assert(!((unsigned char *)v->base)[i]);
    *(uint32_t *)v->base = 0x1234;
    assert(!ios_wow64_claim_view(b, 0x7ff00000, 0x4000, rw, &v));
    assert(!*(uint32_t *)v->base);
    *(uint32_t *)v->base = 0x5678;
    assert(*(uint32_t *)(a + 0x7ff00000) == 0x1234);
    rejected(a, 0x7ff00000, 0x4000, rw, STATUS_CONFLICTING_ADDRESSES);
    rejected(a, 0x7fef0000, 0x20000, rw, STATUS_CONFLICTING_ADDRESSES);
    /* Real mutexes and the production owner-selection wrapper: exactly one
     * concurrent fixed-address claim per owner, with no cross-owner collision. */
    struct request requests[8];
    pthread_t threads[8];
    for (unsigned i = 0; i < 8; ++i)
    {
        requests[i] = (struct request){i & 1 ? &owner_b : &owner_a, (void *)1, -1};
        assert(!pthread_create(&threads[i], NULL, concurrent_claim, &requests[i]));
    }
    unsigned int wins[2] = {0, 0};
    for (unsigned i = 0; i < 8; ++i)
    {
        assert(!pthread_join(threads[i], NULL));
        if (!requests[i].status)
        {
            ++wins[i & 1];
            assert(requests[i].host == (void *)((i & 1 ? b : a) + 0x400000));
        }
        else
        {
            assert(requests[i].status == STATUS_CONFLICTING_ADDRESSES);
            assert(requests[i].host == (void *)1);
        }
    }
    assert(wins[0] == 1 && wins[1] == 1);
    /* Allocation at each end of a gap, and exact-fit gaps with no descriptors
     * available: reuse the existing hole instead of allocating needlessly. */
    assert(!ios_wow64_claim_view(a, 0x10000, 0x10000, rw, &v));
    assert(!ios_wow64_claim_view(a, 0xffff0000, 0x10000, rw, &v));
    fail_after = 0;
    assert(!ios_wow64_claim_view(a, 0x20000, 0x3e0000, 0, &v));
    fail_after = -1;
    assert(!ios_wow64_claim_view(a, 0x410000, 0x7faf0000, 0, &v));
    assert(!ios_wow64_claim_view(a, 0x7ff10000, 0x800e0000, 0, &v));
    check_cover(a); check_cover(b);
    check_guard(a); check_guard(b);
    ios_wow64_delete_views(a);
    assert(!find_view_range((void *)a, IOS_WOW64_WINDOW_SIZE));
    check_cover(b);
    assert(*(uint32_t *)(b + 0x7ff00000) == 0x5678);
    ios_wow64_delete_views(b);
    assert(!descriptor_count);
    puts("WoW64 view splitting: PASS (real mappings, mock Wine tree, failure rollback, guard, disjoint windows, teardown)");
    return 0;
}

/* Production fixed-image placement/protection/rollback with real mappings.
 * The view tree and Wine page bytes are mocked, not the algorithms.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define VPROT_WOW64_IMAGE 0x2000
#define VPROT_EXEC 0x04
#define VPROT_WRITECOPY 0x08
#define SEC_IMAGE 0x1000000
#define SEC_FILE 0x800000
#define IMAGE_FILE_MACHINE_I386 0x14c
#define IMAGE_FILE_LARGE_ADDRESS_AWARE 0x20
#define FALSE 0
#define TRUE 1
/* Reuse the baseline's mock view tree, owner wrapper and real mappings. */
#define main views_baseline_main
#include "views_test.c"
#undef main

typedef int BOOL;
typedef unsigned char BYTE;
struct pe_image_info { uint64_t base, map_addr; unsigned int machine, image_charact, image_flags; };
static int fail_replace;
static void *image_mmap(void *addr, size_t size, int prot, int flags, int fd, off_t offset)
{
    if (fail_replace) return MAP_FAILED;
    return mmap(addr, size, prot, flags, fd, offset);
}
#define mmap image_mmap
#include "wow64_image.h"
#undef mmap

#define ROUND_ADDR(addr,mask) ((void *)((uintptr_t)(addr) & ~(uintptr_t)(mask)))
#define ROUND_SIZE(addr,size,mask) (((size) + ((uintptr_t)(addr) & (mask)) + (mask)) & ~(size_t)(mask))
static const size_t host_page_size = 0x4000;
static uintptr_t page_base;
static BYTE page_bytes[16];
static unsigned int native_exec_calls;
static BYTE get_host_page_vprot(void *addr)
{
    size_t idx = ((uintptr_t)addr - page_base) / host_page_size;
    assert(idx < 16);
    return page_bytes[idx];
}
/* The baseline's get_unix_prot only needs RW. For this test use the actual
 * committed/EXEC/WRITECOPY meaning, without Wine's writewatch machinery. */
static int image_unix_prot(BYTE p)
{
    if (!(p & VPROT_COMMITTED)) return PROT_NONE;
    return ((p & VPROT_READ) ? PROT_READ : 0) |
           ((p & (VPROT_WRITE | VPROT_WRITECOPY)) ? PROT_WRITE : 0) |
           ((p & VPROT_EXEC) ? PROT_EXEC : 0);
}
static int ios_host_page_split(void *addr) { (void)addr; return 0; }
static int mprotect_exec(void *addr, size_t size, int prot)
{
    ++native_exec_calls;
    return mprotect(addr, size, prot);
}
#define get_unix_prot image_unix_prot
#include "image_api.h"
#undef get_unix_prot

static void reject_image(uintptr_t base, struct pe_image_info *image, size_t size)
{
    struct file_view *out = (void *)1;
    uint64_t map_addr = image->map_addr;
    int count = descriptor_count;
    assert(ios_wow64_claim_image(base, image, size, &out));
    assert(out == (void *)1 && map_addr == image->map_addr && descriptor_count == count);
    check_cover(base);
}
static void check_inaccessible(void *host, int execute)
{
    pid_t pid = fork();
    assert(pid >= 0);
    if (!pid)
    {
        signal(SIGSEGV, SIG_DFL);
        if (execute) ((void (*)(void))host)();
        else *(volatile char *)host = 0;
        _exit(0);
    }
    int status;
    assert(waitpid(pid, &status, 0) == pid && WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV);
}
#ifndef IMAGE_TEST_ENTRY
#define IMAGE_TEST_ENTRY main
#endif
int IMAGE_TEST_ENTRY(void)
{
    /* Run all original splitter/owner regressions too. */
    assert(!views_baseline_main());
    uintptr_t a = reserve(), b = reserve();
    struct pe_image_info image = {0x400000, 0x7340000000, IMAGE_FILE_MACHINE_I386,
                                  IMAGE_FILE_LARGE_ADDRESS_AWARE, 0};
    struct file_view *va, *vb;
    uint32_t guest = 0xdeadbeef;
    assert(ios_wow64_claim_image(a, NULL, 0x4000, &va) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_claim_image(a, &image, 0x4000, NULL) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_rollback_image(NULL) == STATUS_INVALID_PARAMETER);
    assert(!ios_wow64_image_guest(a, (void *)(a + 0x400000), 0x4000, NULL));
    assert(!ios_wow64_image_guest(a, NULL, 0x4000, &guest));
    assert(!ios_wow64_image_guest(a, (void *)(a + 0xffff), 1, &guest));
    assert(!ios_wow64_image_guest(a, (void *)(a + 0xffffffff), 2, &guest));
    assert(!ios_wow64_image_guest(a, (void *)(a + 0x400000), 0, &guest));
    assert(!ios_wow64_image_guest(a, (void *)(b + 0x400000), 0x4000, &guest));
    assert(!ios_wow64_image_guest(a, (void *)(a + IOS_WOW64_WINDOW_SIZE), 1, &guest));
    assert(guest == 0xdeadbeef);
    assert(ios_wow64_image_guest(a, (void *)(a + 0xffff0000), 0x10000, &guest));
    assert(guest == 0xffff0000);
    reject_image(a, &image, 0);
    reject_image(a, &image, SIZE_MAX);
    image.base = 0xffff0000;
    reject_image(a, &image, 0x10001); /* rounding must not cross window end */
    assert(!ios_wow64_claim_image(a, &image, 0x10000, &va));
    assert(!ios_wow64_rollback_image(va));
    image.image_charact = 0;
    image.base = 0x80000000;
    reject_image(a, &image, 0x4000);
    image.base = 0x7fff0000;
    reject_image(a, &image, 0x10001);
    assert(!ios_wow64_claim_image(a, &image, 0x10000, &va));
    assert(!ios_wow64_rollback_image(va));
    image.base = 0x10000400000;
    reject_image(a, &image, 0x4000); /* wide preferred address is not truncated */
    image.base = 0x400001;
    reject_image(a, &image, 0x4000);
    image.base = 0;
    reject_image(a, &image, 0x4000);
    image.base = 0x400000;
    image.machine = 0x8664;
    reject_image(a, &image, 0x4000);
    image.machine = IMAGE_FILE_MACHINE_I386;
    image.image_charact = IMAGE_FILE_LARGE_ADDRESS_AWARE;
    fail_after = 1;
    reject_image(a, &image, 0x5000);
    fail_after = -1;
    fail_protect = 1;
    reject_image(a, &image, 0x5000);
    fail_protect = 0;
    assert(!ios_wow64_claim_image(a, &image, 0x5000, &va));
    assert(image.map_addr == 0x400000 && image.base == 0x400000);
    assert(va->size == 0x8000 && va->base == (void *)(a + 0x400000));
    assert((va->protect & (SEC_IMAGE | SEC_FILE | VPROT_EXEC | VPROT_WOW64_IMAGE)) ==
           (SEC_IMAGE | SEC_FILE | VPROT_EXEC | VPROT_WOW64_IMAGE));
    assert(ios_wow64_image_guest(a, va->base, va->size, &guest) && guest == 0x400000);
    image.map_addr = 0x10000000;
    assert(!ios_wow64_claim_image(b, &image, 0x5000, &vb));
    int fd = memfd_create("wow64-image-test", 0);
    assert(fd >= 0 && !ftruncate(fd, va->size));
    assert(mmap(va->base, va->size, PROT_READ | PROT_WRITE,
                MAP_FIXED | MAP_PRIVATE, fd, 0) == va->base);
    assert(!close(fd));
    *(uint32_t *)va->base = 0x4017d1; /* guest absolute, no host-base relocation */
    assert(!*(uint32_t *)vb->base);
    *(uint32_t *)vb->base = 0x12345678;
    reject_image(a, &image, 0x5000);
    page_base = (uintptr_t)va->base;
    page_bytes[0] = VPROT_COMMITTED | VPROT_READ | VPROT_EXEC;
    page_bytes[1] = VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY | VPROT_EXEC;
    assert(!mprotect_range(va->base, va->size, 0, 0));
    assert(!native_exec_calls);
    assert(*(uint32_t *)va->base == 0x4017d1);
    *(uint32_t *)((char *)va->base + 0x4000) = 0x42; /* physical writecopy */
    check_inaccessible(va->base, 0); /* first page is read-only */
    check_inaccessible(va->base, 1); /* neither page is native executable */
    check_inaccessible((char *)va->base + 0x4000, 1);
    assert(page_bytes[0] & VPROT_EXEC); /* logical permission was not removed */
    /* Even explicit set EXEC cannot escape the native-NX policy. */
    assert(!mprotect_range(va->base, va->size, VPROT_EXEC, 0));
    assert(!native_exec_calls);
    fail_replace = 1;
    assert(ios_wow64_rollback_image(va) == STATUS_NO_MEMORY);
    assert(va->protect & VPROT_WOW64_IMAGE);
    assert(*(uint32_t *)va->base == 0x4017d1);
    check_cover(a);
    fail_replace = 0;
    assert(!ios_wow64_rollback_image(va));
    assert(va->protect == VPROT_WOW64_HOLE);
    check_cover(a);
    check_inaccessible(va->base, 0);
    assert(!ios_wow64_claim_image(a, &image, 0x8000, &va));
    assert(!*(uint32_t *)va->base); /* file/private bytes not reused */
    assert(*(uint32_t *)vb->base == 0x12345678);
    /* Non-window native mappings still take the old mprotect_exec path. */
    page_base = (uintptr_t)vb->base;
    vb->protect &= ~VPROT_WOW64_IMAGE;
    assert(!mprotect_range(vb->base, vb->size, 0, VPROT_EXEC));
    assert(native_exec_calls == 2);
    check_guard(a); check_guard(b);
    ios_wow64_delete_views(a);
    check_cover(b);
    assert(*(uint32_t *)vb->base == 0x12345678);
    ios_wow64_delete_views(b);
    assert(!descriptor_count);
    puts("WoW64 image placement: PASS (guest identity, NX storage, rounded limits, rollback/retry, disjoint owners)");
    return 0;
}

/* Production protection transaction (wow64_protect.h), native NtProtect route
 * (wow64_vm.h and the extracted router), Wine's protection conversions
 * (wow64_vprot.h) and the window query, with real mappings, a real
 * MAP_PRIVATE file and real faults. Mocked: the Wine view tree, page bytes,
 * owner identity and the image fixture's setup (a claimed view with the file
 * mapped over it and Wine's set_vprot calls replayed through the production
 * transaction; not Wine's PE mapper, set_vprot itself or the wineserver).
 * The host kernel's 4 KiB pages stand in for iOS 16 KiB ones: every
 * mprotect covers a whole 16 KiB host page, so the per-host-page union is
 * what is tested. No Mach fault service, signal masking or PE thunks.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define WOW64_QUERY_HELPERS_ONLY
#include "query_test.c"
#include <fcntl.h>
#include <sys/stat.h>

#define PAGE_WRITECOMBINE 0x400
#define PAGE_TARGETS_INVALID 0x40000000
enum { READ, WRITE, EXEC };

/* 1 when the access faults in a child; the parent is left unchanged. No
 * UBSan function-signature check: it would read before addr itself. */
__attribute__((no_sanitize("undefined")))
static int faults(void *addr, int kind)
{
    pid_t pid = fork();
    assert(pid >= 0);
    if (!pid)
    {
        signal(SIGSEGV, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
        if (kind == READ) (void)*(volatile unsigned char *)addr;
        else if (kind == WRITE) *(volatile unsigned char *)addr = 0x5a;
        else ((void (*)(void))addr)();
        _exit(0);
    }
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    if (WIFEXITED(status) && !WEXITSTATUS(status)) return 0;
    assert(WIFSIGNALED(status) && (WTERMSIG(status) == SIGSEGV || WTERMSIG(status) == SIGBUS));
    return 1;
}
static void native(void *addr, int r, int w)
{
    assert(faults(addr, READ) == !r);
    assert(faults(addr, WRITE) == !w);
    assert(faults(addr, EXEC)); /* never native EXEC, whatever the logical bits */
}
static const unsigned char ret_insn[] = {0xc3}; /* x86-64 ret */
/* Native permissions one Win32 protection gives a whole host page. */
static void expect_native(void *addr, ULONG prot)
{
    ULONG base = prot & 0xff;
    int r = !(prot & PAGE_GUARD) && base != PAGE_NOACCESS;
    int w = r && (base == PAGE_READWRITE || base == PAGE_WRITECOPY ||
                  base == PAGE_EXECUTE_READWRITE || base == PAGE_EXECUTE_WRITECOPY);
    native(addr, r, w);
}
static NTSTATUS protect(void *at, size_t len, ULONG prot, ULONG *old, void **out, size_t *out_len)
{
    void *a = at;
    size_t n = len;
    NTSTATUS status = routed(2, &a, &n, 0, prot, old);
    if (out) *out = a;
    if (out_len) *out_len = n;
    if (status) assert(a == at && n == len); /* outputs unchanged on failure */
    return status;
}
/* Page bytes of the 64 Wine pages around addr, inside its window. */
static void snapshot(uintptr_t addr, unsigned char *out)
{
    for (unsigned i = 0; i < 2; ++i)
        if (addr >= bases[i] && addr - bases[i] < IOS_WOW64_WINDOW_SIZE)
        {
            uintptr_t lo = (addr & ~page_mask) - bases[i] < 32 * page_size ? bases[i] :
                           (addr & ~page_mask) - 32 * page_size;
            if (lo + 64 * page_size > bases[i] + IOS_WOW64_WINDOW_SIZE)
                lo = bases[i] + IOS_WOW64_WINDOW_SIZE - 64 * page_size;
            for (unsigned j = 0; j < 64; ++j) out[j] = get_page_vprot((void *)(lo + j * page_size));
            return;
        }
    abort();
}
static void refuse(void *at, size_t len, ULONG prot, NTSTATUS expected)
{
    unsigned char before[64], after[64];
    snapshot((uintptr_t)at, before);
    ULONG old = 0xdead;
    NTSTATUS status = protect(at, len, prot, &old, NULL, NULL);
    if (status != expected) fprintf(stderr, "protect %p+%#zx %#x: %#x, expected %#x\n", at, len, prot, status, expected);
    assert(status == expected && old == 0xdead);
    snapshot((uintptr_t)at, after);
    assert(!memcmp(before, after, sizeof(before)));
}
static void ok(void *at, size_t len, ULONG prot, ULONG expected_old, void *expected_at, size_t expected_len)
{
    ULONG old = 0xdead;
    void *out;
    size_t out_len;
    NTSTATUS status = protect(at, len, prot, &old, &out, &out_len);
    if (status || old != expected_old)
        fprintf(stderr, "protect %p+%#zx %#x: status %#x old %#x/%#x\n", at, len, prot, status, old, expected_old);
    assert(!status && old == expected_old && out == expected_at && out_len == expected_len);
}
static unsigned int logical(ULONG prot, BOOL image)
{
    unsigned int v;
    assert(!get_vprot_flags(prot, &v, image));
    return v | VPROT_COMMITTED;
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    struct rlimit core = {0, 0};
    assert(!setrlimit(RLIMIT_CORE, &core));
    int a, b;
    bases[0] = reserve(); bases[1] = reserve();
    ios_wow64_windows[0].owner = &a; ios_wow64_windows[0].base = bases[0];
    ios_wow64_windows[1].owner = &b; ios_wow64_windows[1].base = bases[1];
    current_owner = &a;
    uintptr_t w = bases[0];

    /* The fault harness itself can see native EXEC (positive control). */
    void *rx = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(rx != MAP_FAILED);
    memcpy(rx, ret_insn, sizeof(ret_insn));
    assert(!mprotect(rx, 0x4000, PROT_READ | PROT_EXEC));
    assert(!faults(rx, EXEC) && faults(rx, WRITE));
    assert(!munmap(rx, 0x4000));

    /* Every anonymous VM transition, host page by host page: old values,
     * page bytes, the query and native (never executable) permissions. */
    void *vm = (void *)(w + 0x500000);
    size_t vm_size = 0x10000;
    assert(!routed(0, &vm, &vm_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL));
    memcpy(vm, ret_insn, sizeof(ret_insn));
    const ULONG prots[] = {PAGE_NOACCESS, PAGE_READONLY, PAGE_READWRITE, PAGE_EXECUTE,
                           PAGE_EXECUTE_READ, PAGE_EXECUTE_READWRITE,
                           PAGE_READONLY | PAGE_GUARD, PAGE_READWRITE | PAGE_GUARD,
                           PAGE_EXECUTE_READ | PAGE_GUARD, PAGE_NOACCESS | PAGE_GUARD};
    const unsigned nprots = sizeof(prots) / sizeof(*prots);
    ULONG current = PAGE_READWRITE;
    for (unsigned i = 0; i < nprots; ++i)
        for (unsigned j = 0; j < nprots; ++j)
        {
            ok(vm, 0x4000, prots[i], current, vm, 0x4000);
            ok((char *)vm + 1, 0x3fff, prots[j], prots[i], vm, 0x4000);
            current = prots[j];
            for (unsigned p = 0; p < 4; ++p)
                assert(get_page_vprot((char *)vm + p * page_size) == logical(current, FALSE));
            /* The other host pages stay READWRITE: equal protections merge. */
            region((uintptr_t)vm, vm, current == PAGE_READWRITE ? 0x10000 : 0x4000, MEM_COMMIT,
                   current, PAGE_READWRITE, MEM_PRIVATE);
            expect_native(vm, current);
        }
    ok(vm, 0x4000, PAGE_EXECUTE, current, vm, 0x4000);
    assert(*(unsigned char *)vm == ret_insn[0]); /* execute-only stays readable for the decoder */
    native(vm, 1, 0);
    /* Anonymous VM has no file: WRITECOPY is refused, as by Wine. */
    refuse(vm, 0x4000, PAGE_WRITECOPY, STATUS_INVALID_PAGE_PROTECTION);
    refuse(vm, 0x4000, PAGE_EXECUTE_WRITECOPY, STATUS_INVALID_PAGE_PROTECTION);
    /* Modifiers page bytes cannot hold are refused, not dropped. */
    refuse(vm, 0x4000, PAGE_READONLY | PAGE_NOCACHE, STATUS_NOT_SUPPORTED);
    refuse(vm, 0x4000, PAGE_READONLY | PAGE_WRITECOMBINE, STATUS_NOT_SUPPORTED);
    refuse(vm, 0x4000, PAGE_EXECUTE_READ | PAGE_TARGETS_INVALID, STATUS_NOT_SUPPORTED);
    refuse(vm, 0x4000, 0, STATUS_INVALID_PAGE_PROTECTION);
    refuse(vm, 0x4000, PAGE_READONLY | PAGE_EXECUTE, STATUS_INVALID_PAGE_PROTECTION);
    void *any = vm; size_t any_size = 0x1000;
    assert(routed(2, &any, &any_size, 0, PAGE_READONLY, NULL) == STATUS_ACCESS_VIOLATION);
    assert(any == vm && any_size == 0x1000);
    refuse(vm, 0, PAGE_READONLY, STATUS_INVALID_PARAMETER);

    /* 4 KiB Wine pages inside one 16 KiB host page: partial ranges round to
     * Wine pages, each page keeps its own logical value, the query splits per
     * page and the host page takes the union of native permissions. */
    char *hp = (char *)vm + 0x4000;
    ok(hp + 0x1003, 1, PAGE_READONLY, PAGE_READWRITE, hp + 0x1000, 0x1000);
    ok(hp + 0x2fff, 2, PAGE_EXECUTE, PAGE_READWRITE, hp + 0x2000, 0x2000);
    region((uintptr_t)hp, vm, 0x1000, MEM_COMMIT, PAGE_READWRITE, PAGE_READWRITE, MEM_PRIVATE);
    region((uintptr_t)hp + 0x1fff, vm, 0x1000, MEM_COMMIT, PAGE_READONLY, PAGE_READWRITE, MEM_PRIVATE);
    region((uintptr_t)hp + 0x2000, vm, 0x2000, MEM_COMMIT, PAGE_EXECUTE, PAGE_READWRITE, MEM_PRIVATE);
    region((uintptr_t)hp + 0x4000, vm, 0x8000, MEM_COMMIT, PAGE_READWRITE, PAGE_READWRITE, MEM_PRIVATE);
    for (unsigned p = 0; p < 4; ++p)
    {
        MEMORY_BASIC_INFORMATION i = query((uintptr_t)hp + p * page_size);
        assert(i.BaseAddress == hp + p * page_size);
    }
    /* Limit, not a pass: the union leaves the read-only page natively
     * writable while a neighbour is writable (no window fault service yet). */
    native(hp + 0x1000, 1, 1);
    ok(hp, 0x1000, PAGE_NOACCESS, PAGE_READWRITE, hp, 0x1000);
    native(hp, 1, 0); /* now R | RO | X | X: readable, nothing writable */
    native(hp + 0x3000, 1, 0);
    ok(hp, 0x4000, PAGE_EXECUTE, PAGE_NOACCESS, hp, 0x4000);
    ok(hp + 0x1000, 0x3000, PAGE_NOACCESS, PAGE_EXECUTE, hp + 0x1000, 0x3000);
    native(hp, 1, 0); /* one execute-only page makes its host page readable */
    /* A range across host pages and a 16 KiB-unaligned start. */
    ok(hp + 0x3000, 0x2000, PAGE_READWRITE, PAGE_NOACCESS, hp + 0x3000, 0x2000);
    region((uintptr_t)hp + 0x3000, vm, 0x9000, MEM_COMMIT, PAGE_READWRITE, PAGE_READWRITE, MEM_PRIVATE);

    /* A guard page is enforced or refused: never beside an accessible page
     * in its host page, and the host page of a guard page is PROT_NONE. */
    ok(hp, 0x4000, PAGE_READWRITE, PAGE_EXECUTE, hp, 0x4000);
    refuse(hp, 0x1000, PAGE_READWRITE | PAGE_GUARD, STATUS_NOT_SUPPORTED);
    native(hp, 1, 1);
    ok(hp + 0x1000, 0x3000, PAGE_NOACCESS, PAGE_READWRITE, hp + 0x1000, 0x3000);
    ok(hp, 0x1000, PAGE_READWRITE | PAGE_GUARD, PAGE_READWRITE, hp, 0x1000);
    native(hp, 0, 0);
    region((uintptr_t)hp, vm, 0x1000, MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD, PAGE_READWRITE, MEM_PRIVATE);
    refuse(hp + 0x2000, 0x1000, PAGE_READONLY, STATUS_NOT_SUPPORTED); /* would unguard it */
    refuse(hp + 0x3fff, 2, PAGE_READONLY, STATUS_NOT_SUPPORTED); /* across host pages, nothing changes */
    native(hp + 0x4000, 1, 1);
    ok(hp + 0x2000, 0x1000, PAGE_NOACCESS | PAGE_GUARD, PAGE_NOACCESS, hp + 0x2000, 0x1000);
    refuse(hp, 0x1000, PAGE_EXECUTE_READ, STATUS_NOT_SUPPORTED); /* the other guard page stays */
    native(hp, 0, 0);
    ok(hp, 0x4000, PAGE_READWRITE, PAGE_READWRITE | PAGE_GUARD, hp, 0x4000);
    native(hp, 1, 1);

    /* Failure leaves no partial change: page bytes, outputs and every host
     * page's native protection stay as they were, including the pages that
     * had already changed (restored one by one). */
    protect_calls = 0; fail_protect_call = 1;
    refuse(vm, 0xc000, PAGE_READONLY, STATUS_ACCESS_DENIED);
    assert(protect_calls == 1);
    protect_calls = 0; fail_protect_call = 3;
    refuse(vm, 0xc000, PAGE_READONLY, STATUS_ACCESS_DENIED);
    assert(protect_calls == 5); /* two applied, one failed, two restored */
    fail_protect_call = 0;
    native(vm, 1, 0); native(hp, 1, 1); native(hp + 0x4000, 1, 1);
    region((uintptr_t)vm, vm, 0x4000, MEM_COMMIT, PAGE_EXECUTE, PAGE_READWRITE, MEM_PRIVATE);
    /* A restore that fails stops the process rather than run on with a
     * protection no page byte describes (cannot happen short of a kernel
     * fault: the restored protection is one the mapping already had). */
    pid_t pid = fork();
    assert(pid >= 0);
    if (!pid)
    {
        protect_calls = 0; fail_protect_from = 3;
        ULONG old;
        protect(vm, 0xc000, PAGE_READONLY, &old, NULL, NULL);
        _exit(0);
    }
    int child;
    assert(waitpid(pid, &child, 0) == pid && WIFSIGNALED(child) && WTERMSIG(child) == SIGABRT);
    /* Commit takes the same transaction: whole host pages, logical EXEC, NX. */
    fail_protect = 1;
    void *c = hp; size_t cn = 0x4000;
    assert(routed(0, &c, &cn, MEM_COMMIT, PAGE_READONLY, NULL) == STATUS_ACCESS_DENIED);
    fail_protect = 0;
    region((uintptr_t)hp, vm, 0xc000, MEM_COMMIT, PAGE_READWRITE, PAGE_READWRITE, MEM_PRIVATE);
    assert(!routed(0, &c, &cn, MEM_COMMIT, PAGE_EXECUTE_READ, NULL));
    native(hp, 1, 0);

    /* Committed pages only, one allocation only. */
    size_t one = 0x4000;
    void *dc = (char *)vm + 0x8000;
    assert(!routed(1, &dc, &one, MEM_DECOMMIT, 0, NULL));
    refuse((char *)vm + 0x7000, 0x2000, PAGE_READONLY, STATUS_NOT_COMMITTED);
    void *next = (char *)vm + 0x10000; size_t next_size = 0x4000;
    assert(!routed(0, &next, &next_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL));
    refuse((char *)vm + 0xf000, 0x2000, PAGE_READWRITE, STATUS_INVALID_PARAMETER);
    refuse((char *)next + 0x3fff, 2, PAGE_READWRITE, STATUS_INVALID_PARAMETER); /* into free space */
    refuse((void *)(w + 0x900000), 0x1000, PAGE_READWRITE, STATUS_INVALID_PARAMETER); /* free */
    refuse((void *)(w + 0x1000), 0x1000, PAGE_READWRITE, STATUS_INVALID_PARAMETER); /* low guard */
    refuse((void *)(w + 0xf000), 0x2000, PAGE_READWRITE, STATUS_INVALID_PARAMETER);
    refuse((void *)(w + IOS_WOW64_WINDOW_SIZE - 0x1000), 0x2000, PAGE_READWRITE, STATUS_INVALID_PARAMETER);

    /* Bootstrap TEB/PEB storage is not protected through this path. */
    struct file_view *boot;
    assert(!ios_wow64_claim_view(w, 0x7ff00000, 0x4000, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED, &boot));
    set_page_vprot(boot->base, boot->size, VPROT_READ | VPROT_WRITE | VPROT_COMMITTED);
    refuse(boot->base, 0x1000, PAGE_READONLY, STATUS_NOT_SUPPORTED);
    native(boot->base, 1, 1);

    /* Other owners, remote processes and a missing owner are denied, outputs
     * unchanged; addresses outside every window fall through untouched. */
    current_owner = &b;
    refuse(vm, 0x1000, PAGE_READONLY, STATUS_ACCESS_DENIED);
    current_owner = NULL;
    refuse(vm, 0x1000, PAGE_READONLY, STATUS_ACCESS_DENIED);
    current_owner = &a;
    void *r = vm; size_t rn = 0x1000; ULONG rold = 0xdead; NTSTATUS rs = -1;
    assert(ios_wow64_route_vm(2, (HANDLE)123, &r, &rn, 0, PAGE_READONLY, 0, &rold, &rs));
    assert(rs == STATUS_ACCESS_DENIED && r == vm && rn == 0x1000 && rold == 0xdead);
    uintptr_t outside[] = {0x400000, w - 1, w + IOS_WOW64_WINDOW_SIZE};
    for (unsigned i = 0; i < sizeof(outside) / sizeof(*outside); ++i)
    {
        if (find_view((void *)outside[i], 1)) continue; /* second mapping may abut */
        r = (void *)outside[i]; rn = 0x1000; rs = -1;
        assert(!ios_wow64_route_vm(2, NtCurrentProcess(), &r, &rn, 0, PAGE_READONLY, 0, &rold, &rs));
        assert(rs == -1 && rold == 0xdead && r == (void *)outside[i] && rn == 0x1000);
    }

    /* Image: a real file mapped MAP_PRIVATE over a claimed window view, as
     * map_file_into_view maps an aligned private section. Wine's setup
     * (header R, .text RX, .rdata R, .data WRITECOPY) goes through the
     * production transaction, as set_vprot sends it for window views. */
    char path[4096];
    snprintf(path, sizeof(path), "%s/image.bin", argv[1]);
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0);
    unsigned char file[0x8000];
    for (size_t i = 0; i < sizeof(file); ++i) file[i] = (unsigned char)("HTTRDDDP"[i / 0x1000] + (i & 7));
    file[0x1000] = file[0x3000] = ret_insn[0];
    assert(write(fd, file, sizeof(file)) == (ssize_t)sizeof(file));
    struct file_view *img;
    assert(!ios_wow64_claim_view(w, 0x600000, 0x8000, VPROT_READ | VPROT_COMMITTED, &img));
    char *ib = img->base;
    assert(mmap(ib, 0x8000, PROT_READ, MAP_FIXED | MAP_PRIVATE, fd, 0) == ib);
    img->protect = VPROT_WOW64_IMAGE | SEC_IMAGE | SEC_FILE | VPROT_COMMITTED |
                   VPROT_READ | VPROT_WRITECOPY | VPROT_EXEC;
    img->wow64_registered = TRUE; img->wow64_mapping = (HANDLE)11;
    img->wow64_size = 0x7000; /* exact server extent; 0x7000 is host-page padding */
    set_page_vprot(ib, 0x8000, VPROT_READ | VPROT_COMMITTED);
    assert(ios_wow64_apply_protection(img, ib, 0x1000, VPROT_COMMITTED | VPROT_READ | VPROT_WRITE) ==
           STATUS_INVALID_PAGE_PROTECTION); /* image pages are copy-on-write only */
    assert(!ios_wow64_apply_protection(img, ib, 0x1000, VPROT_COMMITTED | VPROT_READ));
    assert(!ios_wow64_apply_protection(img, ib + 0x1000, 0x2000, VPROT_COMMITTED | VPROT_READ | VPROT_EXEC));
    assert(!ios_wow64_apply_protection(img, ib + 0x3000, 0x1000, VPROT_COMMITTED | VPROT_READ));
    assert(!ios_wow64_apply_protection(img, ib + 0x4000, 0x3000, VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY));
    assert(ios_wow64_apply_protection(img, ib + 0x7000, 0x2000, VPROT_COMMITTED) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_apply_protection(img, ib + 0x800, 0x1000, VPROT_COMMITTED) == STATUS_INVALID_PARAMETER);
    region((uintptr_t)ib, ib, 0x1000, MEM_COMMIT, PAGE_READONLY, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    region((uintptr_t)ib + 0x1000, ib, 0x2000, MEM_COMMIT, PAGE_EXECUTE_READ, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    region((uintptr_t)ib + 0x3000, ib, 0x1000, MEM_COMMIT, PAGE_READONLY, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    region((uintptr_t)ib + 0x4000, ib, 0x3000, MEM_COMMIT, PAGE_WRITECOPY, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    native(ib + 0x1000, 1, 0); /* .text: readable for FEX, natively NX */
    native(ib + 0x4000, 1, 1);
    *(ib + 0x4000) = 'x'; /* a private copy: the file keeps its byte */
    unsigned char disk;
    assert(pread(fd, &disk, 1, 0x4000) == 1 && disk == file[0x4000]);
    /* Image READWRITE is WRITECOPY, as for Wine images; old values are the
     * first page's, writes stay private, and EXEC stays logical. */
    assert(logical(PAGE_READWRITE, TRUE) == (VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY));
    ok(ib + 0x1000, 0x1000, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_READ, ib + 0x1000, 0x1000);
    assert(get_page_vprot(ib + 0x1000) == (VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY | VPROT_EXEC));
    region((uintptr_t)ib + 0x1000, ib, 0x1000, MEM_COMMIT, PAGE_EXECUTE_WRITECOPY, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    region((uintptr_t)ib + 0x2000, ib, 0x1000, MEM_COMMIT, PAGE_EXECUTE_READ, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    native(ib + 0x1000, 1, 1);
    native(ib, 1, 1); /* union with the header's host page (documented limit) */
    *(ib + 0x1001) = 'y';
    ok(ib + 0x3000, 0x1000, PAGE_READWRITE, PAGE_READONLY, ib + 0x3000, 0x1000);
    region((uintptr_t)ib + 0x3000, ib, 0x4000, MEM_COMMIT, PAGE_WRITECOPY, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    ok(ib + 0x3000, 0x1000, PAGE_EXECUTE_WRITECOPY, PAGE_WRITECOPY, ib + 0x3000, 0x1000);
    ok(ib + 0x3000, 0x1000, PAGE_WRITECOPY, PAGE_EXECUTE_WRITECOPY, ib + 0x3000, 0x1000);
    /* Back to read-only: the private copies stay (copy-on-write is one-way). */
    ok(ib, 0x4000, PAGE_EXECUTE_READ, PAGE_READONLY, ib, 0x4000);
    native(ib, 1, 0);
    assert(*(ib + 0x1001) == 'y' && *(ib + 0x1000) == (char)ret_insn[0]);
    /* Ranges across sections in one image are one allocation. */
    ok(ib + 0x3800, 0x1000, PAGE_READONLY, PAGE_EXECUTE_READ, ib + 0x3000, 0x2000);
    native(ib + 0x4000, 1, 1); /* .data pages 5 and 6 stay WRITECOPY */
    assert(*(ib + 0x4000) == 'x');
    ok(ib + 0x4000, 0x3000, PAGE_EXECUTE_WRITECOPY, PAGE_READONLY, ib + 0x4000, 0x3000);
    /* Guard on image pages, over a whole host page. */
    ok(ib, 0x4000, PAGE_READONLY | PAGE_GUARD, PAGE_EXECUTE_READ, ib, 0x4000);
    native(ib, 0, 0);
    region((uintptr_t)ib, ib, 0x4000, MEM_COMMIT, PAGE_READONLY | PAGE_GUARD, PAGE_EXECUTE_WRITECOPY, MEM_IMAGE);
    refuse(ib + 0x4000, 0x1000, PAGE_READONLY | PAGE_GUARD, STATUS_NOT_SUPPORTED);
    ok(ib, 0x4000, PAGE_READONLY, PAGE_READONLY | PAGE_GUARD, ib, 0x4000);
    /* Padding past the server extent, quarantined images and modifiers. */
    refuse(ib + 0x7000, 0x1000, PAGE_READONLY, STATUS_NOT_SUPPORTED);
    refuse(ib + 0x6000, 0x2000, PAGE_READONLY, STATUS_NOT_SUPPORTED);
    refuse(ib + 0x7fff, 2, PAGE_READONLY, STATUS_INVALID_PARAMETER);
    refuse(ib, 0x1000, PAGE_READONLY | PAGE_NOCACHE, STATUS_NOT_SUPPORTED);
    img->wow64_registered = FALSE;
    refuse(ib, 0x1000, PAGE_READWRITE, STATUS_NOT_SUPPORTED);
    img->wow64_registered = TRUE; img->wow64_mapping = 0;
    refuse(ib, 0x1000, PAGE_READWRITE, STATUS_NOT_SUPPORTED);
    img->wow64_mapping = (HANDLE)11;
    current_owner = &b;
    refuse(ib, 0x1000, PAGE_READWRITE, STATUS_ACCESS_DENIED);
    current_owner = &a;
    /* Failure on an image: no partial change, private bytes kept. */
    protect_calls = 0; fail_protect_call = 2;
    refuse(ib, 0x8000 - 0x1000, PAGE_EXECUTE_READ, STATUS_ACCESS_DENIED);
    fail_protect_call = 0;
    native(ib, 1, 0); native(ib + 0x4000, 1, 1);
    /* The file was never written through any of these protections. */
    unsigned char now[sizeof(file)];
    assert(pread(fd, now, sizeof(now), 0) == (ssize_t)sizeof(now) && !memcmp(now, file, sizeof(file)));
    assert(!close(fd) && !unlink(path));

    /* The other owner's window is untouched by all of this. */
    current_owner = &b;
    region(bases[1] + 0x400000, NULL, IOS_WOW64_WINDOW_SIZE - 0x400000, MEM_FREE, PAGE_NOACCESS, 0, 0);
    current_owner = &a;
    check_cover(w); check_guard(w); check_guard(bases[1]);
    ios_wow64_delete_views(w); ios_wow64_delete_views(bases[1]);
    assert(!descriptor_count);
    puts("WoW64 protect: transitions/old values, 4K pages in 16K host pages, writecopy, guard, NX, rollback, owners pass");
    return 0;
}

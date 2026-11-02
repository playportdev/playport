/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * exchook: how an x86-64 guest's exception reaches ntdll's x64
 * KiUserExceptionDispatcher and its Wow64PrepareForException hook (PLA-516).
 * x64 Windows' KiUserExceptionDispatcher is entered with the CONTEXT at rsp,
 * the EXCEPTION_RECORD at rsp+0x4f0 and the machine frame (Rip, Cs, EFlags,
 * Rsp, Ss) at rsp+0x590. Its code is
 *
 *   cld
 *   mov rax, [Wow64PrepareForException]
 *   test rax, rax / jz 1f
 *   rcx = rsp+0x4f0, rdx = rsp, call rax
 *   1: rcx = rsp+0x4f0, rdx = rsp, call <the dispatcher>   (RtlDispatchException, then
 *      RtlRestoreContext or NtRaiseException)
 *
 * so a program finds the hook's pointer in that code, stores its own function
 * there, and the function is called in x64 code with rsp+8 the context, before
 * any vectored handler, with the same record and context the handlers then get;
 * what it changes in the context is what they see and what resumes. For int3
 * the record's address and the context's Rip are the int3 itself (x64 Windows
 * backs Rip up over it).
 *
 *   a  KiUserExceptionDispatcher's code: cld, then mov rax,[rip+x] with x inside
 *      ntdll; after the call through rax, another call before any ret
 *   b  int3 with the hook set: the hook runs first, rsp+8 = the context,
 *      rcx = context+0x4f0, its return address in KiUserExceptionDispatcher;
 *      the machine frame holds the context's Rip and Rsp; code, address, Rip
 *      (the int3), Rsp and the registers set before the int3; the vectored
 *      handler then gets the same record and context
 *   c  the hook changes a register in the context: the handler sees it, and the
 *      resumed code has it
 *   d  an access violation reading address 0x10: the hook first, code, read,
 *      address, Rip the faulting instruction
 *   e  the hook skips the int3 itself and resumes with RtlRestoreContext: no
 *      handler runs
 *   f  the same with NtContinue
 *   g  b on another thread
 *   h  the hook's pointer back to what it was: an int3 reaches the handler alone
 *
 * Each line goes to OutputDebugString, stdout and <dir>\exchook.log. A line ends
 * "ok", "BAD" or "INFO"; the last is "exchook: done ok" (exit 0) or
 * "exchook: done FAIL" (1). x86-64 only; built with llvm-mingw by
 * tools/compat/probes/build.sh.
 */
#include <windows.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef __x86_64__
#error "exchook is an x86-64 probe"
#endif

static HANDLE log_file = INVALID_HANDLE_VALUE;
static int failed;

static void probe_log(const char *fmt, ...)
{
    char line[512];
    va_list ap;
    DWORD written;
    int n = snprintf(line, sizeof(line), "exchook: ");

    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    OutputDebugStringA(line);
    printf("%s", line);
    fflush(stdout);
    if (log_file != INVALID_HANDLE_VALUE) WriteFile(log_file, line, (DWORD)strlen(line), &written, NULL);
}

static const char *verdict(int ok)
{
    if (!ok) failed = 1;
    return ok ? "ok" : "BAD";
}

#define CHECK(id, cond, ...) do { int ok_ = !!(cond); char what_[256]; \
    snprintf(what_, sizeof(what_), __VA_ARGS__); \
    probe_log("CHECK %s %s: %s\n", id, what_, verdict(ok_)); } while (0)

#define MAGIC_R10 0x1122334455667788ull
#define MAGIC_R11 0x0badc0de12345678ull
#define MAGIC_RBX 0x5a5a5a5aa5a5a5a5ull
#define CHANGED_R10 0x7766554433221100ull

/* The hook (hook_entry), the int3 and fault sites. hook_entry keeps rsp and
 * its return address at entry, then tail-calls hook_c(rec, ctx). Each site
 * stores rsp at the event into *rcx and returns r10 as it is after it. */
void hook_entry(void);
uint64_t run_int3(uint64_t *rsp_out);
uint64_t run_av(uint64_t *rsp_out);
extern const char int3_site[], av_site[];
volatile uint64_t hook_rsp, hook_ret;

__asm__(
    ".text\n.globl hook_entry\n.def hook_entry; .scl 2; .type 32; .endef\nhook_entry:\n"
    "\tmovq %rsp, hook_rsp(%rip)\n"
    "\tmovq (%rsp), %rax\n"
    "\tmovq %rax, hook_ret(%rip)\n"
    "\tjmp hook_c\n"
    ".globl run_int3\n.def run_int3; .scl 2; .type 32; .endef\nrun_int3:\n"
    "\tpushq %rbx\n"
    "\tmovabsq $0x5a5a5a5aa5a5a5a5, %rbx\n"
    "\tmovabsq $0x1122334455667788, %r10\n"
    "\tmovabsq $0x0badc0de12345678, %r11\n"
    "\tmovq %rsp, (%rcx)\n"
    ".globl int3_site\nint3_site:\n"
    "\tint3\n"
    "\tmovq %r10, %rax\n"
    "\tpopq %rbx\n"
    "\tret\n"
    ".globl run_av\n.def run_av; .scl 2; .type 32; .endef\nrun_av:\n"
    "\tmovabsq $0x1122334455667788, %r10\n"
    "\tmovq %rsp, (%rcx)\n"
    "\tmovl $0x10, %edx\n"
    ".globl av_site\nav_site:\n"
    "\tmovl (%rdx), %eax\n"   /* 8b 02 */
    "\tmovq %r10, %rax\n"
    "\tret\n");

enum hook_mode { PLAIN, CHANGE, RESTORE, CONTINUE };

struct seen {
    LONG seq;
    EXCEPTION_RECORD *rec;
    CONTEXT *ctx;
    DWORD code;
    void *addr;
    DWORD nparams;
    ULONG_PTR info0, info1;
    uint64_t rip, rsp, rbx, r10, r11, entry_rsp, ret, frame_rip, frame_rsp, rcx_arg;
};

static volatile enum hook_mode mode;
static volatile LONG seq;
static struct seen hook_seen, veh_seen;
static NTSTATUS (WINAPI *pNtContinue)(CONTEXT *, BOOLEAN);
static void (WINAPI *pRtlRestoreContext)(CONTEXT *, EXCEPTION_RECORD *);
static DWORD hook_thread;

static int our_site(void *addr)
{
    return addr == (void *)int3_site || addr == (void *)av_site;
}

static void record(struct seen *s, EXCEPTION_RECORD *rec, CONTEXT *ctx)
{
    s->seq = InterlockedIncrement(&seq);
    s->rec = rec;
    s->ctx = ctx;
    s->code = rec->ExceptionCode;
    s->addr = rec->ExceptionAddress;
    s->nparams = rec->NumberParameters;
    s->info0 = rec->NumberParameters > 0 ? rec->ExceptionInformation[0] : 0;
    s->info1 = rec->NumberParameters > 1 ? rec->ExceptionInformation[1] : 0;
    s->rip = ctx->Rip;
    s->rsp = ctx->Rsp;
    s->rbx = ctx->Rbx;
    s->r10 = ctx->R10;
    s->r11 = ctx->R11;
}

void hook_c(EXCEPTION_RECORD *rec, CONTEXT *ctx);
void hook_c(EXCEPTION_RECORD *rec, CONTEXT *ctx)
{
    if (GetCurrentThreadId() != hook_thread || !our_site(rec->ExceptionAddress)) return;
    record(&hook_seen, rec, ctx);
    hook_seen.entry_rsp = hook_rsp;
    hook_seen.ret = hook_ret;
    hook_seen.rcx_arg = (uint64_t)rec;
    hook_seen.frame_rip = *(uint64_t *)((char *)ctx + 0x590);
    hook_seen.frame_rsp = *(uint64_t *)((char *)ctx + 0x5a8);
    switch (mode) {
    case PLAIN:
        break;
    case CHANGE:
        ctx->R10 = CHANGED_R10;
        break;
    case RESTORE:
        ctx->Rip += 1;
        pRtlRestoreContext(ctx, NULL);
        break;
    case CONTINUE:
        ctx->Rip += 1;
        pNtContinue(ctx, FALSE);
        break;
    }
}

static LONG CALLBACK veh(EXCEPTION_POINTERS *ep)
{
    EXCEPTION_RECORD *rec = ep->ExceptionRecord;
    CONTEXT *ctx = ep->ContextRecord;

    if (!our_site(rec->ExceptionAddress)) return EXCEPTION_CONTINUE_SEARCH;
    record(&veh_seen, rec, ctx);
    if (rec->ExceptionAddress == (void *)int3_site) ctx->Rip = (uint64_t)int3_site + 1;
    else ctx->Rip = (uint64_t)av_site + 2;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static uint64_t **hook_slot;
static uint8_t *dispatcher;

static void set_hook(void *fn)
{
    DWORD old;
    VirtualProtect(hook_slot, sizeof(*hook_slot), PAGE_EXECUTE_READWRITE, &old);
    *hook_slot = fn;
    VirtualProtect(hook_slot, sizeof(*hook_slot), old, &old);
}

static void reset(enum hook_mode m)
{
    memset(&hook_seen, 0, sizeof(hook_seen));
    memset(&veh_seen, 0, sizeof(veh_seen));
    seq = 0;
    mode = m;
    hook_thread = GetCurrentThreadId();
}

/* a: the dispatcher's code. */
static int check_code(void)
{
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((char *)ntdll + ((IMAGE_DOS_HEADER *)ntdll)->e_lfanew);
    uint8_t *lo = (uint8_t *)ntdll, *hi = lo + nt->OptionalHeader.SizeOfImage;
    uint8_t *p = dispatcher;
    int i, hook_call = -1, next_call = -1, ret = -1;

    {
        char hex[200];
        int n = 0;
        for (i = 0; i < 48; i++) n += snprintf(hex + n, sizeof(hex) - n, " %02x", p[i]);
        probe_log("KiUserExceptionDispatcher %p (ntdll+0x%llx):%s INFO\n", p, (unsigned long long)(p - lo), hex);
    }
    if (p[0] != 0xfc || p[1] != 0x48 || p[2] != 0x8b || p[3] != 0x05) {
        CHECK("a", 0, "cld; mov rax,[rip+x] at its start");
        return 0;
    }
    hook_slot = (uint64_t **)(p + 8 + *(int32_t *)(p + 4));
    CHECK("a", (uint8_t *)hook_slot >= lo && (uint8_t *)hook_slot < hi,
          "cld; mov rax,[rip+x]: the hook's pointer at ntdll+0x%llx, %p now",
          (unsigned long long)((uint8_t *)hook_slot - lo), (void *)*hook_slot);
    for (i = 8; i < 64; i++) {
        if (hook_call < 0 && p[i] == 0xff && p[i + 1] == 0xd0) hook_call = i;
        else if (hook_call >= 0 && next_call < 0 && p[i] == 0xe8) next_call = i;
        else if (ret < 0 && p[i] == 0xc3) ret = i;
    }
    CHECK("a", hook_call >= 0 && next_call > hook_call && (ret < 0 || ret > next_call),
          "after the hook's call (+%d) the dispatch goes on in this code: a call at +%d, ret at +%d",
          hook_call, next_call, ret);
    return 1;
}

static void check_int3_values(const char *id)
{
    uint64_t rsp_at = 0;
    run_int3(&rsp_at);
    CHECK(id, hook_seen.seq == 1 && veh_seen.seq == 2, "the hook ran first (%ld), then the handler (%ld)",
          hook_seen.seq, veh_seen.seq);
    CHECK(id, hook_seen.entry_rsp + 8 == (uint64_t)hook_seen.ctx,
          "at the hook rsp+8 = the context (rsp %llx, context %p)",
          (unsigned long long)hook_seen.entry_rsp, (void *)hook_seen.ctx);
    CHECK(id, hook_seen.rcx_arg == (uint64_t)hook_seen.ctx + 0x4f0, "the record at context+0x4f0 (%p, context %p)",
          (void *)hook_seen.rcx_arg, (void *)hook_seen.ctx);
    CHECK(id, hook_seen.ret > (uint64_t)dispatcher && hook_seen.ret < (uint64_t)dispatcher + 64,
          "the hook returns into KiUserExceptionDispatcher (+0x%llx)",
          (unsigned long long)(hook_seen.ret - (uint64_t)dispatcher));
    CHECK(id, hook_seen.frame_rip == hook_seen.rip && hook_seen.frame_rsp == hook_seen.rsp,
          "the machine frame at context+0x590 holds Rip and Rsp (%llx %llx)",
          (unsigned long long)hook_seen.frame_rip, (unsigned long long)hook_seen.frame_rsp);
    CHECK(id, hook_seen.code == EXCEPTION_BREAKPOINT && hook_seen.addr == (void *)int3_site,
          "code %08lx at %p (int3 %p)", hook_seen.code, hook_seen.addr, (void *)int3_site);
    CHECK(id, hook_seen.rip == (uint64_t)int3_site, "Rip %llx is the int3", (unsigned long long)hook_seen.rip);
    CHECK(id, hook_seen.rsp == rsp_at, "Rsp %llx (at the int3 %llx)", (unsigned long long)hook_seen.rsp,
          (unsigned long long)rsp_at);
    CHECK(id, hook_seen.rbx == MAGIC_RBX && hook_seen.r10 == MAGIC_R10 && hook_seen.r11 == MAGIC_R11,
          "rbx, r10, r11 as set before it");
    CHECK(id, veh_seen.rec == hook_seen.rec && veh_seen.ctx == hook_seen.ctx,
          "the handler gets the hook's record and context (%p %p, %p %p)",
          (void *)veh_seen.rec, (void *)hook_seen.rec, (void *)veh_seen.ctx, (void *)hook_seen.ctx);
}

static DWORD WINAPI thread_g(void *arg)
{
    reset(PLAIN);
    check_int3_values("g");
    return 0;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    char dir[MAX_PATH], path[MAX_PATH + 16], *slash;
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    uint64_t *old_hook, rsp_at, r;
    PVOID handler;

    GetModuleFileNameA(NULL, dir, sizeof(dir));
    if ((slash = strrchr(dir, '\\'))) *slash = 0;
    snprintf(path, sizeof(path), "%s\\exchook.log", dir);
    log_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    probe_log("start\n");

    dispatcher = (uint8_t *)GetProcAddress(ntdll, "KiUserExceptionDispatcher");
    pNtContinue = (void *)GetProcAddress(ntdll, "NtContinue");
    pRtlRestoreContext = (void *)GetProcAddress(ntdll, "RtlRestoreContext");
    if (!dispatcher || !check_code()) {
        probe_log("done FAIL\n");
        return 1;
    }
    handler = AddVectoredExceptionHandler(1, veh);
    old_hook = *hook_slot;
    set_hook((void *)hook_entry);

    reset(PLAIN);
    check_int3_values("b");

    reset(CHANGE);
    r = run_int3(&rsp_at);
    CHECK("c", veh_seen.seq == 2 && veh_seen.r10 == CHANGED_R10, "the handler sees the hook's r10 (%llx)",
          (unsigned long long)veh_seen.r10);
    CHECK("c", r == CHANGED_R10, "the resumed code has it (%llx)", (unsigned long long)r);

    reset(PLAIN);
    r = run_av(&rsp_at);
    CHECK("d", hook_seen.seq == 1 && veh_seen.seq == 2, "the hook ran first (%ld), then the handler (%ld)",
          hook_seen.seq, veh_seen.seq);
    CHECK("d", hook_seen.code == EXCEPTION_ACCESS_VIOLATION && hook_seen.addr == (void *)av_site &&
          hook_seen.nparams == 2 && hook_seen.info0 == 0 && hook_seen.info1 == 0x10,
          "code %08lx at %p, %lu params: %llx %llx", hook_seen.code, hook_seen.addr, hook_seen.nparams,
          (unsigned long long)hook_seen.info0, (unsigned long long)hook_seen.info1);
    CHECK("d", hook_seen.rip == (uint64_t)av_site && hook_seen.rsp == rsp_at, "Rip %llx, Rsp %llx (%llx)",
          (unsigned long long)hook_seen.rip, (unsigned long long)hook_seen.rsp, (unsigned long long)rsp_at);
    CHECK("d", hook_seen.entry_rsp + 8 == (uint64_t)hook_seen.ctx && hook_seen.rcx_arg == (uint64_t)hook_seen.ctx + 0x4f0,
          "rsp+8 = the context, the record at context+0x4f0");

    reset(RESTORE);
    r = run_int3(&rsp_at);
    CHECK("e", hook_seen.seq == 1 && veh_seen.seq == 0 && r == MAGIC_R10,
          "RtlRestoreContext from the hook resumes after the int3 (hook %ld, handler %ld)",
          hook_seen.seq, veh_seen.seq);

    reset(CONTINUE);
    r = run_int3(&rsp_at);
    CHECK("f", hook_seen.seq == 1 && veh_seen.seq == 0 && r == MAGIC_R10,
          "NtContinue from the hook resumes after the int3 (hook %ld, handler %ld)",
          hook_seen.seq, veh_seen.seq);

    {
        HANDLE t = CreateThread(NULL, 0, thread_g, NULL, 0, NULL);
        WaitForSingleObject(t, INFINITE);
        CloseHandle(t);
    }

    set_hook(old_hook);
    reset(PLAIN);
    run_int3(&rsp_at);
    CHECK("h", hook_seen.seq == 0 && veh_seen.seq == 1 && veh_seen.rip == (uint64_t)int3_site,
          "the hook's pointer back: the handler alone (%ld), Rip the int3", veh_seen.seq);

    RemoveVectoredExceptionHandler(handler);
    probe_log("done %s\n", failed ? "FAIL" : "ok");
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return failed;
}

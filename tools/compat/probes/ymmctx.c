/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * ymmctx: whether an x86-64 guest's ymm registers survive the paths where the
 * runtime holds its context (PLA-516). FEX's ARM64EC host reports AVX and AVX2
 * and keeps each ymm's high 128 bits in its own thread state; Wine's ARM64EC
 * contexts carry the low halves only (build/ymm-context/test.py). On Windows
 * the context of an exception, an APC and Get/SetThreadContext carries the
 * high halves as CONTEXT_XSTATE, and NtContinue restores them.
 *
 * Every check loads all 16 ymm registers with a known pattern in assembly,
 * lets one event happen, stores all 16 in assembly and compares, low and high
 * halves apart:
 *
 *   a  int3, a vectored handler that touches nothing: both halves kept
 *   b  an access violation in the same straight-line run of code as the loads
 *      (as a guard page or lazy commit takes one); the handler makes the page
 *      writable and the store runs again: both halves kept
 *   c  int3, the handler overwrites every ymm register itself (a handler built
 *      with AVX, a memcpy that ends in vzeroupper): Windows restores the
 *      context's XSTATE, so both halves are kept
 *   d  int3, the handler reads the context: CONTEXT_XSTATE with the AVX
 *      feature, holding the loaded high halves
 *   e  int3, the handler writes other high halves into the context's XSTATE:
 *      the resumed code must see them
 *   f  RaiseException, a handler that touches nothing (the high halves are
 *      volatile across a call in the x64 ABI: INFO only)
 *   g  int3 under a frame-based (SEH, .seh_handler) handler that overwrites
 *      every ymm register: both halves kept
 *   h  a user APC that overwrites every ymm register, run by SleepEx(0, TRUE)
 *      (a call again: INFO only)
 *   i  another thread spinning with the pattern loaded, suspended 100 times:
 *      GetThreadContext with CONTEXT_XSTATE must show the high halves, the
 *      same context set back, and the thread must end with both halves kept
 *   j  the same thread suspended once, other high halves set through
 *      SetThreadContext's XSTATE: the thread must end with them
 *   k  SetThreadContext without CONTEXT_XSTATE: both halves kept
 *
 * First it reports what the guest is told about AVX: CPUID (AVX, AVX2, FMA,
 * F16C, BMI1/2, OSXSAVE), XCR0, IsProcessorFeaturePresent and
 * GetEnabledXStateFeatures; told AVX, the five must agree. Told no AVX, there
 * is nothing to check. With `noavx` as its arguments it expects no AVX (a
 * launch with FEX_HOSTFEATURES' disableavx): AVX, AVX2, FMA, F16C, BMI1/2 and
 * XCR0's AVX bit must all be absent.
 *
 * Each line goes to OutputDebugString, stdout and <dir>\ymmctx.log. A line ends
 * "ok", "BAD" or "INFO"; the last is "ymmctx: done ok" (exit 0) or
 * "ymmctx: done FAIL" (1). x86-64 only; built with llvm-mingw by
 * tools/compat/probes/build.sh.
 */
#include <windows.h>
#include <intrin.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef __x86_64__
#error "ymmctx is an x86-64 probe"
#endif

#define REGS 16
typedef struct { uint8_t b[32]; } ymm_t;
typedef struct { ymm_t r[REGS]; } __attribute__((aligned(32))) ymmset;

static HANDLE log_file = INVALID_HANDLE_VALUE;
static int failed;

static void probe_log(const char *fmt, ...)
{
    char line[512];
    va_list ap;
    DWORD written;
    int n = snprintf(line, sizeof(line), "ymmctx: ");

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

/* The assembly. Each ymm_run_* (rcx = the set to load, rdx = where to store
 * it, r8 = its own argument) saves the callee-saved xmm6-15, loads ymm0-15,
 * runs its event, stores ymm0-15 and returns. The frame: 0x20 shadow space,
 * xmm6-15 at 0x20-0xbf, the store pointer at 0xc0. */
#define LOAD_ALL(p) \
    "\tvmovdqu 0x000(" p "), %ymm0\n\tvmovdqu 0x020(" p "), %ymm1\n\tvmovdqu 0x040(" p "), %ymm2\n" \
    "\tvmovdqu 0x060(" p "), %ymm3\n\tvmovdqu 0x080(" p "), %ymm4\n\tvmovdqu 0x0a0(" p "), %ymm5\n" \
    "\tvmovdqu 0x0c0(" p "), %ymm6\n\tvmovdqu 0x0e0(" p "), %ymm7\n\tvmovdqu 0x100(" p "), %ymm8\n" \
    "\tvmovdqu 0x120(" p "), %ymm9\n\tvmovdqu 0x140(" p "), %ymm10\n\tvmovdqu 0x160(" p "), %ymm11\n" \
    "\tvmovdqu 0x180(" p "), %ymm12\n\tvmovdqu 0x1a0(" p "), %ymm13\n\tvmovdqu 0x1c0(" p "), %ymm14\n" \
    "\tvmovdqu 0x1e0(" p "), %ymm15\n"
#define STORE_ALL(p) \
    "\tvmovdqu %ymm0, 0x000(" p ")\n\tvmovdqu %ymm1, 0x020(" p ")\n\tvmovdqu %ymm2, 0x040(" p ")\n" \
    "\tvmovdqu %ymm3, 0x060(" p ")\n\tvmovdqu %ymm4, 0x080(" p ")\n\tvmovdqu %ymm5, 0x0a0(" p ")\n" \
    "\tvmovdqu %ymm6, 0x0c0(" p ")\n\tvmovdqu %ymm7, 0x0e0(" p ")\n\tvmovdqu %ymm8, 0x100(" p ")\n" \
    "\tvmovdqu %ymm9, 0x120(" p ")\n\tvmovdqu %ymm10, 0x140(" p ")\n\tvmovdqu %ymm11, 0x160(" p ")\n" \
    "\tvmovdqu %ymm12, 0x180(" p ")\n\tvmovdqu %ymm13, 0x1a0(" p ")\n\tvmovdqu %ymm14, 0x1c0(" p ")\n" \
    "\tvmovdqu %ymm15, 0x1e0(" p ")\n"
#define SAVE_XMM \
    "\tmovdqu %xmm6, 0x20(%rsp)\n\tmovdqu %xmm7, 0x30(%rsp)\n\tmovdqu %xmm8, 0x40(%rsp)\n" \
    "\tmovdqu %xmm9, 0x50(%rsp)\n\tmovdqu %xmm10, 0x60(%rsp)\n\tmovdqu %xmm11, 0x70(%rsp)\n" \
    "\tmovdqu %xmm12, 0x80(%rsp)\n\tmovdqu %xmm13, 0x90(%rsp)\n\tmovdqu %xmm14, 0xa0(%rsp)\n" \
    "\tmovdqu %xmm15, 0xb0(%rsp)\n"
#define RESTORE_XMM \
    "\tmovdqu 0x20(%rsp), %xmm6\n\tmovdqu 0x30(%rsp), %xmm7\n\tmovdqu 0x40(%rsp), %xmm8\n" \
    "\tmovdqu 0x50(%rsp), %xmm9\n\tmovdqu 0x60(%rsp), %xmm10\n\tmovdqu 0x70(%rsp), %xmm11\n" \
    "\tmovdqu 0x80(%rsp), %xmm12\n\tmovdqu 0x90(%rsp), %xmm13\n\tmovdqu 0xa0(%rsp), %xmm14\n" \
    "\tmovdqu 0xb0(%rsp), %xmm15\n"
#define RUN_FN(name, handler, body) \
    ".text\n.globl " #name "\n.def " #name "; .scl 2; .type 32; .endef\n" #name ":\n" \
    ".seh_proc " #name "\n" handler \
    "\tsubq $0xd8, %rsp\n.seh_stackalloc 0xd8\n.seh_endprologue\n" \
    "\tmovq %rdx, 0xc0(%rsp)\n" SAVE_XMM LOAD_ALL("%rcx") body \
    "\tmovq 0xc0(%rsp), %rax\n" STORE_ALL("%rax") \
    "\tvzeroupper\n" RESTORE_XMM "\taddq $0xd8, %rsp\n\tret\n.seh_endproc\n"

void ymm_run_int3(const ymmset *in, ymmset *out, void *arg);
void ymm_run_store(const ymmset *in, ymmset *out, void *arg);
void ymm_run_raise(const ymmset *in, ymmset *out, void *arg);
void ymm_run_int3_seh(const ymmset *in, ymmset *out, void *arg);
void ymm_run_sleepex(const ymmset *in, ymmset *out, void *arg);
void ymm_spin(const ymmset *in, ymmset *out, volatile LONG *flags);
void ymm_clobber(void);
extern const char ymm_int3_resume[], ymm_int3_seh_resume[];
EXCEPTION_DISPOSITION seh_continue(EXCEPTION_RECORD *, void *, CONTEXT *, void *);

__asm__(
    /* a, c, d, e: int3, resumed after it. */
    RUN_FN(ymm_run_int3, "", "\tint3\n.globl ymm_int3_resume\nymm_int3_resume:\n")
    /* b: one store to r8 right after the loads, no branch between them. */
    RUN_FN(ymm_run_store, "", "\tmovl $1, (%r8)\n")
    /* f: RaiseException(r8 = code, 0, 0, NULL). */
    RUN_FN(ymm_run_raise, "", "\tmovl %r8d, %ecx\n\txorl %edx, %edx\n\txorl %r8d, %r8d\n\txorl %r9d, %r9d\n"
                              "\tcallq *__imp_RaiseException(%rip)\n")
    /* g: int3 with this frame's own exception handler. */
    RUN_FN(ymm_run_int3_seh, ".seh_handler seh_continue, @except\n",
           "\tint3\n.globl ymm_int3_seh_resume\nymm_int3_seh_resume:\n")
    /* h: SleepEx(0, TRUE), which runs the queued APC. */
    RUN_FN(ymm_run_sleepex, "", "\txorl %ecx, %ecx\n\tmovl $1, %edx\n\tcallq *__imp_SleepEx(%rip)\n")
    /* i-k: flags[0] = 1 once loaded, then spin until flags[1] != 0. The loop goes
     * back with an unconditional jmp, where FEX checks its suspend doorbell. */
    RUN_FN(ymm_spin, "", "\tmovl $1, (%r8)\n1:\n\tcmpl $0, 4(%r8)\n\tjne 2f\n\tjmp 1b\n2:\n")
    /* Every ymm register to all ones, as a handler built with AVX would leave them. */
    ".text\n.globl ymm_clobber\n.def ymm_clobber; .scl 2; .type 32; .endef\nymm_clobber:\n"
    "\tvpcmpeqd %ymm0, %ymm0, %ymm0\n\tvpcmpeqd %ymm1, %ymm1, %ymm1\n\tvpcmpeqd %ymm2, %ymm2, %ymm2\n"
    "\tvpcmpeqd %ymm3, %ymm3, %ymm3\n\tvpcmpeqd %ymm4, %ymm4, %ymm4\n\tvpcmpeqd %ymm5, %ymm5, %ymm5\n"
    "\tvpcmpeqd %ymm6, %ymm6, %ymm6\n\tvpcmpeqd %ymm7, %ymm7, %ymm7\n\tvpcmpeqd %ymm8, %ymm8, %ymm8\n"
    "\tvpcmpeqd %ymm9, %ymm9, %ymm9\n\tvpcmpeqd %ymm10, %ymm10, %ymm10\n\tvpcmpeqd %ymm11, %ymm11, %ymm11\n"
    "\tvpcmpeqd %ymm12, %ymm12, %ymm12\n\tvpcmpeqd %ymm13, %ymm13, %ymm13\n\tvpcmpeqd %ymm14, %ymm14, %ymm14\n"
    "\tvpcmpeqd %ymm15, %ymm15, %ymm15\n\tret\n");

static void fill(ymmset *s, uint8_t seed)
{
    for (int r = 0; r < REGS; r++)
        for (int i = 0; i < 32; i++) s->r[r].b[i] = (uint8_t)(seed + r * 37 + i * 5 + (i >> 4) * 0x80);
}

/* How many registers' low (bytes 0-15) and high (16-31) halves match. */
static void compare(const ymmset *got, const ymmset *want, int *low, int *high)
{
    *low = *high = 0;
    for (int r = 0; r < REGS; r++) {
        *low += !memcmp(got->r[r].b, want->r[r].b, 16);
        *high += !memcmp(got->r[r].b + 16, want->r[r].b + 16, 16);
    }
}

/* The high halves as the context's XSTATE holds them (YMM_CONTEXT: Ymm0-15's high halves). */
static int xstate_high(CONTEXT *ctx, const ymmset *want, M128A **area)
{
    DWORD len = 0;
    M128A *ymm;
    int same = 0;

    *area = NULL;
    if ((ctx->ContextFlags & CONTEXT_XSTATE) != CONTEXT_XSTATE) return -1;
    if (!(ymm = LocateXStateFeature(ctx, XSTATE_AVX, &len)) || len < REGS * sizeof(M128A)) return -2;
    *area = ymm;
    for (int r = 0; r < REGS; r++) same += !memcmp(&ymm[r], want->r[r].b + 16, 16);
    return same;
}

static const char *xstate_why(int n)
{
    return n == -1 ? "no CONTEXT_XSTATE" : n == -2 ? "no AVX feature in it" : "";
}

/* What the handlers do, set before each check. */
enum mode { QUIET, CLOBBER, READ, WRITE };
static volatile enum mode mode;
static volatile int handled, use_veh;
static ymmset loaded, other;
static int seen_flags = -3;
static void *fault_page;

static void act(CONTEXT *ctx)
{
    M128A *area;

    if (mode == CLOBBER) ymm_clobber();
    if (mode == READ) seen_flags = xstate_high(ctx, &loaded, &area);
    if (mode == WRITE) {
        seen_flags = xstate_high(ctx, &loaded, &area);
        if (area) {
            for (int r = 0; r < REGS; r++) memcpy(&area[r], other.r[r].b + 16, 16);
            SetXStateFeaturesMask(ctx, XSTATE_MASK_LEGACY | XSTATE_MASK_AVX);
        }
    }
}

static LONG CALLBACK veh(EXCEPTION_POINTERS *ep)
{
    EXCEPTION_RECORD *rec = ep->ExceptionRecord;
    DWORD old;

    if (!use_veh) return EXCEPTION_CONTINUE_SEARCH;
    if (rec->ExceptionCode == EXCEPTION_BREAKPOINT) {
        ep->ContextRecord->Rip = (DWORD64)(uintptr_t)ymm_int3_resume;
    } else if (rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && fault_page &&
               rec->NumberParameters >= 2 && (void *)rec->ExceptionInformation[1] == fault_page) {
        if (!VirtualProtect(fault_page, 4096, PAGE_READWRITE, &old)) return EXCEPTION_CONTINUE_SEARCH;
    } else if (rec->ExceptionCode != 0xe0001234) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    handled++;
    act(ep->ContextRecord);
    return EXCEPTION_CONTINUE_EXECUTION;
}

EXCEPTION_DISPOSITION seh_continue(EXCEPTION_RECORD *rec, void *frame, CONTEXT *ctx, void *dispatch)
{
    if (rec->ExceptionCode != EXCEPTION_BREAKPOINT || (rec->ExceptionFlags & EXCEPTION_UNWINDING))
        return ExceptionContinueSearch;
    ctx->Rip = (DWORD64)(uintptr_t)ymm_int3_seh_resume;
    handled++;
    act(ctx);
    return ExceptionContinueExecution;
}

static void report(const char *id, const char *what, const ymmset *got, const ymmset *want_high_from, int info)
{
    int low, high, lowx, highx;
    ymmset want = loaded;

    for (int r = 0; r < REGS; r++) memcpy(want.r[r].b + 16, want_high_from->r[r].b + 16, 16);
    compare(got, &want, &low, &high);
    compare(got, &loaded, &lowx, &highx);
    (void)lowx;
    probe_log("CHECK %s %s: low halves %d/16, high halves %d/16 (%d/16 still the loaded ones): %s\n", id, what, low, high,
              highx, info ? "INFO" : verdict(low == REGS && high == REGS));
}

static void check_exception(const char *id, const char *what, enum mode m, void (*run)(const ymmset *, ymmset *, void *),
                            void *arg, int veh_on, int info)
{
    ymmset out;

    memset(&out, 0, sizeof(out));
    mode = m;
    use_veh = veh_on;
    handled = 0;
    seen_flags = -3;
    run(&loaded, &out, arg);
    use_veh = 0;
    if (handled != 1) probe_log("CHECK %s %s: the handler ran %d times: %s\n", id, what, handled, verdict(0));
    if (m == READ || m == WRITE)
        probe_log("CHECK %s %s: the handler's context holds the loaded high halves: %s%s%d/16: %s\n", id, what,
                  xstate_why(seen_flags), seen_flags < 0 ? ", " : "", seen_flags < 0 ? 0 : seen_flags,
                  verdict(seen_flags == REGS));
    report(id, what, &out, m == WRITE ? &other : &loaded, info);
}

static void CALLBACK apc_clobber(ULONG_PTR arg)
{
    handled++;
    ymm_clobber();
}

/* i-k: the spinning thread. */
struct spin { ymmset in, out; volatile LONG flags[2]; };

static DWORD WINAPI spin_thread(void *p)
{
    struct spin *s = p;
    ymm_spin(&s->in, &s->out, s->flags);
    return 0;
}

static HANDLE spin_start(struct spin *s)
{
    HANDLE t;

    memset(s, 0, sizeof(*s));
    s->in = loaded;
    if (!(t = CreateThread(NULL, 0, spin_thread, s, 0, NULL))) return NULL;
    for (int i = 0; i < 5000 && !s->flags[0]; i++) Sleep(1);
    return t;
}

static int spin_end(HANDLE t, struct spin *s)
{
    DWORD r;
    InterlockedExchange(&s->flags[1], 1);
    r = WaitForSingleObject(t, 10000);
    CloseHandle(t);
    return r == WAIT_OBJECT_0;
}

/* A CONTEXT with room for XSTATE and the AVX feature asked for, or NULL. */
static CONTEXT *xstate_context(void **buffer)
{
    DWORD len = 0;
    CONTEXT *ctx = NULL;
    DWORD flags = CONTEXT_FULL | CONTEXT_XSTATE;

    *buffer = NULL;
    InitializeContext(NULL, flags, NULL, &len);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !len) return NULL;
    if (!(*buffer = calloc(1, len))) return NULL;
    if (!InitializeContext(*buffer, flags, &ctx, &len) || !SetXStateFeaturesMask(ctx, XSTATE_MASK_AVX)) {
        free(*buffer);
        *buffer = NULL;
        return NULL;
    }
    return ctx;
}

static void check_suspend(void)
{
    struct spin s;
    HANDLE t;
    void *buffer;
    CONTEXT *ctx, plain;
    M128A *area;
    int rounds = 0, visible = 0, set_ok = 0, why = 0;

    if (!(ctx = xstate_context(&buffer)))
        probe_log("CHECK i InitializeContext with CONTEXT_XSTATE and AVX (GetEnabledXStateFeatures %#llx): %s\n",
                  (unsigned long long)GetEnabledXStateFeatures(), verdict(0));
    if (!(t = spin_start(&s)) || !s.flags[0]) {
        probe_log("CHECK i the spinning thread starts: %s\n", verdict(0));
        return;
    }
    for (int i = 0; i < 100; i++) {
        if (SuspendThread(t) == (DWORD)-1) break;
        rounds++;
        if (ctx) {
            ctx->ContextFlags = CONTEXT_FULL | CONTEXT_XSTATE;
            SetXStateFeaturesMask(ctx, XSTATE_MASK_AVX);
            if (GetThreadContext(t, ctx)) {
                int n = xstate_high(ctx, &loaded, &area);
                if (n == REGS) visible++;
                else if (!why) why = n;
                set_ok += !!SetThreadContext(t, ctx);
            }
        }
        ResumeThread(t);
        Sleep(1);
    }
    if (ctx)
        probe_log("CHECK i GetThreadContext shows the high halves %d of %d times%s%s: %s\n", visible, rounds,
                  why < 0 ? ", else " : "", why < 0 ? xstate_why(why) : "", verdict(visible == rounds && rounds));
    if (ctx) probe_log("CHECK i SetThreadContext with that context %d of %d times: %s\n", set_ok, rounds, verdict(set_ok == rounds));
    probe_log("CHECK i the thread ends: %s\n", verdict(spin_end(t, &s)));
    report("i", "100 suspends with Get/SetThreadContext", &s.out, &loaded, 0);

    if (ctx && (t = spin_start(&s)) && s.flags[0]) {
        int got = 0, n = -3;
        if (SuspendThread(t) != (DWORD)-1) {
            ctx->ContextFlags = CONTEXT_FULL | CONTEXT_XSTATE;
            SetXStateFeaturesMask(ctx, XSTATE_MASK_AVX);
            if (GetThreadContext(t, ctx) && (n = xstate_high(ctx, &loaded, &area)) >= 0 && area) {
                for (int r = 0; r < REGS; r++) memcpy(&area[r], other.r[r].b + 16, 16);
                SetXStateFeaturesMask(ctx, XSTATE_MASK_AVX);
                got = !!SetThreadContext(t, ctx);
            }
            ResumeThread(t);
        }
        probe_log("CHECK j SetThreadContext with other high halves in XSTATE%s%s: %s\n", n < 0 ? ": " : "",
                  n < 0 ? xstate_why(n) : "", verdict(got));
        probe_log("CHECK j the thread ends: %s\n", verdict(spin_end(t, &s)));
        report("j", "high halves set through SetThreadContext", &s.out, &other, 0);
    }

    if ((t = spin_start(&s)) && s.flags[0]) {
        int got = 0;
        if (SuspendThread(t) != (DWORD)-1) {
            plain.ContextFlags = CONTEXT_FULL;
            got = GetThreadContext(t, &plain) && SetThreadContext(t, &plain);
            ResumeThread(t);
        }
        probe_log("CHECK k Get/SetThreadContext with CONTEXT_FULL: %s\n", verdict(got));
        probe_log("CHECK k the thread ends: %s\n", verdict(spin_end(t, &s)));
        report("k", "SetThreadContext without XSTATE", &s.out, &loaded, 0);
    }
    free(buffer);
}

/* What the guest is told about AVX; returns whether it is offered. */
static int avx_view(int expect_none)
{
    int r1[4], r7[4];
    unsigned long long xcr0 = 0, enabled = GetEnabledXStateFeatures();
    int osxsave, avx, avx2, fma, f16c, bmi1, bmi2, pf_avx, pf_avx2;

    __cpuid(r1, 1);
    __cpuidex(r7, 7, 0);
    osxsave = !!(r1[2] & (1 << 27));
    avx = !!(r1[2] & (1 << 28));
    fma = !!(r1[2] & (1 << 12));
    f16c = !!(r1[2] & (1 << 29));
    avx2 = !!(r7[1] & (1 << 5));
    bmi1 = !!(r7[1] & (1 << 3));
    bmi2 = !!(r7[1] & (1 << 8));
    if (osxsave) {
        unsigned int lo, hi;
        __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
        xcr0 = ((unsigned long long)hi << 32) | lo;
    }
    pf_avx = IsProcessorFeaturePresent(PF_AVX_INSTRUCTIONS_AVAILABLE);
    pf_avx2 = IsProcessorFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE);
    probe_log("cpuid: OSXSAVE %d AVX %d AVX2 %d FMA %d F16C %d BMI1 %d BMI2 %d; XCR0 %#llx; "
              "IsProcessorFeaturePresent AVX %d AVX2 %d; GetEnabledXStateFeatures %#llx\n",
              osxsave, avx, avx2, fma, f16c, bmi1, bmi2, xcr0, pf_avx, pf_avx2, enabled);
    if (expect_none) {
        probe_log("CHECK noavx: no AVX, AVX2, FMA, F16C, BMI1, BMI2 or XCR0 AVX: %s\n",
                  verdict(!avx && !avx2 && !fma && !f16c && !bmi1 && !bmi2 && !(xcr0 & 4)));
        probe_log("CHECK noavx: IsProcessorFeaturePresent says no AVX or AVX2: %s\n", verdict(!pf_avx && !pf_avx2));
        return 0;
    }
    if (!avx) return 0;
    probe_log("CHECK told AVX: OSXSAVE, XCR0 x87|SSE|AVX, IsProcessorFeaturePresent and GetEnabledXStateFeatures agree: %s\n",
              verdict(osxsave && (xcr0 & 7) == 7 && pf_avx && (enabled & XSTATE_MASK_AVX)));
    return osxsave && (xcr0 & 6) == 6;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    char dir[MAX_PATH], path[MAX_PATH + 16], *slash;
    int expect_none = cmdline && strstr(cmdline, "noavx");
    PVOID handler;
    DWORD old;

    GetModuleFileNameA(NULL, dir, sizeof(dir));
    if ((slash = strrchr(dir, '\\'))) *slash = 0;
    snprintf(path, sizeof(path), "%s\\ymmctx.log", dir);
    log_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    probe_log("start: arguments \"%s\"\n", cmdline ? cmdline : "");

    if (!avx_view(expect_none)) {
        probe_log("no AVX offered: nothing to check\n");
    } else {
        fill(&loaded, 0x11);
        fill(&other, 0xa5);
        handler = AddVectoredExceptionHandler(1, veh);
        check_exception("a", "int3, quiet handler", QUIET, ymm_run_int3, NULL, 1, 0);
        fault_page = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READONLY);
        check_exception("b", "access violation after the loads, page made writable", QUIET, ymm_run_store, fault_page, 1, 0);
        VirtualProtect(fault_page, 4096, PAGE_READONLY, &old);
        check_exception("c", "int3, handler overwrites ymm", CLOBBER, ymm_run_int3, NULL, 1, 0);
        check_exception("d", "int3, handler reads XSTATE", READ, ymm_run_int3, NULL, 1, 0);
        check_exception("e", "int3, handler writes XSTATE", WRITE, ymm_run_int3, NULL, 1, 0);
        check_exception("f", "RaiseException, quiet handler", QUIET, ymm_run_raise, (void *)(uintptr_t)0xe0001234, 1, 1);
        check_exception("g", "int3, SEH frame handler overwrites ymm", CLOBBER, ymm_run_int3_seh, NULL, 0, 0);
        RemoveVectoredExceptionHandler(handler);
        VirtualFree(fault_page, 0, MEM_RELEASE);
        fault_page = NULL;
        {
            ymmset out;
            handled = 0;
            QueueUserAPC(apc_clobber, GetCurrentThread(), 0);
            ymm_run_sleepex(&loaded, &out, NULL);
            probe_log("CHECK h the APC ran: %s\n", verdict(handled == 1));
            report("h", "SleepEx with an APC that overwrites ymm", &out, &loaded, 1);
        }
        check_suspend();
    }
    probe_log("done %s\n", failed ? "FAIL" : "ok");
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return failed;
}

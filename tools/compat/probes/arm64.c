/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * arm64: a plain ARM64 Windows program, which the x86-64 session starts as a
 * native ARM64 child with its own aarch64 ntdll and no FEX (PLA-512,
 * decision 0170).
 *
 *   machine  IsWow64Process2 says the process is not a WoW64 one and the
 *            host is ARM64; neither wow64.dll nor FEX (xtajit64.dll,
 *            libarm64ecfex.dll) is loaded; kernel32.dll came from
 *            C:\windows\sysarm64; ntdll.dll has no ARM64EC export
 *   load     LoadLibrary of a system DLL not yet loaded (version.dll), from
 *            sysarm64, and a call into it
 *   rwx      code written into PAGE_EXECUTE_READWRITE memory, flushed with
 *            FlushInstructionCache and called; rewritten in place and called
 *            again; a second copy made executable by VirtualProtect
 *            (PAGE_READWRITE to PAGE_EXECUTE_READ) and called: the runtime's
 *            anonymous executable path; 800 allocations of 1.3 MB of RWX
 *            memory, each run and freed, more than the JIT pool holds
 *            (freed RWX memory must give its pool space back); on ARM64,
 *            system32\ntdll.dll read into RWX memory and its
 *            NtProtectVirtualMemory export called there, as World of
 *            Warcraft does (an x86-64 stub in Playport's ARM64EC ntdll)
 *   thread   a second thread runs and returns its exit code
 *   child    the program again as a child with `exit 7`: a native ARM64
 *            child of a native ARM64 child; its exit code must be 7
 *   x18      only with `x18` as the command line (PLA-516), after the checks
 *            above: what happens to x18 in a native ARM64 child. x18 is set
 *            to a sentinel, then each of: nothing; a 20 ms spin (interrupts);
 *            a raw Darwin getpid (svc, a kernel entry with no wait); a raw
 *            Mach thread_switch waiting 50 ms (svc, a context switch); the
 *            Wine calls NtYieldExecution, Sleep(0), Sleep(50); a UDF round
 *            trip through a vectored handler. After each, x18 is read back:
 *            kept (the sentinel), TEB (what Wine put there), zero (the
 *            kernel's) or other. The sequence runs plain, then armed: TPIDR_EL0
 *            bit 48 set first, the custom x18 ABI bit that macOS 26.4's
 *            os_set_custom_x18_abi_enabled sets (madeira-unix 0272 calls it at
 *            thread start with madeira.cfg x18-abi = 1), and the bit read after.
 *            x18 is read only by SP-relative stores, which the runtime's x18
 *            patcher leaves alone. One line "arm64: x18-abi: VERDICT ..."
 *            sums it up; the phase never changes the exit code.
 *
 * Each line goes to OutputDebugString and <dir>\arm64.log; the last line is
 * "arm64: done ok" and the exit code is 42, or "arm64: done FAIL" and 1.
 * With `exit N` on its command line it exits with N at once, with no log.
 *
 * Built with llvm-mingw for aarch64 by tools/compat/probes/build.sh, also
 * as two variants of this file:
 *   PROBE_FAULT  arm64-fault.exe: logs, then writes through a null pointer;
 *                the play must end as a failed one (exit 0xc0000005)
 *   PROBE_MIN    arm64-min.exe: no C runtime, imports only kernel32.dll and
 *                calls ExitProcess(42) (a loader-only start)
 * An x86-64 build of the default program (the rwx bytes are x86 there) runs
 * under desktop Wine as a check of the program itself.
 */
#include <windows.h>

#ifdef PROBE_MIN

void entry(void)
{
    ExitProcess(42);
}

#else

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HANDLE log_file = INVALID_HANDLE_VALUE;
static int failed;
static char exe_path[MAX_PATH];

static void probe_log(const char *fmt, ...)
{
    char line[1024];
    va_list ap;
    DWORD written;
    int n = snprintf(line, sizeof(line), "arm64: ");

    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    OutputDebugStringA(line);
    if (log_file != INVALID_HANDLE_VALUE) WriteFile(log_file, line, (DWORD)strlen(line), &written, NULL);
}

static void check(const char *what, int ok)
{
    probe_log("CHECK %s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) failed = 1;
}

#ifdef __aarch64__
static int module_from_sysarm64(HMODULE module)
{
    char path[MAX_PATH];

    if (!module || !GetModuleFileNameA(module, path, sizeof(path))) return 0;
    probe_log("module %p: %s\n", (void *)module, path);
    _strlwr(path);
    return strstr(path, "\\sysarm64\\") != NULL;
}
#endif

static void machine_phase(void)
{
    typedef BOOL (WINAPI *is_wow64_process2_fn)(HANDLE, USHORT *, USHORT *);
    is_wow64_process2_fn is_wow64_process2 =
        (is_wow64_process2_fn)(void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "IsWow64Process2");
    USHORT process = 0xffff, native = 0xffff;

    probe_log("machine: built for %s\n",
#ifdef __aarch64__
              "aarch64"
#else
              "x86-64"
#endif
    );
    check("IsWow64Process2 present", is_wow64_process2 != NULL);
    if (is_wow64_process2 && is_wow64_process2(GetCurrentProcess(), &process, &native))
    {
        probe_log("machine: IsWow64Process2 process %#x native %#x\n", process, native);
        check("not a WoW64 process", process == IMAGE_FILE_MACHINE_UNKNOWN);
#ifdef __aarch64__
        check("native machine is ARM64", native == IMAGE_FILE_MACHINE_ARM64);
#endif
    }
    else
        check("IsWow64Process2 succeeds", 0);
    check("wow64.dll not loaded", GetModuleHandleA("wow64.dll") == NULL);
    check("xtajit64.dll not loaded (no FEX)", GetModuleHandleA("xtajit64.dll") == NULL);
    check("libarm64ecfex.dll not loaded (no FEX)", GetModuleHandleA("libarm64ecfex.dll") == NULL);
#ifdef __aarch64__
    check("kernel32.dll from sysarm64", module_from_sysarm64(GetModuleHandleA("kernel32.dll")));
    /* KiUserEmulationDispatcher is exported by the ARM64EC ntdll only. */
    check("ntdll.dll is the aarch64 build, not the session's ARM64EC one",
          GetProcAddress(GetModuleHandleA("ntdll.dll"), "KiUserEmulationDispatcher") == NULL);
#endif
}

static void load_phase(void)
{
    typedef DWORD (WINAPI *size_fn)(LPCSTR, LPDWORD);
    HMODULE version;
    size_fn size;
    DWORD handle = 0, bytes = 0;
    char kernel32[MAX_PATH];

    check("version.dll not loaded before", GetModuleHandleA("version.dll") == NULL);
    version = LoadLibraryA("version.dll");
    check("LoadLibrary(version.dll)", version != NULL);
    if (!version) return;
#ifdef __aarch64__
    check("version.dll from sysarm64", module_from_sysarm64(version));
#endif
    size = (size_fn)(void *)GetProcAddress(version, "GetFileVersionInfoSizeA");
    check("GetProcAddress(GetFileVersionInfoSizeA)", size != NULL);
    if (size && GetModuleFileNameA(GetModuleHandleA("kernel32.dll"), kernel32, sizeof(kernel32)))
    {
        bytes = size(kernel32, &handle);
        probe_log("load: GetFileVersionInfoSizeA(kernel32) = %lu\n", bytes);
        check("a call into version.dll", bytes > 0);
    }
    FreeLibrary(version);
}

/* Code that returns value: movz w0, #value; ret on ARM64, mov eax, value; ret on x86-64. */
static size_t emit_return(unsigned char *code, unsigned int value)
{
#ifdef __aarch64__
    DWORD insn[2] = { 0x52800000 | ((value & 0xffff) << 5), 0xd65f03c0 };
    memcpy(code, insn, sizeof(insn));
    return sizeof(insn);
#else
    code[0] = 0xb8;
    memcpy(code + 1, &value, 4);
    code[5] = 0xc3;
    return 6;
#endif
}

typedef unsigned int (*code_fn)(void);

/* RWX memory freed and allocated again gives its JIT-pool space back (madeira-unix 0269, PLA-514): 800 copies of
 * 1.3 MB, World of Warcraft's size, are about 1 GB, more than the pool has room for. The pause keeps the copies
 * freed within the pool's 3 s reuse grace to about 160 MB. */
static void rwx_churn(void)
{
    const SIZE_T size = 0x148000;
    unsigned int i, ok = 0;

    for (i = 0; i < 800; i++)
    {
        unsigned char *rwx = VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        size_t len;

        if (!rwx)
        {
            probe_log("rwx churn: VirtualAlloc %u failed, error %lu\n", i, GetLastError());
            break;
        }
        len = emit_return(rwx + size - 0x4000, i);
        FlushInstructionCache(GetCurrentProcess(), rwx + size - 0x4000, len);
        if (((code_fn)(void *)(rwx + size - 0x4000))() == i) ok++;
        VirtualFree(rwx, 0, MEM_RELEASE);
        Sleep(20);
    }
    probe_log("rwx churn: %u of 800 allocations of 0x%lx bytes ran their code\n", ok, (unsigned long)size);
    check("800 RWX allocations freed and made again all run", ok == 800);
}

#ifdef __aarch64__
typedef LONG (WINAPI *protect_fn)(HANDLE, void **, SIZE_T *, ULONG, ULONG *);

/* The file offset of rva in a PE file with these section headers. */
static DWORD file_offset(const IMAGE_SECTION_HEADER *sec, unsigned int count, DWORD rva)
{
    unsigned int i;

    for (i = 0; i < count; i++)
        if (rva >= sec[i].VirtualAddress && rva < sec[i].VirtualAddress + sec[i].SizeOfRawData)
            return rva - sec[i].VirtualAddress + sec[i].PointerToRawData;
    return rva;
}

/* system32\ntdll.dll read from disk into RWX memory and its NtProtectVirtualMemory export called there, as World of
 * Warcraft does (madeira-unix 0268, PLA-514). On Windows the file is ARM64X and the export is `svc #id; ret`; here it
 * is the ARM64EC ntdll, whose export is an x86-64 stub the runtime turns into the system call. */
static void disk_ntdll_syscall(void)
{
    char path[MAX_PATH + 16];
    unsigned char *file = NULL, *page = NULL;
    DWORD got = 0, i;
    HANDLE h;
    LARGE_INTEGER fsize;
    IMAGE_NT_HEADERS64 *nt;
    IMAGE_SECTION_HEADER *sec;
    IMAGE_EXPORT_DIRECTORY *exp;
    DWORD *names, *funcs, rva = 0;
    WORD *ordinals;
    void *base;
    SIZE_T len = 0x1000;
    ULONG old = 0;
    LONG status = -1;
    MEMORY_BASIC_INFORMATION mbi;

#define RAW(r) (file + file_offset(sec, nt->FileHeader.NumberOfSections, (r)))
    GetSystemDirectoryA(path, MAX_PATH);
    strcat(path, "\\ntdll.dll");
    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    check("open system32\\ntdll.dll", h != INVALID_HANDLE_VALUE);
    if (h == INVALID_HANDLE_VALUE) return;
    GetFileSizeEx(h, &fsize);
    file = VirtualAlloc(NULL, fsize.LowPart, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (file) ReadFile(h, file, fsize.LowPart, &got, NULL);
    CloseHandle(h);
    check("read system32\\ntdll.dll into RWX memory", file && got == fsize.LowPart);
    if (!file || got != fsize.LowPart) goto done;

    nt = (IMAGE_NT_HEADERS64 *)(file + ((IMAGE_DOS_HEADER *)file)->e_lfanew);
    sec = IMAGE_FIRST_SECTION(nt);
    exp = (IMAGE_EXPORT_DIRECTORY *)RAW(nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress);
    names = (DWORD *)RAW(exp->AddressOfNames);
    funcs = (DWORD *)RAW(exp->AddressOfFunctions);
    ordinals = (WORD *)RAW(exp->AddressOfNameOrdinals);
    for (i = 0; i < exp->NumberOfNames; i++)
        if (!strcmp((const char *)RAW(names[i]), "NtProtectVirtualMemory")) rva = funcs[ordinals[i]];
    probe_log("disk ntdll: %s, NtProtectVirtualMemory at RVA 0x%lx\n", path, rva);
    check("NtProtectVirtualMemory in the file's exports", rva != 0);
    if (!rva) goto done;

    page = VirtualAlloc(NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    base = page;
    FlushInstructionCache(GetCurrentProcess(), file, fsize.LowPart);
    status = ((protect_fn)(void *)RAW(rva))(GetCurrentProcess(), &base, &len, PAGE_READONLY, &old);
    VirtualQuery(page, &mbi, sizeof(mbi));
    probe_log("disk ntdll: NtProtectVirtualMemory returned 0x%lx, old 0x%lx, now 0x%lx\n", (unsigned long)status,
              old, mbi.Protect);
    check("the disk copy's NtProtectVirtualMemory makes a page read-only",
          status == 0 && old == PAGE_READWRITE && mbi.Protect == PAGE_READONLY);
done:
    if (page) VirtualFree(page, 0, MEM_RELEASE);
    if (file) VirtualFree(file, 0, MEM_RELEASE);
#undef RAW
}
#endif

static void rwx_phase(void)
{
    const SIZE_T size = 0x10000;
    unsigned char *rwx = VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    unsigned char *wx;
    DWORD old;
    size_t len;
    unsigned int got;

    check("VirtualAlloc(PAGE_EXECUTE_READWRITE)", rwx != NULL);
    if (!rwx) return;
    len = emit_return(rwx, 1234);
    check("FlushInstructionCache", FlushInstructionCache(GetCurrentProcess(), rwx, len));
    got = ((code_fn)(void *)rwx)();
    probe_log("rwx: first code returned %u\n", got);
    check("RWX code runs", got == 1234);

    len = emit_return(rwx, 4321);
    FlushInstructionCache(GetCurrentProcess(), rwx, len);
    got = ((code_fn)(void *)rwx)();
    probe_log("rwx: rewritten code returned %u\n", got);
    check("RWX code rewritten in place runs the new code", got == 4321);

    len = emit_return(rwx + 0x8000, 777);
    FlushInstructionCache(GetCurrentProcess(), rwx + 0x8000, len);
    got = ((code_fn)(void *)(rwx + 0x8000))();
    probe_log("rwx: code in a later page returned %u\n", got);
    check("RWX code in a later page runs", got == 777);
    VirtualFree(rwx, 0, MEM_RELEASE);

    wx = VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    check("VirtualAlloc(PAGE_READWRITE)", wx != NULL);
    if (!wx) return;
    len = emit_return(wx, 99);
    check("VirtualProtect(PAGE_EXECUTE_READ)", VirtualProtect(wx, size, PAGE_EXECUTE_READ, &old));
    FlushInstructionCache(GetCurrentProcess(), wx, len);
    got = ((code_fn)(void *)wx)();
    probe_log("rwx: write-then-protect code returned %u\n", got);
    check("RW code made executable runs", got == 99);
    VirtualFree(wx, 0, MEM_RELEASE);

    rwx_churn();
#ifdef __aarch64__
    disk_ntdll_syscall();
#endif
}

static DWORD WINAPI thread_main(void *arg)
{
    return (DWORD)(ULONG_PTR)arg * 2;
}

static void thread_phase(void)
{
    HANDLE thread = CreateThread(NULL, 0, thread_main, (void *)(ULONG_PTR)21, 0, NULL);
    DWORD code = 0;

    check("CreateThread", thread != NULL);
    if (!thread) return;
    check("thread ends", WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0);
    GetExitCodeThread(thread, &code);
    probe_log("thread: exit code %lu\n", code);
    check("thread exit code 42", code == 42);
    CloseHandle(thread);
}

static void child_phase(void)
{
    char cmdline[MAX_PATH + 16];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD code = 0;

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    snprintf(cmdline, sizeof(cmdline), "\"%s\" exit 7", exe_path);
    if (!CreateProcessA(exe_path, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
    {
        probe_log("child: CreateProcess error %lu\n", GetLastError());
        check("CreateProcess(self, exit 7)", 0);
        return;
    }
    check("child ends", WaitForSingleObject(pi.hProcess, 30000) == WAIT_OBJECT_0);
    GetExitCodeProcess(pi.hProcess, &code);
    probe_log("child: exit code %lu\n", code);
    check("child exit code 7", code == 7);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
}

#ifdef __aarch64__
/* The x18 phase (PLA-516). x18_run(op, sentinel, arm, out): with arm, sets TPIDR_EL0 bit 48 (the custom x18 ABI bit
 * xnu's exception return restores x18 for); sets x18 to sentinel; calls op; stores x18, then TPIDR_EL0 as read before
 * and after op; clears the bit again if it is still set; puts the entry x18 back. x18 is only ever read by a store
 * relative to SP, a form the runtime's x18 patcher leaves alone (madeira-unix 0263); a write of x18 is not patched.
 * x18_op_getpid and x18_op_switch enter the Darwin kernel straight from guest code (svc #0x80, x16 the call):
 * getpid (20) returns at once, thread_switch (Mach trap -61) with SWITCH_OPTION_WAIT (2) blocks for 50 ms, so the
 * thread is switched out and back in. x18_op_udf raises an illegal instruction at x18_udf_insn. */
struct x18_out
{
    unsigned long long x18, tpidr_before, tpidr_after;
};

void x18_run(void (*op)(void), unsigned long long sentinel, int arm, struct x18_out *out);
unsigned long long x18_read(void);
unsigned long long x18_tpidr(void);
void x18_op_none(void);
void x18_op_getpid(void);
void x18_op_switch(void);
void x18_op_udf(void);
extern const char x18_udf_insn[];

__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl x18_run\n"
    "x18_run:\n\t"
    "stp x29, x30, [sp, #-64]!\n\t"
    "mov x29, sp\n\t"
    "stp x19, x20, [sp, #16]\n\t"
    "str x18, [sp, #32]\n\t"
    "mov x19, x0\n\t"
    "mov x20, x3\n\t"
    "cbz w2, 1f\n\t"
    "mrs x9, tpidr_el0\n\t"
    "orr x9, x9, #0x1000000000000\n\t"
    "msr tpidr_el0, x9\n"
    "1:\n\t"
    "mrs x9, tpidr_el0\n\t"
    "str x9, [x20, #8]\n\t"
    "mov x18, x1\n\t"
    "blr x19\n\t"
    "str x18, [sp, #40]\n\t"
    "mrs x9, tpidr_el0\n\t"
    "ldr x10, [sp, #40]\n\t"
    "str x10, [x20]\n\t"
    "str x9, [x20, #16]\n\t"
    "tbz x9, #48, 2f\n\t"
    "and x9, x9, #0xfffeffffffffffff\n\t"
    "msr tpidr_el0, x9\n"
    "2:\n\t"
    "ldr x18, [sp, #32]\n\t"
    "ldp x19, x20, [sp, #16]\n\t"
    "ldp x29, x30, [sp], #64\n\t"
    "ret\n"
    ".p2align 2\n"
    ".globl x18_read\n"
    "x18_read:\n\t"
    "str x18, [sp, #-16]!\n\t"
    "ldr x0, [sp], #16\n\t"
    "ret\n"
    ".p2align 2\n"
    ".globl x18_tpidr\n"
    "x18_tpidr:\n\t"
    "mrs x0, tpidr_el0\n\t"
    "ret\n"
    ".p2align 2\n"
    ".globl x18_op_none\n"
    "x18_op_none:\n\t"
    "ret\n"
    ".p2align 2\n"
    ".globl x18_op_getpid\n"
    "x18_op_getpid:\n\t"
    "mov x16, #20\n\t"
    "svc #0x80\n\t"
    "ret\n"
    ".p2align 2\n"
    ".globl x18_op_switch\n"
    "x18_op_switch:\n\t"
    "mov x0, #0\n\t"
    "mov x1, #2\n\t"
    "mov x2, #50\n\t"
    "mov x16, #-61\n\t"
    "svc #0x80\n\t"
    "ret\n"
    ".p2align 2\n"
    ".globl x18_op_udf\n"
    ".globl x18_udf_insn\n"
    "x18_op_udf:\n\t"
    "nop\n"
    "x18_udf_insn:\n\t"
    "udf #0xdead\n\t"
    "ret\n");

#define X18_SENTINEL  0x7818a5a5c3c31818ull
#define X18_TPIDR_BIT (1ull << 48)

typedef LONG (WINAPI *nt_yield_fn)(void);
static nt_yield_fn x18_nt_yield;
static unsigned long long x18_udf_ctx_x18;
static int x18_udf_seen;

/* Steps over the UDF at x18_udf_insn and keeps the x18 its context reports. */
static LONG CALLBACK x18_udf_handler(EXCEPTION_POINTERS *ep)
{
    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION ||
        ep->ExceptionRecord->ExceptionAddress != (void *)x18_udf_insn)
        return EXCEPTION_CONTINUE_SEARCH;
    x18_udf_ctx_x18 = ep->ContextRecord->X18;
    x18_udf_seen++;
    ep->ContextRecord->Pc += 4;
    return EXCEPTION_CONTINUE_EXECUTION;
}

/* 20 ms on the generic timer, with no call: only interrupts (and preemption) reach the kernel. */
static void x18_op_spin(void)
{
    unsigned long long freq, start, now;

    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(start));
    if (!freq) freq = 24000000;
    do __asm__ volatile("mrs %0, cntvct_el0" : "=r"(now));
    while (now - start < freq / 50);
}

static void x18_op_yield(void) { x18_nt_yield(); }
static void x18_op_sleep0(void) { Sleep(0); }
static void x18_op_sleep50(void) { Sleep(50); }

static const char *x18_class(unsigned long long v, unsigned long long teb)
{
    return v == X18_SENTINEL ? "kept" : v == teb ? "TEB" : !v ? "zero" : "other";
}

enum { X18_NONE, X18_SPIN, X18_GETPID, X18_SWITCH, X18_YIELD, X18_SLEEP0, X18_SLEEP50, X18_UDF, X18_OPS };

static void x18_phase(void)
{
    static const struct { const char *name; void (*fn)(void); } ops[X18_OPS] = {
        { "none", x18_op_none }, { "spin", x18_op_spin }, { "getpid", x18_op_getpid }, { "switch", x18_op_switch },
        { "yield", x18_op_yield }, { "sleep0", x18_op_sleep0 }, { "sleep50", x18_op_sleep50 }, { "udf", x18_op_udf },
    };
    const unsigned long long teb = (ULONG_PTR)NtCurrentTeb(), x18 = x18_read(), tpidr = x18_tpidr();
    const char *got[2][X18_OPS];
    int bit_after[2][X18_OPS];
    char sum[2][512];
    const char *verdict;
    PVOID veh;
    int mode, i;

    x18_nt_yield = (nt_yield_fn)(void *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtYieldExecution");
    probe_log("x18: TEB %#llx; x18 at the phase start %#llx (%s); TPIDR_EL0 %#llx, custom x18 ABI bit %d\n", teb, x18,
              x18_class(x18, teb), tpidr, !!(tpidr & X18_TPIDR_BIT));
    veh = AddVectoredExceptionHandler(1, x18_udf_handler);
    for (mode = 0; mode < 2; mode++)
    {
        int n = 0;

        for (i = 0; i < X18_OPS; i++)
        {
            struct x18_out out;
            char extra[96] = "";

            if (i == X18_YIELD && !x18_nt_yield)
            {
                got[mode][i] = "n/a";
                bit_after[mode][i] = 0;
                n += snprintf(sum[mode] + n, sizeof(sum[mode]) - n, "%s%s=n/a", i ? " " : "", ops[i].name);
                continue;
            }
            x18_udf_seen = 0;
            x18_run(ops[i].fn, X18_SENTINEL, mode, &out);
            got[mode][i] = x18_class(out.x18, teb);
            bit_after[mode][i] = !!(out.tpidr_after & X18_TPIDR_BIT);
            if (i == X18_UDF && x18_udf_seen)
                snprintf(extra, sizeof(extra), "; the handler's context had x18 %#llx (%s)", x18_udf_ctx_x18,
                         x18_class(x18_udf_ctx_x18, teb));
            else if (i == X18_UDF)
                snprintf(extra, sizeof(extra), "; the handler was not called");
            probe_log("x18: %s %s: x18 %#llx (%s), bit 48 %d -> %d%s\n", mode ? "armed" : "plain", ops[i].name,
                      out.x18, got[mode][i], !!(out.tpidr_before & X18_TPIDR_BIT), bit_after[mode][i], extra);
            n += snprintf(sum[mode] + n, sizeof(sum[mode]) - n, "%s%s=%s%s", i ? " " : "", ops[i].name,
                          got[mode][i], mode && bit_after[mode][i] ? "+bit" : "");
        }
    }
    if (veh) RemoveVectoredExceptionHandler(veh);

    if (!strcmp(got[0][X18_GETPID], "kept"))
        verdict = "NOT-ZEROED (x18 kept across a kernel entry without the bit)";
    else if (strcmp(got[1][X18_GETPID], "kept"))
        verdict = "IGNORED (the bit does not keep x18 across a kernel entry)";
    else if (!strcmp(got[1][X18_SWITCH], "kept") && bit_after[1][X18_SWITCH])
        verdict = "PRESERVED (x18 and the bit survive a context switch)";
    else if (strcmp(got[1][X18_SWITCH], "kept"))
        verdict = "UNTIL-SWITCH (the bit keeps x18 across kernel entries; a context switch clears both)";
    else
        verdict = "MIXED";
    probe_log("x18-abi: %s; plain: %s; armed: %s\n", verdict, sum[0], sum[1]);
}
#else
static void x18_phase(void)
{
    probe_log("x18: skipped, not an aarch64 build\n");
}
#endif

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    char dir[MAX_PATH], path[MAX_PATH + 16], *slash;

    if (!strncmp(cmdline, "exit ", 5)) ExitProcess((UINT)strtoul(cmdline + 5, NULL, 0));

    GetModuleFileNameA(NULL, exe_path, sizeof(exe_path));
    strcpy(dir, exe_path);
    if ((slash = strrchr(dir, '\\'))) *slash = 0;
#ifdef PROBE_FAULT
    snprintf(path, sizeof(path), "%s\\arm64-fault.log", dir);
#else
    snprintf(path, sizeof(path), "%s\\arm64.log", dir);
#endif
    log_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    probe_log("start: %s\n", exe_path);

    machine_phase();
#ifdef PROBE_FAULT
    {
        int *volatile target = NULL;

        probe_log("fault: writing through a null pointer\n");
        if (log_file != INVALID_HANDLE_VALUE) FlushFileBuffers(log_file);
        *target = 1;
        check("the null write faults", 0);
    }
#endif
    load_phase();
    rwx_phase();
    thread_phase();
    child_phase();
    if (strstr(cmdline, "x18")) x18_phase();

    probe_log("done %s\n", failed ? "FAIL" : "ok");
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return failed ? 1 : 42;
}

#endif

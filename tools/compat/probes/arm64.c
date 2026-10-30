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
 *            anonymous executable path
 *   thread   a second thread runs and returns its exit code
 *   child    the program again as a child with `exit 7`: a native ARM64
 *            child of a native ARM64 child; its exit code must be 7
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

    probe_log("done %s\n", failed ? "FAIL" : "ok");
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return failed ? 1 : 42;
}

#endif

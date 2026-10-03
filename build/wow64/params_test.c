/* Test the production packer with mock Wine layouts and real window storage.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include "wow64_window.h"

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define PROCESS_PARAMS_FLAG_NORMALIZED 1
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 0xc000000du
#define STATUS_NOT_SUPPORTED 0xc00000bbu
#define STATUS_NO_MEMORY 0xc0000017u
#define HandleToULong(h) ((uint32_t)(uintptr_t)(h))
typedef uint32_t NTSTATUS;
typedef uint16_t WCHAR;
typedef struct { uint16_t Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { uint16_t Length, MaximumLength; uint32_t Buffer; } UNICODE_STRING32;
#define SCALARS \
    uint32_t AllocationSize, Size, Flags, DebugFlags, ConsoleFlags; \
    uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars; \
    uint32_t dwFillAttribute, dwFlags, wShowWindow, ProcessGroupId, LoaderThreads;
#define STRINGS(type) type DllPath, ImagePathName, CommandLine, WindowTitle, Desktop, ShellInfo, RuntimeInfo;
typedef struct {
    SCALARS
    void *ConsoleHandle, *hStdInput, *hStdOutput, *hStdError;
    struct { UNICODE_STRING DosPath; void *Handle; } CurrentDirectory;
    STRINGS(UNICODE_STRING)
    void *Environment;
    uintptr_t EnvironmentSize, EnvironmentVersion;
    void *PackageDependencyData;
    struct { uint16_t Flags, Length; uint32_t TimeStamp; UNICODE_STRING DosPath; } DLCurrentDirectory[32];
} RTL_USER_PROCESS_PARAMETERS;
typedef struct {
    SCALARS
    uint32_t ConsoleHandle, hStdInput, hStdOutput, hStdError;
    struct { UNICODE_STRING32 DosPath; uint32_t Handle; } CurrentDirectory;
    STRINGS(UNICODE_STRING32)
    uint32_t Environment, EnvironmentSize, EnvironmentVersion, PackageDependencyData;
    struct { uint16_t Flags, Length; uint32_t TimeStamp; UNICODE_STRING32 DosPath; } DLCurrentDirectory[32];
} RTL_USER_PROCESS_PARAMETERS32;
#include "wow64_params.h"

typedef struct { int64_t QuadPart; } LARGE_INTEGER;
#define PEB_SCALARS \
    uint32_t BeingDebugged, NumberOfProcessors, NtGlobalFlag; \
    LARGE_INTEGER CriticalSectionTimeout;
typedef struct {
    PEB_SCALARS
    uintptr_t HeapSegmentReserve, HeapSegmentCommit, HeapDeCommitTotalFreeThreshold, HeapDeCommitFreeBlockThreshold;
} PEB;
typedef struct {
    PEB_SCALARS
    uint32_t HeapSegmentReserve, HeapSegmentCommit, HeapDeCommitTotalFreeThreshold, HeapDeCommitFreeBlockThreshold;
    uint32_t ProcessParameters, ImageBaseAddress, LdrData, ProcessHeap;
} PEB32;
typedef struct { uint32_t Peb; } TEB32;
typedef struct { PEB *Peb; } TEB;
typedef int BOOL;
static TEB current;
static TEB32 pair;
static uintptr_t active_window;
static int alloc_fail, alloc_calls;
static TEB *NtCurrentTeb(void) { return &current; }
static void *get_wow_teb(TEB *teb) { assert(teb == &current); return &pair; }
static NTSTATUS ios_wow64_allocate_for_peb(void *owner, uint32_t guest, size_t size,
                                         unsigned int vprot, void **result)
{
    assert(owner == current.Peb && vprot == 0x23);
    assert(size <= IOS_WOW64_PARAMS_MAX);
    alloc_calls++;
    if (alloc_fail) return STATUS_NO_MEMORY;
    void *host = (void *)ios_wow64_host_addr(active_window, guest);
    assert(!mprotect(host, size, PROT_READ | PROT_WRITE));
    *result = host;
    return 0;
}
/* Suppress diagnostic output only; the extracted publication function is unchanged. */
#define dprintf(...) ((void)0)
#include "params_api.h"
#undef dprintf

static void *window(void)
{
    size_t total = IOS_WOW64_WINDOW_SIZE + 0x10000;
    void *raw = mmap(NULL, total, PROT_NONE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    assert(raw != MAP_FAILED);
    uintptr_t base = ((uintptr_t)raw + 0xffff) & ~(uintptr_t)0xffff;
    size_t prefix = base - (uintptr_t)raw, suffix = 0x10000 - prefix;
    if (prefix) assert(!munmap(raw, prefix));
    if (suffix) assert(!munmap((void *)(base + IOS_WOW64_WINDOW_SIZE), suffix));
    assert(ios_wow64_valid_base(base));
    return (void *)base;
}

static WCHAR env[] = {'A','=','1',0,'B','=','2',0,0};
static WCHAR text[] = {'a','b','c',0};
static unsigned char blob[] = {0xff, 0, 0x80};
static RTL_USER_PROCESS_PARAMETERS input(void)
{
    RTL_USER_PROCESS_PARAMETERS p = {0};
    p.Flags = PROCESS_PARAMS_FLAG_NORMALIZED | 0x400;
    p.DebugFlags = 7;
    p.ConsoleHandle = (void *)(intptr_t)-3;
    p.hStdInput = (void *)(uintptr_t)0x1234;
    p.hStdError = (void *)(intptr_t)-1;
    p.CurrentDirectory.Handle = (void *)(uintptr_t)0x4321;
#define INIT_STRING(field) p.field = (UNICODE_STRING){6, 16, text};
    IOS_WOW64_PARAM_STRINGS(INIT_STRING)
#undef INIT_STRING
    p.RuntimeInfo = (UNICODE_STRING){3, 3, (void *)blob};
    p.Environment = env;
    p.EnvironmentSize = sizeof(env);
    p.EnvironmentVersion = 3;
    p.ProcessGroupId = 42;
    p.dwX = 11;
    return p;
}

static void check(uintptr_t base, uint32_t guest, RTL_USER_PROCESS_PARAMETERS *src)
{
    RTL_USER_PROCESS_PARAMETERS32 *dst = (void *)ios_wow64_host_addr(base, guest);
    assert(dst->Flags == src->Flags && dst->dwX == 11 && dst->ProcessGroupId == 42);
    assert(dst->ConsoleHandle == 0xfffffffdu && dst->hStdError == UINT32_MAX);
    assert(dst->hStdInput == 0x1234 && dst->CurrentDirectory.Handle == 0x4321);
#define CHECK_STRING(field) do { \
    UNICODE_STRING32 *s = &dst->field; \
    assert(s->Length == src->field.Length && s->MaximumLength == src->field.MaximumLength); \
    const unsigned char *bytes = (void *)ios_wow64_host_addr(base, s->Buffer); \
    assert(!memcmp(bytes, src->field.Buffer, s->Length)); \
    for (unsigned i = s->Length; i < s->MaximumLength; i++) assert(bytes[i] == 0); \
    assert(s->Buffer >= guest + sizeof(*dst) && s->Buffer + s->MaximumLength <= guest + dst->Size); \
} while (0);
    IOS_WOW64_PARAM_STRINGS(CHECK_STRING)
#undef CHECK_STRING
    assert(!memcmp((void *)ios_wow64_host_addr(base, dst->Environment), env, sizeof(env)));
    assert(!(dst->Environment & 1) && dst->EnvironmentSize == sizeof(env));
    assert(dst->EnvironmentVersion == 3 && !dst->PackageDependencyData);
}

int main(void)
{
    uintptr_t a = (uintptr_t)window(), b = (uintptr_t)window();
    RTL_USER_PROCESS_PARAMETERS src = input(), bad;
    PEB owner = {.NumberOfProcessors = 6, .NtGlobalFlag = 0x123, .HeapSegmentReserve = 0x100000};
    current.Peb = &owner;
    pair.Peb = 0x7ff00000;
    active_window = a;
    PEB32 *p32 = (void *)ios_wow64_host_addr(a, pair.Peb);
    assert(!mprotect(p32, 0x4000, PROT_READ | PROT_WRITE));
    p32->ImageBaseAddress = 0x400000;
    size_t size = 99;
    uint32_t guest = 99;
    assert(ios_wow64_params_size(NULL, &size) == STATUS_INVALID_PARAMETER && size == 99);
    assert(ios_wow64_params_size(&src, NULL) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_pack_params(a, NULL, p32, 0x4000, &guest) == STATUS_INVALID_PARAMETER && guest == 99);
    assert(!ios_wow64_params_size(&src, &size));
    bad = src;
    bad.Flags = 0;
    assert(ios_wow64_init_parameters(&owner, a, &bad, 1) == STATUS_INVALID_PARAMETER);
    assert(!alloc_calls && !p32->ProcessParameters && p32->ImageBaseAddress == 0x400000);
    owner.HeapSegmentCommit = UINT64_C(0x100000000);
    assert(ios_wow64_init_parameters(&owner, a, &src, 1) == STATUS_INVALID_PARAMETER);
    assert(!alloc_calls && !p32->ProcessParameters);
    owner.HeapSegmentCommit = 0x10000;
    alloc_fail = 1;
    assert(ios_wow64_init_parameters(&owner, a, &src, 1) == STATUS_NO_MEMORY);
    assert(!p32->ProcessParameters);
    alloc_fail = 0;
    assert(!ios_wow64_init_parameters(&owner, a, &src, 1));
    assert(p32->ProcessParameters == IOS_WOW64_PARAMS_GUEST && p32->ImageBaseAddress == 0x400000);
    assert(p32->BeingDebugged == 1 && p32->NtGlobalFlag == 0x123 && p32->NumberOfProcessors == 6);
    assert(p32->HeapSegmentReserve == 0x100000 && !p32->LdrData && !p32->ProcessHeap);
    check(a, p32->ProcessParameters, &src);
    int calls = alloc_calls;
    assert(ios_wow64_init_parameters(&owner, a, &src, 0) == STATUS_INVALID_PARAMETER);
    PEB wrong = {0};
    assert(ios_wow64_init_parameters(&wrong, a, &src, 0) == STATUS_INVALID_PARAMETER);
    assert(alloc_calls == calls);

    void *host = (void *)ios_wow64_host_addr(b, IOS_WOW64_PARAMS_GUEST);
    assert(!mprotect(host, 0x4000, PROT_READ | PROT_WRITE));
    memset(host, 0xaa, 0x4000);
#define REJECT(change, code) do { \
    bad = src; change; size = 99; guest = 99; \
    assert(ios_wow64_params_size(&bad, &size) == code && size == 99); \
    assert(ios_wow64_pack_params(b, &bad, host, 0x4000, &guest) == code && guest == 99); \
    assert(*(unsigned char *)host == 0xaa); \
} while (0)
    REJECT(bad.Flags = 0, STATUS_INVALID_PARAMETER);
    REJECT(bad.CommandLine.Length = 17, STATUS_INVALID_PARAMETER);
    REJECT(bad.CommandLine.Length = 3, STATUS_INVALID_PARAMETER);
    REJECT(bad.CommandLine.MaximumLength = 15, STATUS_INVALID_PARAMETER);
    REJECT(bad.CommandLine.Buffer = NULL, STATUS_INVALID_PARAMETER);
    REJECT(bad.Environment = NULL, STATUS_INVALID_PARAMETER);
    REJECT(bad.EnvironmentSize = 3, STATUS_INVALID_PARAMETER);
    REJECT(bad.EnvironmentSize = IOS_WOW64_PARAMS_MAX, STATUS_INVALID_PARAMETER);
    REJECT(bad.EnvironmentSize = UINT64_MAX - 1, STATUS_INVALID_PARAMETER);
    REJECT(bad.PackageDependencyData = host, STATUS_NOT_SUPPORTED);
    REJECT(bad.EnvironmentVersion = UINT64_C(0x100000000), STATUS_NOT_SUPPORTED);
    REJECT(bad.DLCurrentDirectory[1].DosPath.Buffer = text, STATUS_NOT_SUPPORTED);
    WCHAR invalid_env[] = {'A',0,'B',0};
    REJECT(bad.Environment = invalid_env; bad.EnvironmentSize = sizeof(invalid_env), STATUS_INVALID_PARAMETER);
#undef REJECT
    guest = 99;
    assert(ios_wow64_pack_params(b, &src, host, 1, &guest) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_pack_params(a, &src, host, 0x4000, &guest) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_pack_params(b, &src, (void *)(b + 0xffffc000), 0x8000, &guest) == STATUS_INVALID_PARAMETER);
    assert(guest == 99 && *(unsigned char *)host == 0xaa);
    RTL_USER_PROCESS_PARAMETERS snapshot = src;
    assert(!ios_wow64_pack_params(b, &src, host, 0x4000, &guest));
    assert(!memcmp(&src, &snapshot, sizeof(src)));
    check(b, guest, &src);
    RTL_USER_PROCESS_PARAMETERS32 *one = (void *)ios_wow64_host_addr(a, guest), *two = host;
    assert(one->Environment == two->Environment && one->CommandLine.Buffer == two->CommandLine.Buffer);
    *(WCHAR *)ios_wow64_host_addr(b, two->CommandLine.Buffer) = 'z';
    assert(*(WCHAR *)ios_wow64_host_addr(a, one->CommandLine.Buffer) == 'a');
    /* Empty optional strings/empty environment keep NULL sentinel buffers.
     * Maximum allowed blocks and a top-of-window exact fit never wrap offsets. */
    bad = src;
    bad.DllPath = (UNICODE_STRING){0};
    bad.RuntimeInfo = (UNICODE_STRING){0};
    WCHAR empty[] = {0, 0};
    bad.Environment = empty;
    bad.EnvironmentSize = sizeof(empty);
    void *edge = (void *)(b + IOS_WOW64_WINDOW_SIZE - 0x4000);
    assert(!mprotect(edge, 0x4000, PROT_READ | PROT_WRITE));
    assert(!ios_wow64_pack_params(b, &bad, edge, 0x4000, &guest));
    RTL_USER_PROCESS_PARAMETERS32 *edge_params = edge;
    assert(guest == 0xffffc000 && !edge_params->DllPath.Buffer && !edge_params->RuntimeInfo.Buffer);
    assert(edge_params->Environment > guest && edge_params->EnvironmentSize == sizeof(empty));
    assert(!memcmp((void *)ios_wow64_host_addr(b, edge_params->Environment), empty, sizeof(empty)));
    size_t env_size = IOS_WOW64_PARAMS_MAX - sizeof(*edge_params);
    void *big_env = mmap(NULL, env_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(big_env != MAP_FAILED);
    bad = (RTL_USER_PROCESS_PARAMETERS){.Flags = PROCESS_PARAMS_FLAG_NORMALIZED,
                                       .Environment = big_env, .EnvironmentSize = env_size};
    assert(!ios_wow64_params_size(&bad, &size) && size == IOS_WOW64_PARAMS_MAX);
    assert(!mprotect(host, IOS_WOW64_PARAMS_MAX, PROT_READ | PROT_WRITE));
    assert(!ios_wow64_pack_params(b, &bad, host, IOS_WOW64_PARAMS_MAX, &guest));
    assert(two->Size == IOS_WOW64_PARAMS_MAX && two->AllocationSize == IOS_WOW64_PARAMS_MAX);
    bad.EnvironmentSize += sizeof(WCHAR);
    assert(ios_wow64_params_size(&bad, &size) == STATUS_INVALID_PARAMETER);
    assert(!munmap(big_env, env_size));
    /* Restore the independent block for the teardown-isolation check. */
    assert(!ios_wow64_pack_params(b, &src, host, 0x4000, &guest));
    *(WCHAR *)ios_wow64_host_addr(b, two->CommandLine.Buffer) = 'z';
    assert(!munmap((void *)a, IOS_WOW64_WINDOW_SIZE));
    assert(*(WCHAR *)ios_wow64_host_addr(b, two->CommandLine.Buffer) == 'z');
    assert(!munmap((void *)b, IOS_WOW64_WINDOW_SIZE));
    puts("WoW64 parameters: validation, packing, publication and disjoint storage passed");
    return 0;
}

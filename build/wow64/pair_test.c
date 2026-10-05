/* SPDX-License-Identifier: GPL-3.0-or-later
 * Production pairing/publication helpers with mock Wine types and view claims.
 * Real host mappings and pthread TLS; Wine/iOS layouts are checked by pp build.
 */
#define _GNU_SOURCE
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>

typedef uintptr_t ULONG_PTR;
typedef int NTSTATUS;
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_NOT_SUPPORTED 1
#define STATUS_NO_MEMORY 2
#define VPROT_READ 1
#define VPROT_WRITE 2
#define VPROT_COMMITTED 4
#define WOW64_TLS_CPURESERVED 3

typedef struct list { struct list *Flink, *Blink; } LIST_ENTRY;
#define PEB_SCALARS \
    unsigned BeingDebugged, NumberOfProcessors, NtGlobalFlag, OSMajorVersion, \
        OSMinorVersion, OSBuildNumber, OSPlatformId, ImageSubSystem, \
        ImageSubSystemMajorVersion, ImageSubSystemMinorVersion, SessionId

typedef struct { PEB_SCALARS; void *ImageBaseAddress, *ProcessParameters, *ProcessHeap, *LdrData; } PEB;
typedef struct { PEB_SCALARS; uint32_t ImageBaseAddress, ProcessParameters, ProcessHeap, LdrData; } PEB32;
typedef struct { unsigned SubSystemType, MajorSubsystemVersion, MinorSubsystemVersion; } SECTION_IMAGE_INFORMATION;
typedef struct
{
    struct { void *ExceptionList, *StackBase, *StackLimit, *FiberData, *Self; } Tib;
    PEB *Peb;
    struct { void *UniqueProcess, *UniqueThread; } ClientId, RealClientId;
    struct { LIST_ENTRY FrameListCache; } ActivationContextStack;
    void *ActivationContextStackPointer;
    uint16_t StaticUnicodeBuffer[32];
    struct { uint16_t *Buffer; unsigned MaximumLength; } StaticUnicodeString;
    int32_t WowTebOffset;
    void *ChpeV2CpuAreaInfo, *TlsSlots[8];
    struct { void *syscall_frame, *syscall_table; unsigned trace; } GdiTebBatch;
} TEB;
typedef struct
{
    struct { uint32_t ExceptionList, StackBase, StackLimit, FiberData, Self; } Tib;
    uint32_t Peb;
    struct { uint32_t UniqueProcess, UniqueThread; } ClientId, RealClientId;
    struct { struct { uint32_t Flink, Blink; } FrameListCache; } ActivationContextStack;
    uint32_t ActivationContextStackPointer;
    uint16_t StaticUnicodeBuffer[32];
    struct { uint32_t Buffer; unsigned MaximumLength; } StaticUnicodeString;
    uint32_t GdiBatchCount;
    int32_t WowTebOffset;
} TEB32;
#include "wow64_window.h"
#include "wow64_pair.h"

static struct
{
    void *owner;
    uintptr_t base;
    PEB32 *peb32;
    TEB *original_teb, *paired_teb;
} ios_wow64_windows[2];
struct thread_data { TEB *teb; unsigned long tid; void *entry; };
static _Thread_local struct thread_data *current_data;
static _Thread_local int fail_claim, fail_tls, claim_calls;
static SECTION_IMAGE_INFORMATION image = {2, 6, 0};
pthread_key_t ios_teb_tls_key;
static struct thread_data *get_thread_data(void) { return current_data; }
static void *get_syscall_frame(struct thread_data *data) { return data->teb->GdiTebBatch.syscall_frame; }
static TEB32 *get_wow_teb(TEB *teb) { return (TEB32 *)((char *)teb + teb->WowTebOffset); }
static const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void) { return &image; }
struct file_view { void *base; };
static _Thread_local struct file_view claimed;
static NTSTATUS ios_wow64_claim_view(uintptr_t base, uint32_t guest, size_t size,
                                     unsigned vprot, struct file_view **result)
{
    claim_calls++;
    assert(guest == IOS_WOW64_TEB_GUEST && size == IOS_WOW64_PAIR_SIZE);
    assert(vprot == (VPROT_READ | VPROT_WRITE | VPROT_COMMITTED));
    if (fail_claim) return STATUS_NO_MEMORY;
    claimed.base = (void *)(base + guest);
    assert(!mprotect(claimed.base, size, PROT_READ | PROT_WRITE));
    memset(claimed.base, 0, size);
    *result = &claimed;
    return STATUS_SUCCESS;
}
static int test_setspecific(pthread_key_t key, const void *value)
{
    if (fail_tls) return 1;
    return pthread_setspecific(key, value);
}
#define pthread_setspecific test_setspecific
#include "pair_api.h"
#undef pthread_setspecific

static void init_native(TEB *teb, PEB *peb, unsigned tid)
{
    memset(teb, 0, sizeof(*teb));
    teb->Peb = peb;
    teb->Tib.Self = &teb->Tib;
    teb->Tib.StackBase = (void *)(uintptr_t)0xfedc0000;
    teb->Tib.StackLimit = (void *)(uintptr_t)0xfedb0000;
    teb->Tib.ExceptionList = (void *)(uintptr_t)0x1234;
    teb->ClientId.UniqueProcess = (void *)(uintptr_t)42;
    teb->ClientId.UniqueThread = (void *)(uintptr_t)tid;
    teb->RealClientId = teb->ClientId;
    teb->ActivationContextStackPointer = &teb->ActivationContextStack;
    teb->ActivationContextStack.FrameListCache.Flink =
        teb->ActivationContextStack.FrameListCache.Blink = &teb->ActivationContextStack.FrameListCache;
    teb->StaticUnicodeString.Buffer = teb->StaticUnicodeBuffer;
    teb->StaticUnicodeString.MaximumLength = sizeof(teb->StaticUnicodeBuffer);
    teb->StaticUnicodeBuffer[0] = 0xabcd;
    teb->GdiTebBatch.syscall_frame = (void *)(uintptr_t)0x1234567890;
    teb->GdiTebBatch.syscall_table = (void *)(uintptr_t)0xabc1234560;
    teb->GdiTebBatch.trace = 1;
}

static void check_pair(unsigned slot, TEB *old)
{
    TEB *teb = current_data->teb;
    TEB32 *t32 = get_wow_teb(teb);
    uintptr_t base = ios_wow64_windows[slot].base;
    uint32_t guest = 0;
    assert(teb != old && ios_wow64_can_move_teb(old));
    assert(teb == ios_wow64_windows[slot].paired_teb);
    assert(ios_wow64_windows[slot].original_teb == old);
    assert(teb->Peb == old->Peb && teb->Tib.Self == &teb->Tib);
    assert(teb->Tib.ExceptionList == t32);
    assert(teb->WowTebOffset == -t32->WowTebOffset);
    assert((char *)t32 + t32->WowTebOffset == (char *)teb);
    assert(teb->ActivationContextStackPointer == &teb->ActivationContextStack);
    assert(teb->ActivationContextStack.FrameListCache.Flink == &teb->ActivationContextStack.FrameListCache);
    assert(teb->StaticUnicodeString.Buffer == teb->StaticUnicodeBuffer);
    assert(teb->StaticUnicodeBuffer[0] == 0xabcd);
    assert(!memcmp(&teb->GdiTebBatch, &old->GdiTebBatch, sizeof(teb->GdiTebBatch)));
    assert(teb->Tib.StackBase == old->Tib.StackBase && teb->Tib.StackLimit == old->Tib.StackLimit);
    assert(pthread_getspecific(ios_teb_tls_key) == teb);
    assert(ios_wow64_guest_addr(base, (uintptr_t)teb, &guest) && guest == t32->GdiBatchCount);
    assert(ios_wow64_guest_addr(base, (uintptr_t)t32, &guest) && guest == t32->Tib.Self);
    assert(ios_wow64_host_addr(base, t32->Peb) == (uintptr_t)ios_wow64_windows[slot].peb32);
    assert(ios_wow64_host_addr(base, t32->ActivationContextStackPointer) == (uintptr_t)&t32->ActivationContextStack);
    assert(ios_wow64_host_addr(base, t32->ActivationContextStack.FrameListCache.Flink) == (uintptr_t)&t32->ActivationContextStack.FrameListCache);
    assert(ios_wow64_host_addr(base, t32->StaticUnicodeString.Buffer) == (uintptr_t)t32->StaticUnicodeBuffer);
    assert(t32->ClientId.UniqueThread == current_data->tid && t32->ClientId.UniqueProcess == 42);
    assert(!memcmp(&t32->ClientId, &t32->RealClientId, sizeof(t32->ClientId)));
    assert(t32->Tib.ExceptionList == UINT32_MAX && t32->Tib.FiberData == 0x1e00);
    assert(!t32->Tib.StackBase && !t32->Tib.StackLimit);
    PEB32 *p32 = ios_wow64_windows[slot].peb32;
    assert(p32->OSMajorVersion == 10 && p32->NumberOfProcessors == 6);
    assert(p32->ImageSubSystem == 2 && p32->ImageSubSystemMajorVersion == 6);
    assert(!p32->ImageBaseAddress && !p32->ProcessParameters && !p32->ProcessHeap && !p32->LdrData);
}

static void *run_owner(void *arg)
{
    unsigned slot = (uintptr_t)arg;
    PEB *owner = ios_wow64_windows[slot].owner;
    TEB native;
    int list_sentinel;
    init_native(&native, owner, slot + 100);
    struct thread_data data = {&native, slot + 100, &list_sentinel};
    current_data = &data;
    assert(!pthread_setspecific(ios_teb_tls_key, &native));
    int calls = claim_calls;
    current_data = NULL;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NOT_SUPPORTED);
    current_data = &data;
    native.Peb = NULL;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NOT_SUPPORTED);
    native.Peb = owner;
    native.WowTebOffset = 0x2000;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NOT_SUPPORTED);
    native.WowTebOffset = 0;
    native.ChpeV2CpuAreaInfo = &native;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NOT_SUPPORTED);
    native.ChpeV2CpuAreaInfo = NULL;
    native.TlsSlots[WOW64_TLS_CPURESERVED] = &native;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NOT_SUPPORTED);
    native.TlsSlots[WOW64_TLS_CPURESERVED] = NULL;
    native.ActivationContextStack.FrameListCache.Flink = NULL;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NOT_SUPPORTED);
    native.ActivationContextStack.FrameListCache.Flink = &native.ActivationContextStack.FrameListCache;
    native.StaticUnicodeString.Buffer = NULL;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NOT_SUPPORTED);
    native.StaticUnicodeString.Buffer = native.StaticUnicodeBuffer;
    assert(claim_calls == calls);
    fail_claim = 1;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NO_MEMORY);
    fail_claim = 0;
    fail_tls = 1;
    assert(ios_wow64_pair_initial_teb(slot) == STATUS_NO_MEMORY);
    fail_tls = 0;
    assert(data.teb == &native && pthread_getspecific(ios_teb_tls_key) == &native);
    assert(!ios_wow64_windows[slot].paired_teb && !ios_wow64_windows[slot].original_teb);
    assert(!ios_wow64_pair_initial_teb(slot));
    check_pair(slot, &native);
    assert(data.entry == &list_sentinel);
    TEB *pair = data.teb;
    /* Wrong-thread release is refused without touching either publication. */
    data.teb = &native;
    assert(!ios_wow64_restore_initial_teb(slot));
    data.teb = pair;
    fail_tls = 1;
    assert(!ios_wow64_restore_initial_teb(slot));
    assert(data.teb == pair && pthread_getspecific(ios_teb_tls_key) == pair);
    fail_tls = 0;
    pair->GdiTebBatch.trace = 7;
    assert(ios_wow64_restore_initial_teb(slot));
    assert(data.teb == &native && pthread_getspecific(ios_teb_tls_key) == &native);
    assert(ios_wow64_can_move_teb(&native));
    assert(native.Tib.ExceptionList == (void *)(uintptr_t)0x1234);
    assert(native.GdiTebBatch.trace == 7 && data.entry == &list_sentinel);
    assert(!mprotect(pair, IOS_WOW64_PAIR_SIZE, PROT_NONE));
    assert(native.Peb == owner && native.StaticUnicodeBuffer[0] == 0xabcd);
    current_data = NULL;
    return NULL;
}

int main(void)
{
    PEB owners[2] = {0};
    pthread_t threads[2];
    assert(!pthread_key_create(&ios_teb_tls_key, NULL));
    for (unsigned i = 0; i < 2; i++)
    {
        owners[i].OSMajorVersion = 10;
        owners[i].NumberOfProcessors = 6;
        owners[i].ProcessHeap = &owners[i];  /* must never leak to PEB32 */
        size_t size = IOS_WOW64_WINDOW_SIZE + 0x10000;
        void *mapping = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        assert(mapping != MAP_FAILED);
        uintptr_t aligned = ((uintptr_t)mapping + 0xffff) & ~(uintptr_t)0xffff;
        size_t prefix = aligned - (uintptr_t)mapping;
        if (prefix) assert(!munmap(mapping, prefix));
        assert(!munmap((void *)(aligned + IOS_WOW64_WINDOW_SIZE), 0x10000 - prefix));
        void *base = (void *)aligned;
        ios_wow64_windows[i].owner = &owners[i];
        ios_wow64_windows[i].base = (uintptr_t)base;
        ios_wow64_windows[i].peb32 = (PEB32 *)((char *)base + IOS_WOW64_PEB_GUEST);
        assert(!mprotect(ios_wow64_windows[i].peb32, 0x4000, PROT_READ | PROT_WRITE));
    }
    assert(!pthread_create(&threads[0], NULL, run_owner, (void *)0));
    assert(!pthread_create(&threads[1], NULL, run_owner, (void *)1));
    for (unsigned i = 0; i < 2; i++)
    {
        assert(!pthread_join(threads[i], NULL));
        assert(!munmap((void *)ios_wow64_windows[i].base, IOS_WOW64_WINDOW_SIZE));
    }
    assert(!pthread_key_delete(ios_teb_tls_key));
    puts("wow64 initial TEB pair: passed (production helpers, mock Wine layouts/views, real TLS)");
    return 0;
}

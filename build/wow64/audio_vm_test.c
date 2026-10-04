/* SPDX-License-Identifier: GPL-3.0-or-later */
/* madeira-unix 0074's ios_wow64_audio_alloc/free (vm_api.h, from the patch)
 * against a mock window table and VM. */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
typedef int NTSTATUS;
#define STATUS_NOT_SUPPORTED ((NTSTATUS)0xc00000bb)
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xc000000d)
#define MEM_RESERVE 0x2000
#define MEM_COMMIT 0x1000
#define MEM_RELEASE 0x8000
#define PAGE_READWRITE 4
#define IOS_WOW64_WINDOWS_MAX 2
static struct { void *owner; uintptr_t base; int retiring; } ios_wow64_windows[2];
static pthread_mutex_t ios_wow64_windows_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t virtual_mutex = PTHREAD_MUTEX_INITIALIZER;
static int identity;
static void *current_owner = &identity;
static unsigned char backing[65536];
static int fail_allocate;
static unsigned freed;
static void *ios_jit_current_peb(void) { return current_owner; }
static void server_enter_uninterrupted_section(pthread_mutex_t *mutex, sigset_t *sigset)
{ (void)sigset; pthread_mutex_lock(mutex); }
static void server_leave_uninterrupted_section(pthread_mutex_t *mutex, sigset_t *sigset)
{ (void)sigset; pthread_mutex_unlock(mutex); }
static NTSTATUS ios_wow64_vm_allocate_limited(uintptr_t window, void **addr, size_t *size,
                                             unsigned type, unsigned protect, uintptr_t zero_bits, uint64_t end)
{
    assert(window == ios_wow64_windows[0].base && !*addr && *size == 128);
    assert(type == (MEM_RESERVE | MEM_COMMIT) && protect == PAGE_READWRITE && !zero_bits);
    assert(end == UINT64_C(0x80000000));
    if (fail_allocate) return STATUS_NOT_SUPPORTED;
    *addr = backing;
    return 0;
}
static NTSTATUS ios_wow64_vm_free(uintptr_t window, void **addr, size_t *size, unsigned type)
{
    assert(window == ios_wow64_windows[0].base && *addr == backing && !*size && type == MEM_RELEASE);
    freed++;
    return 0;
}
#include "vm_api.h"
int main(void)
{
    uintptr_t base = (uintptr_t)backing - 0x10000;
    ios_wow64_windows[0].owner = &identity; ios_wow64_windows[0].base = base;
    memset(backing, 0x7f, sizeof(backing));
    void *host = (void *)0xfeedbeef;
    assert(!ios_wow64_audio_alloc(&identity, base, 128, &host) && host == backing);
    assert(!memcmp(backing, (unsigned char[128]){0}, 128));
    assert(backing[128] == 0x7f);
    host = (void *)0xfeedbeef;
    fail_allocate = 1;
    assert(ios_wow64_audio_alloc(&identity, base, 128, &host) && host == (void *)0xfeedbeef);
    fail_allocate = 0;
    ios_wow64_windows[0].retiring = 1;
    assert(ios_wow64_audio_alloc(&identity, base, 128, &host) && host == (void *)0xfeedbeef);
    assert(ios_wow64_audio_free(&identity, base, backing) == 0 && freed == 1);
    assert(ios_wow64_audio_free(&identity, base + 0x100000000, backing) && freed == 1);
    int other;
    assert(ios_wow64_audio_free(&other, base, backing) && freed == 1);
    current_owner = &other;
    assert(ios_wow64_audio_alloc(&identity, base, 128, &host) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_audio_free(&identity, base, backing) == 0 && freed == 2);
    puts("WoW64 audio VM: explicit owner/window, allocation/zeroing/OOM/retirement, stored-owner release and foreign-owner rejection passed");
}

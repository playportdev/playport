/* SPDX-License-Identifier: GPL-3.0-or-later
 * Compile the shipped get_nsi_device helper with Win32 transport stubs.
 * Each case runs in a fresh process, like a fresh nsi.dll instance. */
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

typedef void *HANDLE;
typedef int BOOL;
typedef int32_t LONG;
typedef uint32_t DWORD;
#define TRUE 1
#define FALSE 0
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#define FILE_SHARE_READ 1
#define FILE_SHARE_WRITE 2
#define OPEN_EXISTING 3
#define FILE_FLAG_OVERLAPPED 0x40000000
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define ERROR_ACCESS_DENIED 5
#define ERROR_NOT_READY 21
#define ERROR_SUCCESS 0

static HANDLE nsi_device = INVALID_HANDLE_VALUE;
static HANDLE nsi_device_async = INVALID_HANDLE_VALUE;
static _Thread_local DWORD last_error;
static _Atomic unsigned opens, closes, fallback_checks;
static _Atomic int available, device_present;
static DWORD open_error = ERROR_FILE_NOT_FOUND;

static DWORD GetLastError(void) { return last_error; }
static void SetLastError(DWORD err) { last_error = err; }
static LONG InterlockedCompareExchange(LONG *ptr, LONG value, LONG expected)
{
    __atomic_compare_exchange_n(ptr, &expected, value, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return expected;
}
static HANDLE InterlockedCompareExchangePointer(HANDLE *ptr, HANDLE value, HANDLE expected)
{
    __atomic_compare_exchange_n(ptr, &expected, value, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return expected;
}
static BOOL nsi_unix_fallback(void)
{
    atomic_fetch_add(&fallback_checks, 1);
    SetLastError(1234); /* unixlib initialization may clobber the thread's error */
    return atomic_load(&available);
}
static HANDLE CreateFileW(const wchar_t *name, DWORD access, DWORD sharing, void *security,
                          DWORD disposition, DWORD flags, HANDLE template)
{
    assert(!wcscmp(name, L"\\\\.\\Nsi"));
    assert(!access && sharing == (FILE_SHARE_READ | FILE_SHARE_WRITE));
    assert(!security && disposition == OPEN_EXISTING && !template);
    atomic_fetch_add(&opens, 1);
    if (atomic_load(&device_present))
        return (HANDLE)(uintptr_t)(flags ? 0x200 : 0x100);
    SetLastError(open_error);
    return INVALID_HANDLE_VALUE;
}
static BOOL CloseHandle(HANDLE handle)
{
    assert(handle == (HANDLE)0x100 || handle == (HANDLE)0x200);
    atomic_fetch_add(&closes, 1);
    return TRUE;
}

#include "nsi_device.h"

static void *query_thread(void *unused)
{
    (void)unused;
    for (unsigned i = 0; i < 1000; ++i)
    {
        SetLastError(999);
        assert(get_nsi_device(FALSE) == INVALID_HANDLE_VALUE);
        assert(GetLastError() == open_error);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    atomic_store(&available, 1);
    if (!strcmp(argv[1], "missing") || !strcmp(argv[1], "path_missing"))
    {
        if (!strcmp(argv[1], "path_missing")) open_error = ERROR_PATH_NOT_FOUND;
        query_thread(NULL);
        printf("1000 fallback queries: %u device opens\n", atomic_load(&opens));
        fflush(stdout);
        assert(atomic_load(&opens) == 1);
        assert(atomic_load(&fallback_checks) == 1);
    }
    else if (!strcmp(argv[1], "no_fallback"))
    {
        atomic_store(&available, 0);
        query_thread(NULL);
        assert(atomic_load(&opens) == 1000);
        /* A desktop driver can appear after the earlier failed opens. */
        atomic_store(&device_present, 1);
        assert(get_nsi_device(FALSE) == (HANDLE)0x100);
        assert(atomic_load(&opens) == 1001);
        assert(get_nsi_device(FALSE) == (HANDLE)0x100);
        assert(atomic_load(&opens) == 1001);
    }
    else if (!strcmp(argv[1], "transient"))
    {
        open_error = ERROR_ACCESS_DENIED;
        query_thread(NULL);
        open_error = ERROR_NOT_READY;
        query_thread(NULL);
        assert(atomic_load(&opens) == 2000);
        assert(!atomic_load(&fallback_checks));
        atomic_store(&device_present, 1);
        assert(get_nsi_device(FALSE) == (HANDLE)0x100);
    }
    else if (!strcmp(argv[1], "modes"))
    {
        assert(get_nsi_device(FALSE) == INVALID_HANDLE_VALUE);
        assert(GetLastError() == ERROR_FILE_NOT_FOUND);
        open_error = ERROR_PATH_NOT_FOUND;
        assert(get_nsi_device(TRUE) == INVALID_HANDLE_VALUE);
        assert(GetLastError() == ERROR_PATH_NOT_FOUND);
        for (unsigned i = 0; i < 1000; ++i)
        {
            SetLastError(ERROR_SUCCESS);
            assert(get_nsi_device(FALSE) == INVALID_HANDLE_VALUE);
            assert(GetLastError() == ERROR_FILE_NOT_FOUND);
            SetLastError(ERROR_SUCCESS);
            assert(get_nsi_device(-1) == INVALID_HANDLE_VALUE);
            assert(GetLastError() == ERROR_PATH_NOT_FOUND);
        }
        assert(atomic_load(&opens) == 2);
    }
    else if (!strcmp(argv[1], "present"))
    {
        /* A real device still wins even when a fallback is available. */
        atomic_store(&device_present, 1);
        for (unsigned i = 0; i < 1000; ++i)
        {
            assert(get_nsi_device(FALSE) == (HANDLE)0x100);
            assert(get_nsi_device(TRUE) == (HANDLE)0x200);
        }
        assert(atomic_load(&opens) == 2);
        assert(!atomic_load(&fallback_checks));
    }
    else if (!strcmp(argv[1], "parallel"))
    {
        pthread_t threads[8];
        for (unsigned i = 0; i < 8; ++i) assert(!pthread_create(&threads[i], NULL, query_thread, NULL));
        for (unsigned i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
        /* Simultaneous first probes may race; subsequent queries cannot reprobe. */
        assert(atomic_load(&opens) >= 1 && atomic_load(&opens) <= 8);
        unsigned before = atomic_load(&opens);
        query_thread(NULL);
        assert(atomic_load(&opens) == before);
    }
    else assert(!"unknown case");
    return 0;
}

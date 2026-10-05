/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Compile wine-pe 0027's packed_createstruct_64to32 with wine-pe 0018's
 * createstruct_64to32 and window helpers, from the patched user.c. win32u's
 * pack_user_message leaves 0xffffffff for a name or class it copied after the
 * structure: that marker passes through, an atom stays an atom, a window
 * pointer converts, and a pointer outside the window is still rejected. */
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t ULONG;
typedef uint32_t DWORD;
typedef int32_t INT;
typedef int32_t LONG;
typedef int BOOL;
typedef uintptr_t ULONG_PTR;
typedef uint64_t ULONG64;
typedef uint16_t WCHAR;
typedef void *HANDLE;
typedef void *HINSTANCE;
typedef void *HMENU;
typedef void *HWND;
#define PtrToUlong(value) ((ULONG)(uintptr_t)(value))
#define ULongToPtr(value) ((void *)(uintptr_t)(value))
#define HandleToUlong(value) ((ULONG)(uintptr_t)(value))

typedef struct
{
    void *lpCreateParams;
    HINSTANCE hInstance;
    HMENU hMenu;
    HWND hwndParent;
    INT cy, cx, y, x;
    LONG style;
    const WCHAR *lpszName;
    const WCHAR *lpszClass;
    DWORD dwExStyle;
} CREATESTRUCTW;

static ULONG64 wow64_window_base;
static int rejected;
static ULONG wow64_guest_rejected(const void *host)
{
    (void)host;
    rejected++;
    return 0;
}

#include "wow64_window.h"
#include "packed_createstruct_api.h"

static CREATESTRUCTW host_create(const WCHAR *name, const WCHAR *class)
{
    CREATESTRUCTW cs = {0};

    cs.lpCreateParams = (void *)(uintptr_t)0x00402000;
    cs.hInstance = (void *)(uintptr_t)0x00400000;
    cs.hwndParent = (void *)(uintptr_t)0x10024;
    cs.cx = 1280;
    cs.cy = 720;
    cs.style = 0x10cf0000;
    cs.lpszName = name;
    cs.lpszClass = class;
    cs.dwExStyle = 0x100;
    return cs;
}

static void check(const WCHAR *name, const WCHAR *class, ULONG guest_name, ULONG guest_class)
{
    CREATESTRUCTW cs64 = host_create(name, class);
    CREATESTRUCT32 cs32;

    memset(&cs32, 0xcc, sizeof(cs32));
    packed_createstruct_64to32(&cs64, &cs32);
    assert(cs32.lpszName == guest_name);
    assert(cs32.lpszClass == guest_class);
    assert(cs32.lpCreateParams == 0x00402000 && cs32.hInstance == 0x00400000);
    assert(cs32.hwndParent == 0x10024 && cs32.cx == 1280 && cs32.cy == 720);
    assert(cs32.style == 0x10cf0000 && cs32.dwExStyle == 0x100);
}

int main(void)
{
    static WCHAR block[16];
    const ULONG guest = 0x00100000;
    const WCHAR *marker = (const WCHAR *)(uintptr_t)0xffffffff;
    CREATESTRUCTW cs64;
    CREATESTRUCT32 *cs32;
    _Alignas(16) unsigned char buffer[sizeof(CREATESTRUCTW)];

    wow64_window_base = (uintptr_t)block - guest;
    assert(wow64_window_base > UINT32_MAX);

    /* Both strings inline, as pack_user_message leaves them. */
    check(marker, marker, 0xffffffff, 0xffffffff);
    /* An inline name with an atom class, and an atom or empty name. */
    check(marker, (const WCHAR *)(uintptr_t)0xc01a, 0xffffffff, 0xc01a);
    check((const WCHAR *)(uintptr_t)0xc01a, marker, 0xc01a, 0xffffffff);
    check(NULL, NULL, 0, 0);
    assert(rejected == 0);
    /* A pointer into the window still converts. */
    check(block, block + 4, guest, guest + 8);
    assert(rejected == 0);
    /* A pointer outside the window is still rejected; the marker never is. */
    check((const WCHAR *)(uintptr_t)(wow64_window_base - 2), marker, 0, 0xffffffff);
    assert(rejected == 1);

    /* The conversion runs in place in the message buffer. */
    cs64 = host_create(marker, marker);
    memcpy(buffer, &cs64, sizeof(cs64));
    cs32 = (CREATESTRUCT32 *)buffer;
    packed_createstruct_64to32((const CREATESTRUCTW *)buffer, cs32);
    assert(cs32->lpszName == 0xffffffff && cs32->lpszClass == 0xffffffff);
    assert(cs32->cx == 1280 && cs32->dwExStyle == 0x100);
    assert(rejected == 1);
    puts("packed CREATESTRUCT: ok");
    return 0;
}

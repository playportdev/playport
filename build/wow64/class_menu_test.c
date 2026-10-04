/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Compile actual registration/lookup/unregister conversion statements from
 * wine-pe 0025/0022 and the window helpers from 0018/0016. Mock only win32u's
 * opaque storage and user32's packed W/A client-menu block. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint32_t ULONG;
typedef uint32_t UINT;
typedef uintptr_t ULONG_PTR;
typedef uint64_t ULONG64;
typedef int BOOL;
#define TRUE 1
#define ULongToPtr(value) ((void *)(uintptr_t)(value))
#define PtrToUlong(value) ((ULONG)(uintptr_t)(value))

static ULONG64 wow64_window_base;
static int rejected;
static ULONG wow64_guest_rejected(const void *host)
{
    (void)host;
    rejected++;
    return 0;
}
static inline ULONG get_ulong(UINT **args) { return *(*args)++; }
struct client_menu_name;

#include "wow64_window.h"
#include "class_menu_api.h"

static void check_resource(ULONG id)
{
    UINT args[] = {id, 0x55};
    UINT *next = args;
    void *stored = register_class_menu(&next);
    /* The extracted registration expression consumes one argument. */
    assert((uintptr_t)stored == id);
    assert(get_class_menu(stored) == id);
    assert(unregister_class_menu(stored) == id);
    assert(next == args + 1 && *next == 0x55);
}

int main(void)
{
    /* user32 allocates a Unicode string followed by its ANSI form. No nested
     * pointers are stored in client_menu_name, so the block is not widened. */
    static const uint16_t nameW[] = {'m', 'e', 'n', 'u', 0};
    static _Alignas(16) unsigned char block[32];
    const ULONG guest = 0x00100000;
    UINT args[] = {guest};
    UINT *next = args;
    void *stored;
    ULONG result;

    memcpy(block, nameW, sizeof(nameW));
    memcpy(block + sizeof(nameW), "menu", 5);
    wow64_window_base = (uintptr_t)block - guest;
    assert(wow64_window_base > UINT32_MAX);
    assert((ULONG)(uintptr_t)block != guest);
    stored = register_class_menu(&next);
    assert(stored == block);
    result = get_class_menu(stored);
    assert(result == guest && unregister_class_menu(stored) == guest);
    assert(memcmp(wow64_to_host(result), nameW, sizeof(nameW)) == 0);
    assert(strcmp((char *)wow64_to_host(result) + sizeof(nameW), "menu") == 0);
    check_resource(0);
    check_resource(1);
    check_resource(0xffff);
    /* 0x10000 is a pointer, not an integer resource. */
    args[0] = 0x10000;
    next = args;
    stored = register_class_menu(&next);
    assert((uintptr_t)stored == wow64_window_base + 0x10000);
    assert(get_class_menu(stored) == 0x10000);
    assert(rejected == 0);
    assert(get_class_menu((void *)(uintptr_t)(wow64_window_base - 1)) == 0);
    assert(rejected == 1);
    assert(get_class_menu((void *)(uintptr_t)(wow64_window_base + UINT64_C(0x100000000))) == 0);
    assert(rejected == 2);
    /* No window: named-menu addresses keep their identity; IDs stay IDs. */
    wow64_window_base = 0;
    args[0] = guest;
    next = args;
    assert((uintptr_t)register_class_menu(&next) == guest);
    assert(get_class_menu((void *)(uintptr_t)guest) == guest);
    check_resource(1);
    puts("class menu: named W/A block, integer IDs, NULL, boundary, inverse rejection, no window");
    return EXIT_SUCCESS;
}

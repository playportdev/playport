/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Compile wine-pe 0024's actual SendMessage return helper. The narrowing
 * converter is a stub: this checks restoration before conversion, not win32u
 * dispatch, callbacks, or structure packing. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t ULONG;
struct win_proc_params
{
    uintptr_t wparam, lparam;
    uint32_t msg, hwnd, ansi, ansi_dst, mapping, dpi_context;
};
struct win_proc_params32
{
    ULONG wparam, lparam;
    uint32_t msg, hwnd, ansi, ansi_dst, mapping, dpi_context;
};

static void win_proc_params_64to32(const struct win_proc_params *src, struct win_proc_params32 *dst)
{
    dst->wparam = src->wparam;
    dst->lparam = src->lparam;
    dst->msg = src->msg;
    dst->hwnd = src->hwnd;
    dst->ansi = src->ansi;
    dst->ansi_dst = src->ansi_dst;
    dst->mapping = src->mapping;
    dst->dpi_context = src->dpi_context;
}

#include "message_params_api.h"

static void check(uint32_t msg, uintptr_t host_wparam, uintptr_t host_lparam,
                  ULONG guest_wparam, ULONG guest_lparam)
{
    struct win_proc_params native = {host_wparam, host_lparam, msg, 0x10042, 1, 0, 4, 0x60000012};
    struct win_proc_params32 guest;

    send_message_params_64to32(&native, &guest, guest_wparam, guest_lparam);
    assert(guest.wparam == guest_wparam && guest.lparam == guest_lparam);
    assert(guest.msg == native.msg && guest.hwnd == native.hwnd);
    assert(guest.ansi == native.ansi && guest.ansi_dst == native.ansi_dst);
    assert(guest.mapping == native.mapping && guest.dpi_context == native.dpi_context);
    assert(native.wparam == host_wparam && native.lparam == host_lparam);
}

int main(void)
{
    const uintptr_t base = UINT64_C(0x7038010000);
    const ULONG buffer = 0x00100000, second = 0x00200000;
    unsigned char native_temporary[80];
    static const uint32_t temporary_messages[] = {
        0x0001, 0x0081, 0x0220, 0x0046, 0x0047, 0x0083, 0x0039,
        0x002d, 0x002c, 0x002b, 0x004a, 0x0053, 0x0087, 0x0213, 0x0164
    };

    /* WM_GETTEXT/SETTEXT: this is the exact reviewed base/truncation case. */
    assert((ULONG)(base + buffer) != buffer);
    check(0x000d, 128, base + buffer, 128, buffer);
    check(0x000c, 0, base + buffer, 0, buffer);
    /* EM_GETSEL, CB_GETEDITSEL, SBM_GETRANGE: both parameters are pointers. */
    check(0x00b0, base + buffer, base + second, buffer, second);
    check(0x0140, base + buffer, base + second, buffer, second);
    check(0x00e3, base + buffer, base + second, buffer, second);
    check(0x00b0, 0, 0, 0, 0);
    /* Widened structure lparams are native temporaries, NOT window pointers.
     * Returning the original guest address works without inverse conversion. */
    for (unsigned i = 0; i < sizeof(temporary_messages) / sizeof(temporary_messages[0]); ++i)
        check(temporary_messages[i], 1, (uintptr_t)native_temporary, 1, buffer);
    /* Values that happen to resemble addresses must keep their exact bits. */
    check(0x0401, UINT32_MAX, 0xdeadbeef, UINT32_MAX, 0xdeadbeef);
    /* Non-windowed dispatch also preserves parameters. */
    check(0x000d, 128, buffer, 128, buffer);
    puts("SendMessage return: window pointers, pointer wparam, NULL, native temporaries, scalar bits, metadata");
    return EXIT_SUCCESS;
}

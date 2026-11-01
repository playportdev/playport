/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * hio_focus.c — which guest window Winios gives the foreground back to when
 * the app returns to the foreground, or when input arrives while no guest
 * window is the foreground (patches/madeira-winios 0010).
 *
 * A focus loss deactivates the foreground window on its own thread, which
 * leaves Wine with no foreground window (fg 0) until something activates one
 * again; with fg 0 the server drops every key and Winios has no client area to
 * map a touch to. The window that lost focus is preferred; when it is gone,
 * hidden, disabled (behind a modal dialog) or minimized, the topmost window of
 * its process that can be activated, then the topmost of any process.
 * Plain C11 so tests/focus_test.c runs it on the Linux host.
 */

#include "host_io.h"

#define WS_POPUP         0x80000000u
#define WS_CHILD         0x40000000u
#define WS_MINIMIZE      0x20000000u
#define WS_VISIBLE       0x10000000u
#define WS_DISABLED      0x08000000u
#define WS_EX_NOACTIVATE 0x08000000u

static int can_activate(const host_focus_window *w)
{
    if (!w->hwnd || !(w->style & WS_VISIBLE)) return 0;
    if (w->style & (WS_DISABLED | WS_MINIMIZE)) return 0;
    if ((w->style & (WS_POPUP | WS_CHILD)) == WS_CHILD) return 0;
    return !(w->exstyle & WS_EX_NOACTIVATE);
}

int host_focus_pick(const host_focus_window *wins, int n, const void *saved, unsigned int saved_pid)
{
    int i;

    if (saved)
        for (i = 0; i < n; i++)
            if (wins[i].hwnd == saved && can_activate(&wins[i])) return i;
    if (saved_pid)
        for (i = 0; i < n; i++)
            if (wins[i].pid == saved_pid && can_activate(&wins[i])) return i;
    for (i = 0; i < n; i++)
        if (can_activate(&wins[i])) return i;
    return -1;
}

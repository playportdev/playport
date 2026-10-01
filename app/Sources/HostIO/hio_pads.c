/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * hio_pads.c — the app's controller writers (host_io.h) over Madeira's
 * in-process controller snapshot (Winios/WiniosGamepad.c). Wine's own
 * xinput1_*.dll reads that snapshot through win32u (ios_gamepad_query in
 * libwin32u_unix.a). Plain C11 so tests/pads_test.c can run it on the Linux
 * host against the same WiniosGamepad.c.
 */

#include "host_io.h"
#include "WiniosGamepad.h"

#include <pthread.h>

/* Two host threads write: the main thread (GameController, the dev build's
 * virtual pad) and Winios's drain, which releases held buttons once a focus
 * loss has reached the game. The snapshot locks each call; this lock makes
 * release_all's read and write one step against a concurrent set. */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

_Static_assert(HIO_PAD_SLOTS == WINIOS_GAMEPAD_MAX, "one slot per XInput user");

static void put(int slot, const hio_pad_state *st)
{
    struct winios_gamepad g = {0};
    g.buttons = st->buttons;
    g.left_trigger = st->left_trigger;
    g.right_trigger = st->right_trigger;
    g.lx = st->thumb_lx;
    g.ly = st->thumb_ly;
    g.rx = st->thumb_rx;
    g.ry = st->thumb_ry;
    g.connected = 1;
    winios_gamepad_set_state(slot, &g);   /* advances the packet only on a change */
}

void host_pad_set(int slot, const hio_pad_state *st)
{
    if (slot < 0 || slot >= HIO_PAD_SLOTS || !st) return;
    pthread_mutex_lock(&g_lock);
    put(slot, st);
    pthread_mutex_unlock(&g_lock);
}

void host_pad_disconnect(int slot)
{
    if (slot < 0 || slot >= HIO_PAD_SLOTS) return;
    pthread_mutex_lock(&g_lock);
    winios_gamepad_set_state(slot, NULL);
    pthread_mutex_unlock(&g_lock);
}

int host_pads_release_all(void)
{
    static const hio_pad_state rest;
    struct winios_gamepad g;
    int i, n = 0;
    pthread_mutex_lock(&g_lock);
    for (i = 0; i < HIO_PAD_SLOTS; i++) {
        if (!winios_gamepad_get_state(i, &g)) continue;
        if (!g.buttons && !g.left_trigger && !g.right_trigger && !g.lx && !g.ly && !g.rx && !g.ry) continue;
        put(i, &rest);
        n++;
    }
    pthread_mutex_unlock(&g_lock);
    return n;
}

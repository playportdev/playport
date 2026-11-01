/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * hio_pads.c — the app's controller writers (host_io.h) over Madeira's
 * in-process controller snapshot (Winios/WiniosGamepad.c). Wine's own
 * xinput1_*.dll reads that snapshot through win32u (ios_gamepad_query in
 * libwin32u_unix.a), which also reports each of the game's requests here
 * (playport_gamepad_query). Plain C11 so tests/pads_test.c can run it on
 * the Linux host against the same WiniosGamepad.c.
 */

#include "host_io.h"
#include "WiniosGamepad.h"

#include <pthread.h>
#include <stdio.h>

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

/* Game threads report (win32u's ios_gamepad_query); the main thread reads.
 * Relaxed atomics: each counter on its own is what the summary needs. */
static uint64_t g_state_reads;
static struct {
    uint64_t reads, caps, packet_changes;
    uint64_t slot_reads[HIO_PAD_SLOTS];   /* answered from a connected slot */
    uint32_t buttons;                     /* OR of the buttons answered */
    uint32_t last;                        /* 1 + slot of the last state request, 0x100 if empty */
} g_window;
static uint32_t g_last_packet[HIO_PAD_SLOTS];

void playport_gamepad_query(unsigned int index, unsigned int op, int connected, uint32_t packet,
                            uint16_t buttons)
{
    if (index >= HIO_PAD_SLOTS) return;
    if (op != 0) {
        __atomic_fetch_add(&g_window.caps, 1, __ATOMIC_RELAXED);
        return;
    }
    __atomic_fetch_add(&g_state_reads, 1, __ATOMIC_RELAXED);
    __atomic_fetch_add(&g_window.reads, 1, __ATOMIC_RELAXED);
    __atomic_store_n(&g_window.last, (1 + index) | (connected ? 0 : 0x100), __ATOMIC_RELAXED);
    if (!connected) return;
    __atomic_fetch_add(&g_window.slot_reads[index], 1, __ATOMIC_RELAXED);
    __atomic_fetch_or(&g_window.buttons, buttons, __ATOMIC_RELAXED);
    if (__atomic_exchange_n(&g_last_packet[index], packet, __ATOMIC_RELAXED) != packet)
        __atomic_fetch_add(&g_window.packet_changes, 1, __ATOMIC_RELAXED);
}

uint64_t host_pad_state_reads(void)
{
    return __atomic_load_n(&g_state_reads, __ATOMIC_RELAXED);
}

#define TAKE(x) __atomic_exchange_n(&(x), 0, __ATOMIC_RELAXED)

int host_pad_xinput_summary(char *buf, unsigned int size)
{
    uint64_t reads, caps, changes, slots[HIO_PAD_SLOTS];
    uint32_t buttons, last;
    int i, n;

    if (!buf || !size || !(reads = TAKE(g_window.reads))) return 0;
    caps = TAKE(g_window.caps);
    changes = TAKE(g_window.packet_changes);
    buttons = TAKE(g_window.buttons);
    for (i = 0; i < HIO_PAD_SLOTS; i++) slots[i] = TAKE(g_window.slot_reads[i]);
    last = __atomic_load_n(&g_window.last, __ATOMIC_RELAXED);
    n = snprintf(buf, size,
                 "%llu state reads (from a pad: slot 0 %llu, 1 %llu, 2 %llu, 3 %llu), last slot %u %s, "
                 "%llu packet changes, buttons seen 0x%04x, %llu capability requests",
                 (unsigned long long)reads, (unsigned long long)slots[0], (unsigned long long)slots[1],
                 (unsigned long long)slots[2], (unsigned long long)slots[3], (last & 0xff) - 1,
                 last & 0x100 ? "ERROR_DEVICE_NOT_CONNECTED" : "ERROR_SUCCESS",
                 (unsigned long long)changes, buttons, (unsigned long long)caps);
    return n < 0 ? 0 : n >= (int)size ? (int)size - 1 : n;
}

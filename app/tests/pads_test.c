/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * pads_test.c — hio_pads.c on the Linux host (pp test), against Madeira's
 * WiniosGamepad.c at the pin: what Wine's XInput reads back (through
 * winios_gamepad_get_state, the call libwin32u_unix.a makes) after each
 * writer, and a writer thread racing a reader. Host only: on the device the
 * reader is win32u's ios_gamepad_query, which this cannot stand in for.
 */
#include "host_io.h"
#include "WiniosGamepad.h"

#include <pthread.h>
#include <stdio.h>
#include <time.h>

static int failures;
static int stop;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static void *writer(void *arg)
{
    int i = 0;
    (void)arg;
    while (!__atomic_load_n(&stop, __ATOMIC_RELAXED)) {
        int k = 1 + i++ % 30000;
        hio_pad_state st = {(uint16_t)k, (uint8_t)k, (uint8_t)(k >> 8), (int16_t)k, (int16_t)-k, (int16_t)(k / 2), (int16_t)(-k / 2)};
        host_pad_set(2, &st);
    }
    return NULL;
}

int main(void)
{
    const hio_pad_state a = {0x1000, 200, 7, 1234, -1234, 5, 32767}, rest = {0};
    struct winios_gamepad g;
    uint32_t pk;
    long reads = 0, torn = 0;
    pthread_t t;
    time_t end;

    /* Nothing written: every slot reads as disconnected, all zero. */
    CHECK(!winios_gamepad_get_state(0, &g) && g.buttons == 0 && g.packet == 0);

    /* A set arrives value for value, connected. */
    host_pad_set(0, &a);
    CHECK(winios_gamepad_get_state(0, &g));
    CHECK(g.connected == 1 && g.buttons == 0x1000 && g.left_trigger == 200 && g.right_trigger == 7);
    CHECK(g.lx == 1234 && g.ly == -1234 && g.rx == 5 && g.ry == 32767);
    pk = g.packet;
    CHECK(pk != 0);

    /* The same state again is not a new packet; a change is. */
    host_pad_set(0, &a);
    CHECK(winios_gamepad_get_state(0, &g) && g.packet == pk);
    host_pad_set(0, &rest);
    CHECK(winios_gamepad_get_state(0, &g) && g.packet == pk + 1 && g.buttons == 0);

    /* Out-of-range slots are ignored. */
    host_pad_set(-1, &a);
    host_pad_set(HIO_PAD_SLOTS, &a);
    host_pad_disconnect(HIO_PAD_SLOTS);

    /* release_all rests the slots that hold anything, keeps them connected,
     * and counts them; a second call has nothing to release. */
    host_pad_set(0, &a);
    host_pad_set(1, &rest);
    host_pad_set(3, &a);
    CHECK(host_pads_release_all() == 2);
    CHECK(winios_gamepad_get_state(0, &g) && g.buttons == 0 && g.lx == 0 && g.ry == 0);
    CHECK(winios_gamepad_get_state(3, &g) && g.buttons == 0);
    CHECK(winios_gamepad_get_state(1, &g));
    CHECK(host_pads_release_all() == 0);

    /* A disconnect reads as no pad, all zero; release_all skips it. */
    host_pad_set(3, &a);
    host_pad_disconnect(3);
    CHECK(!winios_gamepad_get_state(3, &g) && g.buttons == 0 && g.connected == 0);
    CHECK(host_pads_release_all() == 0);

    /* A writer racing a reader: every read is one whole state (the writer
     * derives every field from one k). */
    pthread_create(&t, NULL, writer, NULL);
    end = time(NULL) + 1;
    while (time(NULL) <= end) {
        if (!winios_gamepad_get_state(2, &g)) continue;
        reads++;
        if (g.lx != (int16_t)g.buttons || g.ly != (int16_t)-g.lx || g.left_trigger != (uint8_t)g.buttons ||
            g.rx != (int16_t)(g.lx / 2))
            torn++;
    }
    __atomic_store_n(&stop, 1, __ATOMIC_RELAXED);
    pthread_join(t, NULL);
    CHECK(reads > 0);
    CHECK(torn == 0);

    printf("%s: %ld reads, %ld torn\n", failures ? "FAILED" : "ok", reads, torn);
    return failures != 0;
}

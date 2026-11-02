/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * pads_test.c — hio_pads.c on the Linux host (pp test), against Madeira's
 * WiniosGamepad.c at the pin: what Wine's XInput reads back (through
 * winios_gamepad_get_state, the call libwin32u_unix.a makes) after each
 * writer, a writer thread racing a reader, the count of the game's state
 * reads and the dev log's summary of them. Host only: on the device the
 * reader is win32u's ios_gamepad_query, which this cannot stand in for (it
 * calls the reporting hook, madeira-unix 0247 and 0273).
 */
#include "host_io.h"
#include "WiniosGamepad.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>
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

#define STATE_READS 100000

/* A game thread asking for XInput state of an empty slot. */
static void *state_reader(void *arg)
{
    int i;
    (void)arg;
    for (i = 0; i < STATE_READS; i++) playport_gamepad_query(1, 0, 0, 0, 0);
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

    /* The game's XInput requests (win32u's ios_gamepad_query, patches/madeira-unix 0247 and
     * 0273, calls the hook): none yet, as the app's own snapshot reads above (release_all) and
     * writes are not the game's; each state request is one, from any thread; capability
     * requests are not. No request, no summary. */
    {
        char line[512];
        CHECK(host_pad_state_reads() == 0);
        CHECK(host_pad_xinput_summary(line, sizeof line) == 0);
        playport_gamepad_query(0, 1, 1, 0, 0);
        CHECK(host_pad_state_reads() == 0);
        CHECK(host_pad_xinput_summary(line, sizeof line) == 0);
        playport_gamepad_query(0, 0, 1, 5, 0x1000);
        playport_gamepad_query(0, 0, 1, 5, 0x1000);
        playport_gamepad_query(0, 0, 1, 6, 0x0001);
        playport_gamepad_query(4, 0, 1, 7, 0x8000);   /* out of range: not counted */
        playport_gamepad_query(2, 0, 0, 0, 0);
        CHECK(host_pad_state_reads() == 4);
        CHECK(host_pad_xinput_summary(line, sizeof line) > 0);
        CHECK(!strcmp(line, "4 state reads (from a pad: slot 0 3, 1 0, 2 0, 3 0), last slot 2 "
                            "ERROR_DEVICE_NOT_CONNECTED, 2 packet changes, buttons seen 0x1001, "
                            "1 capability requests"));
        /* The summary takes its window: nothing new, nothing to say; the total stays.
         * The same packet as the slot's last answer is no change. */
        CHECK(host_pad_xinput_summary(line, sizeof line) == 0);
        playport_gamepad_query(0, 0, 1, 6, 0);
        CHECK(host_pad_xinput_summary(line, sizeof line) > 0);
        CHECK(!strcmp(line, "1 state reads (from a pad: slot 0 1, 1 0, 2 0, 3 0), last slot 0 "
                            "ERROR_SUCCESS, 0 packet changes, buttons seen 0x0000, "
                            "0 capability requests"));
        /* A short buffer holds what fits. */
        playport_gamepad_query(0, 0, 1, 6, 0);
        CHECK(host_pad_xinput_summary(line, 8) == 7 && !strcmp(line, "1 state"));
        CHECK(host_pad_state_reads() == 6);
    }
    {
        char line[512];
        pthread_t r[2];
        pthread_create(&r[0], NULL, state_reader, NULL);
        pthread_create(&r[1], NULL, state_reader, NULL);
        pthread_join(r[0], NULL);
        pthread_join(r[1], NULL);
        CHECK(host_pad_xinput_summary(line, sizeof line) > 0);
        CHECK(!strncmp(line, "200000 state reads (from a pad: slot 0 0,", 41));
    }
    CHECK(host_pad_state_reads() == 6 + 2 * STATE_READS);
    host_pads_release_all();
    CHECK(host_pad_state_reads() == 6 + 2 * STATE_READS);

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

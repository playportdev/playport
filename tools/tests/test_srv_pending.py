# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0175's pp_srv_pending.h (PLA-364): the wineserver reads only the request fds
of threads that marked themselves, every wake a mark needs is signalled once, and a full sweep catches a missed mark.

The stress test runs a server loop shaped like fd_ios.c's main_loop (rearm, timed semaphore wait, drain, read the
marked pipes, a full sweep at a low rate) against many client threads doing synchronous request/reply round trips
over pipes."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0175-wineserver-read-only-the-request-fds-of-threads-that.patch"
HEADER = "build/wineserver/pp_srv_pending.h"

TEST_C = r'''
#include "pp_srv_pending.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static uint32_t seen[64];
static int nseen;
static void collect(uint32_t tid, void *ctx) { (void)ctx; assert(nseen < 64); seen[nseen++] = tid; }

static void unit(void)
{
    static struct ppsp_set s;

    /* Nothing marked: nothing pending, nothing drained. */
    assert(!ppsp_rearm(&s));
    assert(!ppsp_drain(&s, collect, NULL) && nseen == 0);

    /* The first mark after a rearm signals; later ones are coalesced until the next rearm. */
    assert(ppsp_mark(&s, 0x418));
    assert(!ppsp_mark(&s, 0x41c));
    assert(!ppsp_mark(&s, 0x418));                /* twice is once */
    assert(!ppsp_mark(&s, PPSP_MAX_TID));
    assert(ppsp_pending(&s));
    assert(ppsp_rearm(&s));                       /* marks waiting: the server does not sleep */
    assert(ppsp_mark(&s, 0x20));                  /* re-armed: the next mark signals again */
    assert(!ppsp_drain(&s, collect, NULL));
    assert(nseen == 4 && seen[0] == 0x20 && seen[1] == 0x418 && seen[2] == 0x41c && seen[3] == PPSP_MAX_TID);
    assert(!ppsp_pending(&s));
    nseen = 0;
    assert(!ppsp_drain(&s, collect, NULL) && nseen == 0);

    /* An id the set cannot hold asks for one full sweep. */
    assert(!ppsp_rearm(&s));
    assert(ppsp_mark(&s, 0));                     /* before init_first_thread's reply */
    assert(!ppsp_mark(&s, PPSP_MAX_TID + 4));
    assert(!ppsp_mark(&s, 0x41a));                /* not a ptid */
    assert(ppsp_pending(&s));
    assert(ppsp_drain(&s, collect, NULL) && nseen == 0);
    assert(!ppsp_pending(&s) && !ppsp_drain(&s, collect, NULL));

    /* A quiet mark (the server re-marking a partial request) is pending but does not take the wake. */
    assert(!ppsp_rearm(&s));
    ppsp_mark_quiet(&s, 0x500);
    assert(ppsp_pending(&s));
    assert(ppsp_mark(&s, 0x504));                 /* still armed: a client's mark signals */
    assert(!ppsp_drain(&s, collect, NULL) && nseen == 2 && seen[0] == 0x500 && seen[1] == 0x504);
    nseen = 0;
}

/* Concurrent marks and drains: every mark made before a drain is seen by it or a later one. */
#define MARKERS 16
#define MARK_ROUNDS 50000
static struct ppsp_set cs;
static volatile uint32_t taken[PPSP_SLOTS];
static volatile int markers_done;

static void count(uint32_t tid, void *ctx) { (void)ctx; __atomic_fetch_add(&taken[tid >> 2], 1, __ATOMIC_RELAXED); }

static void *marker(void *arg)
{
    uint32_t tid = (uint32_t)(uintptr_t)arg;
    for (unsigned r = 0; r < MARK_ROUNDS; r++) {
        uint32_t before = __atomic_load_n(&taken[tid >> 2], __ATOMIC_RELAXED);
        ppsp_mark(&cs, tid);
        /* wait for a drain to take it: a lost mark hangs here, and the test times out */
        while (__atomic_load_n(&taken[tid >> 2], __ATOMIC_RELAXED) == before) ;
    }
    __atomic_fetch_add(&markers_done, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

static void concurrent(void)
{
    pthread_t t[MARKERS];
    for (unsigned k = 0; k < MARKERS; k++)   /* spread over words and summary words */
        assert(!pthread_create(&t[k], NULL, marker, (void *)(uintptr_t)(4 + k * 4093 * 4 % (PPSP_MAX_TID - 4))));
    while (__atomic_load_n(&markers_done, __ATOMIC_SEQ_CST) < MARKERS) {
        ppsp_rearm(&cs);
        assert(!ppsp_drain(&cs, count, NULL));
    }
    for (unsigned k = 0; k < MARKERS; k++) pthread_join(t[k], NULL);
}

/* The loop: N client threads, each with a request pipe and a reply pipe, R synchronous round trips each. */
static int nclients, rounds, full_sweep_ms, miss_every, legacy, think_us;
struct client { int req[2], rep[2]; uint32_t tid; unsigned served; };
static struct client *cl;
static struct ppsp_set ss;
static sem_t wake;
static volatile int clients_done;
static unsigned long long signals, rearms, timeouts_waiting, reads, failed_reads, full_sweeps, found_by_sweep;

static void *client(void *arg)
{
    struct client *c = arg;
    for (int r = 0; r < rounds; r++) {
        char b = (char)r, a;
        assert(write(c->req[1], &b, 1) == 1);
        /* the client's side of server_call_unlocked: mark, then signal if first since the rearm */
        if (legacy) { __atomic_fetch_add(&signals, 1, __ATOMIC_RELAXED); sem_post(&wake); }
        else if (!(miss_every && r % miss_every == miss_every - 1)) {
            if (ppsp_mark(&ss, c->tid)) { __atomic_fetch_add(&signals, 1, __ATOMIC_RELAXED); sem_post(&wake); }
        }
        assert(read(c->rep[0], &a, 1) == 1 && a == b);
        if (think_us) usleep((unsigned)((c->tid * 2654435761u + (unsigned)r * 40503u) % (unsigned)think_us));
    }
    __atomic_fetch_add(&clients_done, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

static void serve(struct client *c, int from_sweep)
{
    char b;
    ssize_t n = read(c->req[0], &b, 1);
    if (n == 1) {
        reads++;
        if (from_sweep) found_by_sweep++;
        c->served++;
        assert(write(c->rep[1], &b, 1) == 1);
    } else {
        assert(n < 0 && errno == EAGAIN);
        failed_reads++;
    }
}

static void dispatch(uint32_t tid, void *ctx) { (void)ctx; serve(&cl[(tid >> 2) - 1], 0); }

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int loop(int clients, int r, int sweep_ms, int miss, int old, int think)
{
    pthread_t *t;
    double last_full = now_ms(), start = now_ms();
    unsigned long long total = (unsigned long long)clients * r;

    nclients = clients; rounds = r; full_sweep_ms = sweep_ms; miss_every = miss; legacy = old; think_us = think;
    memset(&ss, 0, sizeof ss);
    clients_done = 0; signals = rearms = timeouts_waiting = reads = failed_reads = full_sweeps = found_by_sweep = 0;
    assert(!sem_init(&wake, 0, 0));
    cl = calloc(clients, sizeof *cl);
    t = calloc(clients, sizeof *t);
    for (int k = 0; k < clients; k++) {
        assert(!pipe(cl[k].req) && !pipe(cl[k].rep));
        fcntl(cl[k].req[0], F_SETFL, O_NONBLOCK);
        cl[k].tid = (uint32_t)(k + 1) * 4;
    }
    for (int k = 0; k < clients; k++) assert(!pthread_create(&t[k], NULL, client, &cl[k]));

    while (legacy && reads < total) {
        /* the loop before 0175: a 1 ms wait that the per-request signal ends, then a read of every client pipe */
        struct timespec dl;
        clock_gettime(CLOCK_REALTIME, &dl);
        dl.tv_nsec += 1000000;
        if (dl.tv_nsec >= 1000000000) { dl.tv_sec++; dl.tv_nsec -= 1000000000; }
        rearms++;
        sem_timedwait(&wake, &dl);
        full_sweeps++;
        for (int k = 0; k < clients; k++) serve(&cl[k], 1);
    }
    while (reads < total) {
        int full;
        /* main_loop: rearm, then sleep only if nothing is marked. With no full sweep a 1 s wait stands for the
         * 1 ms tick, so that a lost wake shows as a timeout while a client is still waiting; with one, the wait
         * ends by the next sweep, as the tick does. */
        rearms++;
        if (!ppsp_rearm(&ss)) {
            struct timespec dl;
            long long ns;
            clock_gettime(CLOCK_REALTIME, &dl);
            ns = dl.tv_nsec + (sweep_ms ? sweep_ms * 1000000ll : 1000000000ll);
            dl.tv_sec += ns / 1000000000ll;
            dl.tv_nsec = ns % 1000000000ll;
            if (sem_timedwait(&wake, &dl) && errno == ETIMEDOUT && !sweep_ms && reads < total) timeouts_waiting++;
        }
        full = ppsp_drain(&ss, dispatch, NULL);
        if (sweep_ms && now_ms() - last_full >= sweep_ms) full = 1;
        if (full) {
            last_full = now_ms();
            full_sweeps++;
            for (int k = 0; k < clients; k++) serve(&cl[k], 1);
        }
    }
    for (int k = 0; k < clients; k++) pthread_join(t[k], NULL);
    for (int k = 0; k < clients; k++) {
        assert(cl[k].served == (unsigned)r);
        close(cl[k].req[0]); close(cl[k].req[1]); close(cl[k].rep[0]); close(cl[k].rep[1]);
    }
    printf("loop%s clients=%d rounds=%d think<%dus sweep=%dms miss_every=%d: %llu requests in %.0f ms, %llu signals, %llu rearms, "
           "%llu failed reads, %llu full sweeps, %llu found by a sweep, %llu wake timeouts\n",
           old ? " (before 0175)" : "", clients, r, think, sweep_ms, miss, total, now_ms() - start, signals, rearms, failed_reads, full_sweeps,
           found_by_sweep, timeouts_waiting);
    /* a signal needs armed 0 -> 1, and only a rearm (or the start) sets 0: the semaphore count cannot run away */
    if (!old) assert(signals <= rearms + 1);
    free(cl); free(t);
    sem_destroy(&wake);
    return 0;
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;
    setvbuf(stdout, NULL, _IONBF, 0);
    unit();
    concurrent();
    /* No full sweep at all: every request is read through its mark, and no wake is lost (no 1 s timeout). */
    loop(64, 2000, 0, 0, 0, 0);
    assert(timeouts_waiting == 0 && found_by_sweep == 0 && failed_reads == 0);
    /* RDR2's thread count: one read per request. The loop before 0175 reads every pipe on every pass, so its
     * failed reads depend on how the clients' writes fall between its passes. */
    loop(280, 300, 0, 0, 0, 0);
    assert(timeouts_waiting == 0 && found_by_sweep == 0 && failed_reads == 0 && reads == 280 * 300);
    loop(280, 300, 0, 0, 1, 0);
    assert(reads + failed_reads == full_sweeps * 280);
    /* Clients that do some work between requests, as game threads do: the old loop's failed reads per request. */
    loop(280, 100, 0, 0, 0, 2000);
    assert(timeouts_waiting == 0 && failed_reads == 0);
    loop(280, 100, 0, 0, 1, 2000);
    assert(reads + failed_reads == full_sweeps * 280);
    /* Clients that sometimes forget to mark: the 50 ms full sweep serves them. */
    loop(32, 40, 50, 4, 0, 0);
    assert(found_by_sweep >= 32 * 40 / 4 && full_sweeps > 0);
    printf("ok\n");
    return 0;
}
'''


class SrvPendingTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            subprocess.run(["git", "apply", f"--include={HEADER}", str(PATCH)], cwd=d, check=True)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-pthread", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            out = subprocess.run([str(d / "t")], check=True, timeout=300, capture_output=True, text=True).stdout
            self.assertTrue(out.endswith("ok\n"), out)

    def test_the_server_reads_marks_and_sweeps(self):
        """The loop drains the set, skips request fds between full sweeps, and the client marks after its write."""
        text = PATCH.read_text()
        self.assertIn('+            const char *e = getenv( "MADEIRA_SRV_PENDING" );', text)
        self.assertIn("+#define IOS_SRV_FULL_SWEEP_NS 50000000ull", text)
        self.assertIn("+                            if (ios_full_sweep || !ios_fd_is_thread_request( i ))", text)
        self.assertIn("+        ios_wineserver_kick_thread( data->tid );", text)
        self.assertIn("+            ios_wineserver_kick_thread( data->tid );", text)


if __name__ == "__main__":
    unittest.main()

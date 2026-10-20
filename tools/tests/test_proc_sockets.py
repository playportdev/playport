# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0176's pp_proc_sockets.h (PLA-364, PLA-413): a child pseudo-process's master
socket entry is given back when it ends and reused by a later child (RDR2's 56th Social Club helper start found the
64-entry table full and spoke on another process's socket)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0176-ntdll-reuse-a-child-process-s-master-socket-entry-af.patch"
HEADER = "build/ntdll-unix/pp_proc_sockets.h"

TEST_C = r'''
#include "pp_proc_sockets.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>

#define MAX 4

static struct ios_proc_socket table[MAX];
static int count;

static int reg(uintptr_t peb, int fd) {
    int i = ppps_claim(table, &count, MAX);
    if (i >= 0) ppps_publish(table, i, (void *)peb, fd);
    return i;
}

/* Children starting and ending at once: an entry is never held by two, and each socket is given back once. */
#define RACERS 8
#define ROUNDS 20000
static struct ios_proc_socket big[64];
static int big_count;
static volatile int holder[64];

static void *racer(void *arg) {
    uintptr_t base = (uintptr_t)arg;
    for (unsigned r = 0; r < ROUNDS; r++) {
        uintptr_t peb = 0x10000 + base * 0x100000 + r * 0x10;
        int fd = (int)(base * 100000 + r), got;
        int i = ppps_claim(big, &big_count, 64);
        assert(i >= 0);
        assert(__atomic_exchange_n(&holder[i], (int)base + 1, __ATOMIC_ACQ_REL) == 0);
        ppps_publish(big, i, (void *)peb, fd);
        assert(ppps_scan_count(&big_count, 64) > i);
        assert(__atomic_exchange_n(&holder[i], 0, __ATOMIC_ACQ_REL) == (int)base + 1);
        assert(ppps_release(big, i, (void *)peb, &got) == 1 && got == fd);
        assert(ppps_release(big, i, (void *)peb, &got) == 0);   /* the racing exit or teardown: nothing to close */
    }
    return 0;
}

int main(void) {
    int fd = -1;
    /* the old table only grew: 4 children started and ended one after another took all 4 entries */
    for (int n = 0; n < 1000; n++) {
        int i = reg(0x1000 + n * 0x10, 100 + n);
        assert(i == 0 && count == 1);
        assert(ppps_release(table, i, (void *)(uintptr_t)(0x1000 + n * 0x10), &fd) == 1 && fd == 100 + n);
    }
    /* the lowest free entry; full only with MAX live; a wrong PEB gives nothing back */
    assert(reg(0xa0, 10) == 0 && reg(0xb0, 11) == 1 && reg(0xc0, 12) == 2 && reg(0xd0, 13) == 3);
    assert(count == MAX && ppps_claim(table, &count, MAX) == -1);
    assert(ppps_release(table, 1, (void *)0xa0, &fd) == 0);
    assert(ppps_release(table, 1, (void *)0xb0, &fd) == 1 && fd == 11);
    assert(reg(0xe0, 14) == 1 && table[1].fd == 14 && table[1].exiting == 0);
    /* a claimed entry not yet published names no PEB and is given back by nobody */
    assert(ppps_release(table, 2, (void *)0xc0, &fd) == 1);
    assert(ppps_claim(table, &count, MAX) == 2);
    assert(table[2].peb == PPPS_CLAIMED && ppps_release(table, 2, PPPS_CLAIMED, &fd) == 0);
    assert(ppps_scan_count(&count, MAX) == MAX);
    count = MAX + 3;   /* a mark past the table is scanned only to its end */
    assert(ppps_scan_count(&count, MAX) == MAX);

    pthread_t t[RACERS];
    for (uintptr_t k = 0; k < RACERS; k++) assert(pthread_create(&t[k], 0, racer, (void *)k) == 0);
    for (int k = 0; k < RACERS; k++) pthread_join(t[k], 0);
    assert(big_count <= RACERS);
    for (int i = 0; i < 64; i++) assert(big[i].peb == 0);
    return 0;
}
'''


class ProcSocketTests(unittest.TestCase):
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
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-fsanitize=thread", "-I", str((d / HEADER).parent), "-o", str(d / "t"),
                            str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_registration_exit_and_teardown_use_it(self):
        text = PATCH.read_text()
        self.assertIn("+    int idx = ppps_claim( ios_proc_sockets, &ios_proc_socket_count, IOS_MAX_PROC_SOCKETS );", text)
        self.assertIn("+        if (!ppps_release( ios_proc_sockets, i, peb, &fd )) continue;", text)
        self.assertIn("+            if (ppps_release( ios_proc_sockets, i, dead_peb, &fd ))", text)


if __name__ == "__main__":
    unittest.main()

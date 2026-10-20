# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0173's pp_thread_slots.h (PLA-364, decision 0134): a thread's Mach exception
registry entry and TEB-restore trampoline slot are given back when it ends or is parked, and reused."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0173-ntdll-give-back-a-thread-s-exception-registry-entry-.patch"
HEADER = "build/ntdll-unix/pp_thread_slots.h"

TEST_C = r'''
#include "pp_thread_slots.h"
#include <assert.h>
#include <pthread.h>
#include <string.h>

#define MAX 4

static struct ios_thread_entry reg[MAX];
static volatile int32_t count;

static int claim(unsigned port, int *again) {
    int i = ppts_registry_claim(reg, &count, MAX, port, again);
    if (i >= 0) ppts_registry_publish(reg, i, port, 0x7000000000ull + port * 0x1000, (void *)(uintptr_t)port);
    return i;
}

/* Many threads registering and ending at once: no entry is ever held by two. */
#define RACERS 8
#define ROUNDS 20000
static struct ios_thread_entry big[64];
static volatile int32_t big_count;
static volatile int32_t owner[64];

static void *racer(void *arg) {
    unsigned base = (unsigned)(uintptr_t)arg;
    for (unsigned r = 0; r < ROUNDS; r++) {
        unsigned port = base * 0x100000 + r + 1;
        int again = 0;
        int i = ppts_registry_claim(big, &big_count, 64, port, &again);
        assert(i >= 0 && i < 64 && !again);
        assert(__atomic_fetch_add(&owner[i], 1, __ATOMIC_ACQ_REL) == 0);
        ppts_registry_publish(big, i, port, port, NULL);
        assert(ppts_registry_find(big, 64, port) == i);
        assert(__atomic_fetch_sub(&owner[i], 1, __ATOMIC_ACQ_REL) == 1);
        assert(ppts_registry_release(big, 64, i, port));
    }
    return NULL;
}

int main(void) {
    int again = -1;

    /* New threads take new entries up to the mark; the same port again keeps its entry. */
    assert(claim(0x103, &again) == 0 && !again);
    assert(claim(0x207, &again) == 1 && !again);
    assert(claim(0x103, &again) == 0 && again);
    assert(claim(0x30b, &again) == 2 && claim(0x40f, &again) == 3 && count == 4);
    /* Full: -1, as before; the mark stays clamped for the readers. */
    assert(ppts_registry_claim(reg, &count, MAX, 0x513, &again) == -1);
    assert(ppts_registry_find(reg, MAX, 0x513) == -1);

    /* A thread that ends gives its entry back: TEB and trampoline cleared, port 0, and the next new thread takes
     * the lowest free entry before the mark grows. */
    assert(ppts_registry_release(reg, MAX, 1, 0x207));
    assert(reg[1].mach_thread == 0 && reg[1].teb == 0 && reg[1].trampoline == NULL);
    assert(ppts_registry_find(reg, MAX, 0x207) == -1);
    assert(!ppts_registry_release(reg, MAX, 1, 0x207));     /* once */
    assert(!ppts_registry_release(reg, MAX, 2, 0x207));     /* only the entry naming the port */
    assert(!ppts_registry_release(reg, MAX, -1, 0x207));    /* never registered (the FULL case) */
    assert(!ppts_registry_release(reg, MAX, 0, 0));
    assert(ppts_registry_release(reg, MAX, 3, 0x40f));
    int32_t mark = count;
    assert(claim(0x617, &again) == 1 && !again && reg[1].teb == 0x7000000000ull + 0x617 * 0x1000);
    assert(claim(0x71b, &again) == 3 && count == mark);
    assert(ppts_registry_find(reg, MAX, 0x617) == 1);

    /* A claimed entry names no thread until it is published. */
    assert(ppts_registry_release(reg, MAX, 2, 0x30b));
    int c = ppts_registry_claim(reg, &count, MAX, 0x81f, &again);
    assert(c == 2 && reg[2].mach_thread == PPTS_CLAIMED && reg[2].teb == 0);
    assert(ppts_registry_find(reg, MAX, 0x81f) == -1);
    ppts_registry_publish(reg, c, 0x81f, 0x1234, NULL);
    assert(ppts_registry_find(reg, MAX, 0x81f) == 2);

    /* A claim that races a free-entry scan for the entry at the mark looks again. */
    {
        struct ios_thread_entry r2[MAX];
        volatile int32_t n2 = 1;
        memset(r2, 0, sizeof r2);
        r2[0].mach_thread = 0x10;
        r2[1].mach_thread = 0x20;   /* taken by another claim after the mark moved, before this one's CAS */
        int k = ppts_registry_claim(r2, &n2, MAX, 0x30, &again);
        assert(k == 2 && n2 == 3);
    }

    {
        pthread_t t[RACERS];
        for (unsigned k = 0; k < RACERS; k++) assert(!pthread_create(&t[k], NULL, racer, (void *)(uintptr_t)(k + 1)));
        for (unsigned k = 0; k < RACERS; k++) pthread_join(t[k], NULL);
        assert(big_count < 64);   /* entries are reused: 160,000 registrations, the mark stays near the live count */
        for (int k = 0; k < 64; k++) assert(big[k].mach_thread == 0);
    }

    /* Trampoline slots: lowest free first; slot 0 (the first thread's and every overflow's) is never given back. */
    {
        static volatile uint8_t used[4];
        assert(ppts_trampoline_claim(used, 4) == 0);
        assert(ppts_trampoline_claim(used, 4) == 1);
        assert(ppts_trampoline_claim(used, 4) == 2);
        assert(ppts_trampoline_claim(used, 4) == 3);
        assert(ppts_trampoline_claim(used, 4) == -1);
        assert(!ppts_trampoline_release(used, 4, 0));
        assert(ppts_trampoline_release(used, 4, 2));
        assert(!ppts_trampoline_release(used, 4, 2));
        assert(!ppts_trampoline_release(used, 4, 4) && !ppts_trampoline_release(used, 4, -1));
        assert(ppts_trampoline_claim(used, 4) == 2);
    }
    return 0;
}
'''


class ThreadSlotsTests(unittest.TestCase):
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
            subprocess.run([str(d / "t")], check=True)

    def test_the_trampoline_page_holds_every_slot(self):
        """1024 slots of 16 bytes fill exactly the pool's reserved first page (jit_pool_offset 0x4000)."""
        text = PATCH.read_text()
        self.assertIn("+#define IOS_JIT_MAX_SLOTS 1024", text)
        self.assertEqual(1024 * 16, 0x4000)


if __name__ == "__main__":
    unittest.main()

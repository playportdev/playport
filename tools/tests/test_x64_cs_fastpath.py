# SPDX-License-Identifier: GPL-3.0-or-later
"""Run wine-pe 0050's x64 critical-section stubs (MADEIRA_X64_CS_FASTPATH, PLA-364) natively on an x86-64 host:
GS points at a fake TEB (ClientId.UniqueThread at 0x48), and the stubs' slow targets are C copies of Wine's
RtlEnterCriticalSection/RtlLeaveCriticalSection with a semaphore as the wait. Threads that call the stubs and threads
that call the C functions (ARM64EC callers) share one section, with recursion; a lone thread never leaves the stubs."""
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/wine-pe/0050-ntdll-MADEIRA_X64_CS_FASTPATH-1-takes-an-x64-module-.patch"

TEST_C = r'''
#define _GNU_SOURCE
#include <asm/prctl.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "stubs.h"

typedef struct { void *debug; volatile int32_t lock_count; volatile int32_t recursion; volatile uintptr_t owner;
                 void *semaphore; uintptr_t spin; } section;
_Static_assert(__builtin_offsetof(section, lock_count) == 8 && __builtin_offsetof(section, recursion) == 12 &&
               __builtin_offsetof(section, owner) == 16, "x64 RTL_CRITICAL_SECTION");
typedef int (__attribute__((ms_abi)) *cs_fn)(section *);

static __thread uintptr_t tid;
static sem_t wait_sem;
static long slow_calls;
static section cs = { 0, -1, 0, 0, 0, 0 };
static long counter;
static cs_fn stub_enter, stub_leave;
static long loops, threads;

static int __attribute__((ms_abi)) c_enter(section *c)
{
    __atomic_add_fetch(&slow_calls, 1, __ATOMIC_RELAXED);
    if (__atomic_add_fetch(&c->lock_count, 1, __ATOMIC_SEQ_CST)) {
        if (c->owner == tid) { c->recursion++; return 0; }
        while (sem_wait(&wait_sem));
    }
    c->owner = tid; c->recursion = 1;
    return 0;
}

static int __attribute__((ms_abi)) c_leave(section *c)
{
    __atomic_add_fetch(&slow_calls, 1, __ATOMIC_RELAXED);
    if (--c->recursion) {
        if (c->recursion < 0) abort();
        __atomic_sub_fetch(&c->lock_count, 1, __ATOMIC_SEQ_CST);
    } else {
        c->owner = 0;
        if (__atomic_sub_fetch(&c->lock_count, 1, __ATOMIC_SEQ_CST) >= 0) sem_post(&wait_sem);
    }
    return 0;
}

static void *worker(void *arg)
{
    static uintptr_t tebs[16][16];
    long id = (long)arg, i;
    int ec_caller = threads > 1 && (id & 1);
    cs_fn enter = ec_caller ? c_enter : stub_enter, leave = ec_caller ? c_leave : stub_leave;

    tid = 0x100 + id * 4;
    tebs[id][0x48 / 8] = tid;
    if (syscall(SYS_arch_prctl, ARCH_SET_GS, (unsigned long)tebs[id])) { perror("ARCH_SET_GS"); exit(3); }
    for (i = 0; i < loops; i++) {
        enter(&cs);
        if (cs.owner != tid || cs.recursion != 1) { fprintf(stderr, "not the owner\n"); exit(4); }
        counter++;
        if (i % 7 == 0) {
            enter(&cs);
            if (cs.recursion != 2) { fprintf(stderr, "recursion\n"); exit(5); }
            leave(&cs);
        }
        leave(&cs);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    unsigned char *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    pthread_t th[16];
    void *target;
    long i;

    threads = atol(argv[1]); loops = atol(argv[2]);
    memcpy(page, x64_cs_enter_code, sizeof(x64_cs_enter_code));
    target = (void *)c_enter; memcpy(page + sizeof(x64_cs_enter_code), &target, 8);
    memcpy(page + 0x80, x64_cs_leave_code, sizeof(x64_cs_leave_code));
    target = (void *)c_leave; memcpy(page + 0x80 + sizeof(x64_cs_leave_code), &target, 8);
    stub_enter = (cs_fn)page; stub_leave = (cs_fn)(page + 0x80);
    sem_init(&wait_sem, 0, 0);
    for (i = 0; i < threads; i++) pthread_create(&th[i], NULL, worker, (void *)i);
    for (i = 0; i < threads; i++) pthread_join(th[i], NULL);
    printf("counter=%ld lock_count=%d recursion=%d owner=%lx slow=%ld\n", counter, cs.lock_count, cs.recursion,
           (unsigned long)cs.owner, slow_calls);
    if (counter != threads * loops || cs.lock_count != -1 || cs.recursion || cs.owner) return 1;
    if (threads == 1 && slow_calls != loops / 7 * 2 + (loops % 7 ? 2 : 0)) return 2;   /* only the recursive pairs */
    return 0;
}
'''


def stub_arrays(text):
    out = []
    for name in ("x64_cs_enter_code", "x64_cs_leave_code"):
        body = text[text.index("+static const BYTE %s[] =" % name):]
        body = body[body.index("{") + 1:body.index("};")]
        body = re.sub(r"/\*.*?\*/", "", body, flags=re.S).replace("+", "")
        values = [int(v, 0) for v in body.split(",") if v.strip()]
        out.append("static const unsigned char %s[] = {%s};" % (name, ",".join(map(str, values))))
    return "\n".join(out) + "\n"


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "runs x64 code natively")
class X64CriticalSectionStubTests(unittest.TestCase):
    def run_stubs(self, threads, loops):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "stubs.h").write_text(stub_arrays(PATCH.read_text()))
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Werror", "-pthread", "-o", str(d / "t"),
                            str(d / "test.c")], check=True)
            r = subprocess.run([str(d / "t"), str(threads), str(loops)], capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_contended_with_ec_callers(self):
        self.run_stubs(6, 300000)

    def test_a_lone_thread_stays_in_the_stubs(self):
        self.run_stubs(1, 100000)

    def test_the_sizes_the_loader_assumes(self):
        text = PATCH.read_text()
        self.assertIn("C_ASSERT( sizeof(x64_cs_enter_code) == 0x2b && sizeof(x64_cs_leave_code) == 0x46 );", text)
        enter, leave = (len(line.split("{")[1].split(",")) for line in stub_arrays(text).splitlines())
        self.assertEqual((enter, leave), (0x2b, 0x46))


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""madeira-unix 0211, hand-ported from Madeira 6c3fd8c (#300): Chromium's out-of-memory exit names the
failed request's size at NtTerminateProcess. ios_term_oom_record is taken from the patch and compiled
with a fake TEB and a fake mach_vm_read_overwrite that reads this process's memory (Madeira's own
check, tests/host/check-chromium-oom-exit.py): a record anywhere in the top 256 KB of the stack, across
the edge of its 64 KB read chunks too, is found and printed with the request size and the two page
file figures; lookalikes (a nested record, continuable, no parameters) are skipped; an unreadable chunk
is skipped; a stack without a record says so. And NtTerminateProcess calls it for exit code 0xE0000008
of the current process, before the capped [term-stack] dump."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0211-ntdll-the-request-size-of-Chromium-s-out-of-memory-e.patch"


def added():
    return "\n".join(l[1:] for l in PATCH.read_text().splitlines() if l.startswith("+") and not l.startswith("+++"))


source = added()
start = source.index("static void ios_term_oom_record( TEB *teb )")
function = source[start:source.index("\n}\n", start) + 3]

harness = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
typedef void *PVOID;
typedef uintptr_t ULONG_PTR;
typedef long LONG;
typedef struct { PVOID ExceptionList, StackBase, StackLimit; } NT_TIB;
typedef struct { NT_TIB Tib; } TEB;
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef int kern_return_t;
#define KERN_SUCCESS 0
static int mach_task_self(void) { return 0; }
static uint64_t bad_lo, bad_hi;   /* an unreadable range */
static kern_return_t mach_vm_read_overwrite(int task, mach_vm_address_t a, mach_vm_size_t n, mach_vm_address_t to, mach_vm_size_t *got)
{
    (void)task;
    if (a < bad_hi && a + n > bad_lo) return 1;
    memcpy((void *)(uintptr_t)to, (void *)(uintptr_t)a, n);
    *got = n;
    return KERN_SUCCESS;
}
static LONG InterlockedIncrement(LONG *p) { return ++*p; }
static char out[1 << 16];
static size_t outn;
static int fake_dprintf(int fd, const char *f, ...)
{
    va_list ap; int w;
    (void)fd;
    va_start(ap, f);
    w = vsnprintf(out + outn, sizeof out - outn, f, ap);
    va_end(ap);
    if (w > 0) outn += (size_t)w;
    return w;
}
#define dprintf fake_dprintf
''' + function + r'''
static void put(uint64_t *q, uint32_t code, uint32_t flags, uint64_t nested, uint64_t np, uint64_t a0)
{
    q[0] = code | ((uint64_t)flags << 32);
    q[1] = nested;
    q[2] = 0x154440110ull;   /* the address in the 13:39 log */
    q[3] = np;
    q[4] = a0;
    q[5] = 3ull << 30;
    q[6] = 12ull << 30;
}
int main(void)
{
    size_t words = (1 << 20) / 8;   /* a 1 MB stack */
    uint64_t *stack = aligned_alloc(4096, words * 8);
    TEB teb;
    uint64_t base = (uint64_t)(uintptr_t)stack, top = base + words * 8, lo = top - 0x40000;
    size_t at;

    teb.Tib.StackLimit = stack;
    teb.Tib.StackBase = (PVOID)(uintptr_t)top;

    /* 1: lookalikes first (nested record, continuable, no parameters), then the record */
    memset(stack, 0, words * 8);
    put(stack + words - 2000, 0xE0000008u, 1, 0x1234, 3, 0x111);
    put(stack + words - 1900, 0xE0000008u, 0, 0, 3, 0x222);
    put(stack + words - 1800, 0xE0000008u, 1, 0, 0, 0x333);
    put(stack + words - 1200, 0xE0000008u, 1, 0, 3, 0x200000);
    outn = 0; out[0] = 0;
    ios_term_oom_record(&teb);
    printf("%s", out);
    if (!strstr(out, "3 parameter(s): request 0x200000 bytes (2 MB), 3072 MB, 12288 MB")
        || !strstr(out, "raised at 0x154440110")) { printf("FAIL: the record in the stack's top was not reported\n"); return 1; }
    if (strstr(out, "0x111") || strstr(out, "0x222") || strstr(out, "0x333")) { printf("FAIL: a lookalike was reported\n"); return 1; }

    /* 2: a record across a chunk edge: the first chunk ends at lo + 64 KB */
    memset(stack, 0, words * 8);
    at = (size_t)((lo - base) / 8) + 8192 - 6;   /* starts 6 qwords before the edge */
    put(stack + at, 0xE0000008u, 1, 0, 3, 0x4000000);
    outn = 0; out[0] = 0;
    ios_term_oom_record(&teb);
    printf("%s", out);
    if (!strstr(out, "request 0x4000000 bytes (64 MB)")) { printf("FAIL: a record across a chunk edge was missed\n"); return 1; }

    /* 3: one record, the chunk before it unreadable */
    memset(stack, 0, words * 8);
    put(stack + words - 300, 0xE0000008u, 1, 0, 1, 0x10000);
    bad_lo = lo; bad_hi = lo + 0x10000;
    outn = 0; out[0] = 0;
    ios_term_oom_record(&teb);
    printf("%s", out);
    if (!strstr(out, "1 parameter(s): request 0x10000 bytes (0 MB)\n")) { printf("FAIL: an unreadable chunk stopped the scan\n"); return 1; }
    bad_lo = bad_hi = 0;

    /* 4: no record */
    memset(stack, 0, words * 8);
    outn = 0; out[0] = 0;
    ios_term_oom_record(&teb);
    printf("%s", out);
    if (!strstr(out, "no 0xE0000008 record")) { printf("FAIL: a stack without a record was not reported as such\n"); return 1; }
    printf("PASS: the record is found in the top 256 KB (across chunk edges and past an unreadable chunk), lookalikes are skipped, a missing record is said\n");
    free(stack);
    return 0;
}
'''



class ChromiumOomExitTests(unittest.TestCase):
    def test_record_search(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            c = pathlib.Path(td) / "oom.c"
            exe = pathlib.Path(td) / "oom"
            c.write_text(harness)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Werror", "-Wno-unused-function", "-o", str(exe), str(c)],
                           check=True)
            run = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_nt_terminate_process_calls_it(self):
        text = PATCH.read_text()
        self.assertIn("+    if ((unsigned int)exit_code == 0xE0000008u && handle == NtCurrentProcess())\n"
                      "+        ios_term_oom_record( NtCurrentTeb() );\n", text)


if __name__ == "__main__":
    unittest.main()

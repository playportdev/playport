# SPDX-License-Identifier: GPL-3.0-or-later
"""Run wine-pe 0053's x64 InitOnceExecuteOnce stub (MADEIRA_X64_ONCE_FASTPATH, PLA-364) natively on an x86-64 host.
A completed INIT_ONCE (Ptr & 3 == 2) is answered in the stub: TRUE, and the context Ptr & ~3 when one is asked for.
Every other state reaches the slow target, a C stand-in for kernelbase's export, with all four arguments intact."""
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/wine-pe/0053-ntdll-MADEIRA_X64_ONCE_FASTPATH-1-answers-an-x64-mod.patch"

TEST_C = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include "stub.h"

typedef int (__attribute__((ms_abi)) *once_fn)(void **once, void *func, void *param, void **context);
static long slow_calls;
static void **seen_once, **seen_context;
static void *seen_func, *seen_param;

static int __attribute__((ms_abi)) slow(void **once, void *func, void *param, void **context)
{
    slow_calls++;
    seen_once = once; seen_func = func; seen_param = param; seen_context = context;
    return 0x55;
}

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "line %d: %s\n", __LINE__, #c); return 1; } } while (0)

int main(void)
{
    unsigned char *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    void *target = (void *)slow, *once, *context;
    once_fn stub = (once_fn)page;
    int r;

    memcpy(page, x64_once_code, sizeof(x64_once_code));
    memcpy(page + sizeof(x64_once_code), &target, 8);

    /* completed, with a context */
    once = (void *)(0x7000123450ULL | 2); context = (void *)1;
    r = stub(&once, (void *)0x11, (void *)0x22, &context);
    CHECK(r == 1 && context == (void *)0x7000123450ULL && slow_calls == 0);
    CHECK(once == (void *)(0x7000123450ULL | 2));
    /* completed, no context asked for */
    r = stub(&once, (void *)0x11, (void *)0x22, NULL);
    CHECK(r == 1 && slow_calls == 0);
    /* first call, in progress, async in progress: kernelbase's export, arguments intact */
    for (uintptr_t state = 0; state < 4; state++) {
        if (state == 2) continue;
        once = (void *)(0x7000123450ULL | state); context = (void *)1;
        r = stub(&once, (void *)0x11, (void *)0x22, &context);
        CHECK(r == 0x55 && seen_once == &once && seen_func == (void *)0x11 && seen_param == (void *)0x22);
        CHECK(seen_context == &context && context == (void *)1);
    }
    CHECK(slow_calls == 3);
    printf("ok\n");
    return 0;
}
'''


def stub_array(text):
    body = text[text.index("+static const BYTE x64_once_code[] ="):]
    body = body[body.index("{") + 1:body.index("};")]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S).replace("+", "")
    values = [int(v, 0) for v in body.split(",") if v.strip()]
    return "static const unsigned char x64_once_code[] = {%s};\n" % ",".join(map(str, values)), len(values)


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "runs x64 code natively")
class X64InitOnceStubTests(unittest.TestCase):
    def test_completed_once_stays_in_the_stub(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "stub.h").write_text(stub_array(PATCH.read_text())[0])
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            r = subprocess.run([str(d / "t")], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_the_size_the_loader_assumes(self):
        text = PATCH.read_text()
        self.assertIn("C_ASSERT( sizeof(x64_once_code) == 0x28 );", text)
        self.assertEqual(stub_array(text)[1], 0x28)


if __name__ == "__main__":
    unittest.main()

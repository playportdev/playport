# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise madeira-unix 0266's pp_fault_loop.h (PLA-514): the Mach handler's fault-loop breaker ends a
thread only when that thread faults on the same page and pc 50 times in a row, not when many threads each fault once
at the same place (World of Warcraft's threads, each raising the UDF in its DLL_THREAD_ATTACH callback)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0266-signal-the-fault-loop-breaker-counts-one-thread-s-fa.patch"
HEADER = "build/ntdll-unix/pp_fault_loop.h"

TEST_C = r'''
#include "pp_fault_loop.h"
#include <assert.h>
#include <string.h>

#define PC 0x10c64e7a4ull
#define ADDR 0x4000ull

static struct ppfl_state s;
static uint32_t adv;

static uint32_t note(uint32_t thread, uint64_t pc, uint64_t addr, int align) {
    return ppfl_note(&s, thread, pc, addr, align, &adv);
}

int main(void) {
    /* One thread re-faulting at one pc and address: counted, and ended at the 50th; the count then restarts. */
    memset(&s, 0, sizeof s);
    assert(note(0x103, PC, ADDR, 0) == 0);   /* the first of a run */
    for (uint32_t k = 1; k < PPFL_BREAK_AT; k++) assert(note(0x103, PC, ADDR, 0) == k);
    assert(note(0x103, PC, ADDR, 0) == PPFL_BREAK_AT);
    assert(note(0x103, PC, ADDR, 0) == 1);

    /* The run 20261101T031619 pattern: 30 threads, each faulting twice at the same pc and address. None is ended. */
    memset(&s, 0, sizeof s);
    for (uint32_t t = 0; t < 30; t++) {
        assert(note(0x200 + t, PC, ADDR, 0) == 0);
        assert(note(0x200 + t, PC, ADDR, 0) == 1);
    }
    /* Interleaved the same. */
    memset(&s, 0, sizeof s);
    for (uint32_t k = 0; k < 200; k++) assert(note(0x300 + (k & 1), PC, ADDR, 0) == 0);

    /* Alignment faults are not counted and leave the state as it was: the loop around them still breaks. */
    memset(&s, 0, sizeof s);
    note(0x103, PC, ADDR, 0);
    for (uint32_t k = 1; k < PPFL_BREAK_AT; k++) {
        assert(note(0x103, PC, ADDR, 1) == 0);
        assert(note(0x103, PC, ADDR, 0) == k);
    }
    assert(note(0x103, PC, ADDR, 0) == PPFL_BREAK_AT);

    /* The same page and pc at a new address is progress: the run restarts, the storm count grows. */
    memset(&s, 0, sizeof s);
    note(0x103, PC, 0x7000004000ull, 0);
    for (uint32_t k = 1; k < 30000; k++) {
        uint32_t n = note(0x103, PC, 0x7000004000ull + 8 * (k % 2048), 0);
        if (k < PPFL_STORM_CEILING) assert(n == 1 && adv == k);
        else assert(n == PPFL_BREAK_AT);   /* the storm ceiling: every further new address breaks */
    }

    /* Another page or pc starts a new run; the NULL page is a page too. */
    memset(&s, 0, sizeof s);
    note(0x103, PC, 8, 0);
    assert(note(0x103, PC, 16, 0) == 1 && s.page == 1);
    assert(note(0x103, PC + 4, 16, 0) == 0);
    assert(note(0x103, PC + 4, 0x8000, 0) == 0);
    assert(ppfl_page(0x7000007ff8ull) == 0x7000004000ull && ppfl_page(0) == 1);
    return 0;
}
'''


class FaultLoopTests(unittest.TestCase):
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
            subprocess.run([cc, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I",
                            str((d / HEADER).parent), "-o", str(d / "t"), str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_the_handler_keys_on_the_thread(self):
        """The handler passes the faulting Mach thread and keeps no breaker state of its own."""
        text = PATCH.read_text()
        self.assertIn("+                        uint32_t n = ppfl_note( &fault_loop, thread, fault_pc_check,", text)
        self.assertIn("-                        static volatile uint32_t stuck_n;", text)

    def test_a_breakpoint_is_not_counted(self):
        """madeira-unix 0275 (PLA-516): FEX raises every guest int3 from one BRK, so a breakpoint is passed as not
        counted, like an alignment fault, and a client taking int3 after int3 on one thread is not ended."""
        text = (ROOT / "patches/madeira-unix/0275-signal-the-fault-loop-breaker-does-not-count-a-break.patch").read_text()
        self.assertIn("+                                                fault_kr == EXC_ARM_DA_ALIGN || "
                      "req->exception == EXC_BREAKPOINT,", text)


if __name__ == "__main__":
    unittest.main()

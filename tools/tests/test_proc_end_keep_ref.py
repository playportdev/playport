# SPDX-License-Identifier: GPL-3.0-or-later
"""madeira-unix 0227's [proc-end] keep-ref logger (PLA-476), compiled from the patch against the shipped
pp_proc_end.h: every parked ref of every thread it names for a kept view, on one line, its 64-line cap, and that
the release app (MADEIRA_NO_DIAGNOSTICS, ios_no_diagnostics()) gets none of its lines."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERIES = ROOT / "patches/madeira-unix"
PROC_END_PATCHES = ("0169-ntdll-wineserver-tear-down-a-pseudo-process-another-.patch",
                    "0172-ntdll-empty-a-killed-process-s-FEX-band-views-in-pla.patch",
                    "0203-ntdll-release-a-self-exited-child-s-FEX-band-views-a.patch")
HEADER = "build/ntdll-unix/pp_proc_end.h"
LOGGER_PATCH = SERIES / "0227-ntdll-name-the-parked-register-that-keeps-a-view.patch"

# The order ios_abort_park_state saves a parked thread's refs in, for a readable thread whose
# thread_info succeeded and whose wait address was found: the 53 refs (PPE_REFS) 0227 documents.
REF_NAMES = ([f"x{i}" for i in range(29)] + ["fp", "lr", "sp", "pc"]
             + ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
                "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip"]
             + ["tpidrro_el0", "teb", "wait"])


def logger_source():
    """0227's first hunk, added above ios_proc_end_release_views_locked: its comment, the per-thread ref
    table and ios_proc_end_log_keep_ref."""
    hunk = LOGGER_PATCH.read_text().split("\n@@ ", 2)[1]
    return "\n".join(line[1:] for line in hunk.splitlines() if line.startswith("+")) + "\n"


TEST_C = r'''
#include <assert.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pp_proc_end.h"
#define IOS_PROC_END_PARKED_MAX 256
static uint64_t ios_proc_end_refs[IOS_PROC_END_PARKED_MAX * PPE_REFS];
static int no_diagnostics, lines;
static char last[4096];
static int ios_no_diagnostics(void) { return no_diagnostics; }
__attribute__((format(printf, 2, 3)))
static int test_dprintf(int fd, const char *fmt, ...)
{
    va_list ap;
    assert(fd == 2);
    va_start(ap, fmt);
    vsnprintf(last, sizeof last, fmt, ap);
    va_end(ap);
    lines++;
    return 0;
}
#define dprintf test_dprintf
#include "logger.c"

#define BASE 0x7a00000000ull
#define SIZE 0x100000ull

/* Thread 0 (tid 0x20) has 50 refs (no thread_info, no wait address), none in the view; thread 1 (tid 0x44)
 * has all 53, each 0x1000 * index below the view, except ref `in` which lies in it. */
static unsigned setup(int in)
{
    unsigned i;
    for (i = 0; i < 50; i++) ios_proc_end_refs[i] = 0x1000 + i;
    ios_proc_end_ref_thread[0].start = 0; ios_proc_end_ref_thread[0].n = 50; ios_proc_end_ref_thread[0].tid = 0x20;
    for (i = 0; i < PPE_REFS; i++) ios_proc_end_refs[50 + i] = BASE - 0x1000 * (i + 1);
    if (in >= 0) ios_proc_end_refs[50 + in] = BASE + SIZE - 8;
    ios_proc_end_ref_thread[1].start = 50; ios_proc_end_ref_thread[1].n = PPE_REFS; ios_proc_end_ref_thread[1].tid = 0x44;
    return 2;
}

int main(int argc, char **argv)
{
    char want[256];
    int index;
    assert(argc == 2);
    if (!strcmp(argv[1], "quiet")) {          /* the release app: nothing, and the cap is not spent */
        no_diagnostics = 1;
        ios_proc_end_log_keep_ref((void *)0x1234, BASE, SIZE, PPE_KEEP_REF, setup(29));
        assert(lines == 0);
        no_diagnostics = 0;
        ios_proc_end_log_keep_ref((void *)0x1234, BASE, SIZE, PPE_KEEP_REF, setup(29));
        assert(lines == 1);
        return 0;
    }
    if (!strcmp(argv[1], "cap")) {            /* 64 lines a run, matched or not */
        for (int i = 0; i < 100; i++)
            ios_proc_end_log_keep_ref((void *)0x1234, BASE, SIZE, PPE_KEEP_REF, setup(i & 1 ? -1 : 31));
        assert(lines == 64);
        return 0;
    }
    if (!strcmp(argv[1], "every")) {          /* the older thread's sp and the newer one's wait, in teb_list order */
        setup(PPE_REFS - 1);
        ios_proc_end_refs[31] = BASE + 0x40;
        ios_proc_end_log_keep_ref((void *)0x1234, BASE, SIZE, PPE_KEEP_REF, 2);
        snprintf(want, sizeof want, "[proc-end] keep-ref peb=%p view=%p+0x%llx fate=%d tid=0020 ref#31/50=0x%llx "
                 "tid=0044 ref#52/53=0x%llx (PLA-476)\n", (void *)0x1234, (void *)(uintptr_t)BASE, SIZE, PPE_KEEP_REF,
                 BASE + 0x40, BASE + SIZE - 8);
        assert(lines == 1);
        if (strcmp(last, want)) { fprintf(stderr, "got  %swant %s", last, want); return 1; }
        return 0;
    }
    if (!strcmp(argv[1], "more")) {           /* all 103 refs in the view: what one line cannot hold is counted */
        unsigned i, shown = 0;
        const char *p;
        setup(-1);
        for (i = 0; i < 50 + PPE_REFS; i++) ios_proc_end_refs[i] = BASE + 0x100000 * i;
        ios_proc_end_log_keep_ref((void *)0x1234, BASE, 0x100000ull * (50 + PPE_REFS), PPE_KEEP_REF, 2);
        assert(lines == 1 && strlen(last) < 2048);
        for (p = last; (p = strstr(p, " ref#")); p++) shown++;
        snprintf(want, sizeof want, " +%u more (PLA-476)\n", 50 + PPE_REFS - shown);
        assert(shown > 40 && shown < 50 + PPE_REFS);
        assert(!strcmp(last + strlen(last) - strlen(want), want));
        assert(strstr(last, " tid=0020 ref#0/50=0x7a00000000 tid=0020 ref#1/50=0x7a00100000 "));
        return 0;
    }
    if (!strcmp(argv[1], "none")) {           /* a slot view no ref lies in, freed anyway */
        ios_proc_end_log_keep_ref((void *)0x1234, BASE, SIZE, PPE_FREE, setup(-1));
        snprintf(want, sizeof want, "[proc-end] slot-view peb=%p view=%p+0x%llx fate=%d no parked ref (PLA-476)\n",
                 (void *)0x1234, (void *)(uintptr_t)BASE, SIZE, PPE_FREE);
        assert(lines == 1 && !strcmp(last, want));
        return 0;
    }
    index = atoi(argv[1]);                    /* the parked ref at index lies in the kept view */
    ios_proc_end_log_keep_ref((void *)0x1234, BASE, SIZE, PPE_KEEP_REF, setup(index));
    snprintf(want, sizeof want, "[proc-end] keep-ref peb=%p view=%p+0x%llx fate=%d tid=0044 ref#%d/%d=0x%llx (PLA-476)\n",
             (void *)0x1234, (void *)(uintptr_t)BASE, SIZE, PPE_KEEP_REF, index, PPE_REFS, BASE + SIZE - 8);
    assert(lines == 1);
    if (strcmp(last, want)) { fprintf(stderr, "got  %swant %s", last, want); return 1; }
    return 0;
}
'''


class ProcEndKeepRefTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which("cc")
        assert cc, "no C compiler"
        scratch = ROOT / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        cls.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR", scratch))
        d = pathlib.Path(cls.tmp.name)
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        for name in PROC_END_PATCHES:
            subprocess.run(["git", "apply", f"--include={HEADER}", str(SERIES / name)], cwd=d, check=True)
        (d / "logger.c").write_text(logger_source())
        (d / "test.c").write_text(TEST_C)
        subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
                        "-I", str(d / "build/ntdll-unix"), str(d / "test.c"), "-o", str(d / "test")], check=True)
        cls.binary = str(d / "test")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_case(self, name):
        done = subprocess.run([self.binary, name], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_documented_order_is_ppe_refs(self):
        source = logger_source()
        self.assertEqual(len(REF_NAMES), 53)
        for words in ("0-28 x0-x28, 29 fp, 30 lr,", "31 sp, 32 pc", "33-49", "TPIDRRO_EL0 (when thread_info succeeds)",
                      "its TEB", "wait address"):
            self.assertIn(words, " ".join(source.replace("\n * ", " ").split()))

    def test_names_the_register(self):
        for name in ("x0", "x5", "x28", "fp", "lr", "sp", "pc", "rax", "rsp", "r15", "rip",
                     "tpidrro_el0", "teb", "wait"):
            with self.subTest(register=name):
                self.run_case(str(REF_NAMES.index(name)))

    def test_names_every_ref_of_every_thread(self):
        self.run_case("every")

    def test_counts_what_a_line_cannot_hold(self):
        self.run_case("more")

    def test_slot_view_without_ref(self):
        self.run_case("none")

    def test_capped_at_64(self):
        self.run_case("cap")

    def test_quiet_without_diagnostics(self):
        self.run_case("quiet")


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the rules for ending a terminated pseudo-process, shipped in madeira-unix 0169 (PLA-416)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-unix/0169-ntdll-wineserver-tear-down-a-pseudo-process-another-.patch"


def added_header():
    text = PATCH.read_text()
    section = text.split("diff --git a/build/ntdll-unix/pp_proc_end.h", 1)[1]
    section = section.split("diff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++")) + "\n"


TEST_C = r'''
#include "pp_proc_end.h"
#include <assert.h>
#include <string.h>

/* A thread of a process being terminated, blocked in NtWaitForAlertByThreadId's futex wait, holding nothing. */
static struct ppe_thread_state idle(void) {
    struct ppe_thread_state s;
    memset(&s, 0, sizeof s);
    s.process_ending = 1;
    s.readable = 1;
    s.in_alert_wait = 1;
    s.insn_before_pc = PPE_SVC_0X80;
    s.x16 = PPE_SYS_ULOCK_WAIT;
    s.x0 = 0x01000000 | PPE_UL_COMPARE_AND_WAIT;   /* ULF_NO_ERRNO and the operation */
    return s;
}

int main(void) {
    struct ppe_thread_state s;

    /* Parking: only a provably idle thread in the wait. */
    s = idle(); assert(ppe_may_park(&s) == PPE_PARK);
    s = idle(); s.x16 = PPE_SYS_ULOCK_WAIT2; assert(ppe_may_park(&s) == PPE_PARK);   /* os_sync_wait_on_address */
    s = idle(); s.process_ending = 0; assert(ppe_may_park(&s) == PPE_NOT_ENDING);
    s = idle(); s.in_alert_wait = 0; assert(ppe_may_park(&s) == PPE_NOT_ALERT_WAIT);
    s = idle(); s.wow64_wait = 1; assert(ppe_may_park(&s) == PPE_WOW64_WAIT);
    s = idle(); s.killed_in_wait = 1; assert(ppe_may_park(&s) == PPE_WOW64_WAIT);
    s = idle(); s.readable = 0; assert(ppe_may_park(&s) == PPE_UNREAD);
    s = idle(); s.insn_before_pc = 0xd503201f; assert(ppe_may_park(&s) == PPE_NOT_BLOCKED);   /* nop: running */
    s = idle(); s.x16 = 301; assert(ppe_may_park(&s) == PPE_NOT_BLOCKED);                    /* psynch_mutexwait */
    s = idle(); s.x0 = 2; assert(ppe_may_park(&s) == PPE_NOT_BLOCKED);                       /* UL_UNFAIR_LOCK */
    s = idle(); s.fex_stamps = 1; assert(ppe_may_park(&s) == PPE_FEX_LOCK);
    s = idle(); s.in_syscall_callback = 1; assert(ppe_may_park(&s) == PPE_FEX_LOCK);
    s = idle(); s.host_sections = 1; assert(ppe_may_park(&s) == PPE_HOST_LOCK);
    s = idle(); s.owns_loader_lock = 1; assert(ppe_may_park(&s) == PPE_LOADER_LOCK);
    /* A refusal in the wait is logged; one outside it goes the old way silently. */
    assert(ppe_refusal_logged(PPE_HOST_LOCK) && ppe_refusal_logged(PPE_NOT_BLOCKED) && ppe_refusal_logged(PPE_UNREAD));
    assert(!ppe_refusal_logged(PPE_NOT_ENDING) && !ppe_refusal_logged(PPE_NOT_ALERT_WAIT) &&
           !ppe_refusal_logged(PPE_WOW64_WAIT) && !ppe_refusal_logged(PPE_PARK));
    assert(!strcmp(ppe_park_name(PPE_LOADER_LOCK), "holds the loader lock"));

    /* The teardown waits for every thread: finished or parked, none live. */
    struct ppe_census c = { 0, 0, 0 };
    assert(ppe_all_ended(&c));
    c.finished = 17; c.parked = 11; assert(ppe_all_ended(&c));
    c.live = 1; assert(!ppe_all_ended(&c));

    /* What goes: with nothing parked, all of FEX's band too; with a thread parked, of the band only
     * the L1 caches, and no view a parked thread's registers point into. */
    const uint64_t refs[] = { 0x7c00000123ull, 0x7300004000ull };
    assert(ppe_release_view(PPE_IMAGE, 0, 0x7300000000ull, 0x10000, refs, 2));
    assert(ppe_release_view(PPE_SPAN, 0, 0x7c00000000ull, 0x100000, refs, 2));
    assert(ppe_release_view(PPE_CALLRET, 0, 0x7d00000000ull, 0x408000, refs, 2));
    assert(ppe_release_view(PPE_PRIVATE, 1, 0x7200000000ull, 0x10000, refs, 2));
    assert(!ppe_release_view(PPE_PRIVATE, 1, 0x7300000000ull, 0x10000, refs, 2));   /* x1 points into it */
    assert(!ppe_release_view(PPE_SPAN, 1, 0x7c10000000ull, 0x100000, refs, 2));
    assert(!ppe_release_view(PPE_CALLRET, 1, 0x7d00000000ull, 0x408000, refs, 2));
    assert(!ppe_release_view(PPE_BAND_OTHER, 1, 0x7d10000000ull, 0x10000, refs, 2));
    assert(ppe_release_view(PPE_L1, 1, 0x7e00000000ull, 0x200000, refs, 2));
    assert(!ppe_release_view(PPE_L1, 1, 0x7c00000000ull, 0x200000, refs, 2));       /* referenced */
    assert(ppe_referenced(0x1000, 0x1000, (const uint64_t[]){ 0x1fff }, 1));
    assert(!ppe_referenced(0x1000, 0x1000, (const uint64_t[]){ 0x2000 }, 1));
    assert(!ppe_referenced(0x1000, 0x1000, (const uint64_t[]){ 0xfff }, 1));

    /* Idempotence: a process reported twice has one entry, and is taken for its teardown once. */
    static struct ppe_gone gone[PPE_GONE_MAX];
    static char pebs[PPE_GONE_MAX + 1];
    int i = ppe_gone_add(gone, &pebs[0], 0x284);
    assert(i >= 0 && ppe_gone_add(gone, &pebs[0], 0x284) == i && gone[i].pid == 0x284);
    assert(ppe_gone_take(gone, i, &pebs[0]));
    assert(!ppe_gone_take(gone, i, &pebs[0]));
    assert(!gone[i].peb);
    assert(!ppe_gone_take(gone, i, &pebs[1]));
    for (i = 0; i < PPE_GONE_MAX; i++) assert(ppe_gone_add(gone, &pebs[i], (unsigned)i) >= 0);
    assert(ppe_gone_add(gone, &pebs[PPE_GONE_MAX], 1) < 0);

    /* The line. */
    char row[320];
    unsigned long long freed[PPE_CLASSES] = { 251ull << 20, 120ull << 20, 300ull << 20, 72ull << 20, 36ull << 20, 5ull << 20 };
    struct ppe_census done = { 0, 37, 11 };
    ppe_row(row, sizeof row, (void *)0x1533f8000ull, 0x284, freed, 48ull << 20, 90ull << 20, &done);
    assert(!strcmp(row, "peb=0x1533f8000 pid=0284 killed: freed image=251 private=120 spans=300 callret=72 l1=36 "
                        "band_other=5 pool=48 MB, kept 90 MB; 37 finished, 11 parked thread(s)"));
    return 0;
}
'''


class ProcessEndTests(unittest.TestCase):
    def test_shipped_header(self):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            (d / "pp_proc_end.h").write_text(added_header())
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)


if __name__ == "__main__":
    unittest.main()

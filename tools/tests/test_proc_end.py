# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the rules for ending a terminated pseudo-process: madeira-unix 0169 (PLA-416), 0172,
which empties a parked process's FEX band views in place (decision 0132), and 0203, which gives a child that exits by
itself the same rules for its views, FEX's band included (decision 0143, PLA-413)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERIES = ROOT / "patches/madeira-unix"
PATCHES = ("0169-ntdll-wineserver-tear-down-a-pseudo-process-another-.patch",
           "0172-ntdll-empty-a-killed-process-s-FEX-band-views-in-pla.patch",
           "0203-ntdll-release-a-self-exited-child-s-FEX-band-views-a.patch")
HEADER = "build/ntdll-unix/pp_proc_end.h"


def shipped_header(directory):
    """pp_proc_end.h as the series leaves it: 0169 adds it, 0172 and 0203 change it."""
    subprocess.run(["git", "init", "-q", str(directory)], check=True)
    for name in PATCHES:
        subprocess.run(["git", "apply", f"--include={HEADER}", str(SERIES / name)], cwd=directory, check=True)
    return directory / HEADER


TEST_C = r'''
#include "pp_proc_end.h"
#include <assert.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

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

    /* What goes: with nothing parked, all of FEX's band too; with a thread parked, of the band the L1 caches go
     * and the rest is emptied in place, and no view a parked thread's saved address lies in changes (0132). */
    const uint64_t refs[] = { 0x7c00000123ull, 0x7300004000ull };
    assert(ppe_view_fate(PPE_IMAGE, 0, 0x7300000000ull, 0x10000, refs, 2) == PPE_FREE);
    assert(ppe_view_fate(PPE_SPAN, 0, 0x7c00000000ull, 0x100000, refs, 2) == PPE_FREE);
    assert(ppe_view_fate(PPE_CALLRET, 0, 0x7d00000000ull, 0x408000, refs, 2) == PPE_FREE);
    assert(ppe_view_fate(PPE_PRIVATE, 1, 0x7200000000ull, 0x10000, refs, 2) == PPE_FREE);
    assert(ppe_view_fate(PPE_PRIVATE, 1, 0x7300000000ull, 0x10000, refs, 2) == PPE_KEEP_REF);   /* x1 points into it */
    assert(ppe_view_fate(PPE_SPAN, 1, 0x7c10000000ull, 0x100000, refs, 2) == PPE_EMPTY);
    assert(ppe_view_fate(PPE_CALLRET, 1, 0x7d00000000ull, 0x408000, refs, 2) == PPE_EMPTY);
    assert(ppe_view_fate(PPE_BAND_OTHER, 1, 0x7d10000000ull, 0x10000, refs, 2) == PPE_EMPTY);
    assert(ppe_view_fate(PPE_L1, 1, 0x7e00000000ull, 0x200000, refs, 2) == PPE_FREE);
    assert(ppe_view_fate(PPE_SPAN, 1, 0x7c00000000ull, 0x100000, refs, 2) == PPE_KEEP_REF);    /* referenced */
    assert(ppe_view_fate(PPE_L1, 1, 0x7c00000000ull, 0x200000, refs, 2) == PPE_KEEP_REF);
    assert(PPE_REFS == 53);   /* x0-x28, fp, lr, sp, pc, 17 guest, TPIDRRO_EL0, TEB, wait address */
    assert(ppe_referenced(0x1000, 0x1000, (const uint64_t[]){ 0x1fff }, 1));
    assert(!ppe_referenced(0x1000, 0x1000, (const uint64_t[]){ 0x2000 }, 1));
    assert(!ppe_referenced(0x1000, 0x1000, (const uint64_t[]){ 0xfff }, 1));

    /* Which views of a dead process (killed, or exited by itself since 0203) the fate above decides for. In FEX's
     * band, every view it allocated, its L1 caches, spans and call-return stacks among them, which 0154 kept for a
     * self-exit; a section there stays. Outside it, 0154's: private memory and images, not other sections, and
     * nothing in the JIT pool or a WoW64 window. Never a VPROT_SYSTEM view. */
    assert(ppe_view_released(0, 1, 1, 0, 0));
    assert(!ppe_view_released(0, 1, 0, 0, 0));    /* a section in the band */
    assert(!ppe_view_released(1, 1, 1, 0, 0));    /* VPROT_SYSTEM */
    assert(ppe_view_released(0, 0, 1, 0, 0));     /* private memory */
    assert(ppe_view_released(0, 0, 0, 1, 0));     /* an image */
    assert(!ppe_view_released(0, 0, 0, 0, 0));    /* another section: shared memory a live process may hold */
    assert(!ppe_view_released(0, 0, 1, 0, 1));    /* the JIT pool or a WoW64 window */
    assert(!ppe_view_released(1, 0, 1, 0, 0));

    /* Only whole host pages of a committed run are replaced. */
    uint64_t lo, hi;
    assert(ppe_host_pages(0x7c00001000ull, 0x8000, 0x3fff, &lo, &hi) && lo == 0x7c00004000ull && hi == 0x7c00008000ull);
    assert(ppe_host_pages(0x7c00000000ull, 0x100000, 0x3fff, &lo, &hi) && lo == 0x7c00000000ull && hi == 0x7c00100000ull);
    assert(!ppe_host_pages(0x7c00001000ull, 0x2000, 0x3fff, &lo, &hi));
    assert(!ppe_host_pages(0x7c00003000ull, 0x2000, 0x3fff, &lo, &hi));

    /* Emptying in place, as ios_proc_end_empty_view_locked maps over: the range stays mapped at its protection and
     * reads zero, so a late reader ([waiters], [census-hold]) or a late lock reap neither faults nor sees old data;
     * and a view is taken once, so a second teardown leaves it alone. */
    {
        size_t page = (size_t)sysconf(_SC_PAGESIZE), size = 4 * page;
        unsigned char *view = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        int peb_a, peb_b;
        void *owner = &peb_a;
        assert(view != MAP_FAILED);
        memset(view, 0xa5, size);
        assert(ppe_host_pages((uintptr_t)view, size, page - 1, &lo, &hi) && hi - lo == size);
        assert(ppe_take_view(&owner, &peb_a) && owner == NULL);
        assert(mmap((void *)(uintptr_t)lo, hi - lo, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                    -1, 0) == (void *)(uintptr_t)lo);
        for (size_t k = 0; k < size; k += 512) assert(view[k] == 0);
        __atomic_compare_exchange_n((int *)(view + 64), &(int){ 0 }, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED);
        assert(*(int *)(view + 64) == 1);
        assert(!ppe_take_view(&owner, &peb_a));   /* a second teardown of the same process */
        assert(!ppe_take_view(&owner, &peb_b));   /* or another process's walk */
        assert(!ppe_take_view(&owner, NULL));
        munmap(view, size);
    }

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
    char row[400];
    struct ppe_result r = { { 251ull << 20, 120ull << 20, 0, 0, 36ull << 20, 0 }, 48ull << 20, 700ull << 20,
                            790ull << 20, 9, 8140ull << 20, 7350ull << 20 };
    struct ppe_census done = { 0, 37, 11 };
    ppe_row(row, sizeof row, (void *)0x1533f8000ull, 0x284, &r, &done);
    assert(!strcmp(row, "peb=0x1533f8000 pid=0284 killed: freed image=251 private=120 spans=0 callret=0 l1=36 "
                        "band_other=0 pool=48 MB, emptied=700 MB, kept 790 MB (9 view(s) a parked register points "
                        "into); 37 finished, 11 parked thread(s); footprint 8140->7350 MB"));

    /* A renderer that ended itself (f2's pid 0334): with nothing parked its band goes, as a killed one's. */
    struct ppe_result x = { { 0, 3056ull << 20, 420ull << 20, 66ull << 20, 160ull << 20, 34ull << 20 }, 0, 0,
                            4ull << 20, 0, 7100ull << 20, 6780ull << 20 };
    struct ppe_census exited = { 0, 18, 0 };
    assert(ppe_view_fate(PPE_SPAN, exited.parked, 0x7c10000000ull, 0x100000, refs, 2) == PPE_FREE);
    ppe_exit_row(row, sizeof row, (void *)0x14b4a4000ull, &x, &exited);
    assert(!strcmp(row, "peb=0x14b4a4000 exited: freed image=0 private=3056 spans=420 callret=66 l1=160 "
                        "band_other=34 MB, emptied=0 MB, kept 4 MB (0 view(s) a parked register points into); "
                        "18 finished, 0 parked thread(s); footprint 7100->6780 MB"));
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
            header = shipped_header(d)
            (d / "test.c").write_text(TEST_C)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I", str(header.parent), "-o",
                            str(d / "t"), str(d / "test.c")], check=True)
            subprocess.run([str(d / "t")], check=True)


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile and exercise the rules for ending a terminated pseudo-process: madeira-unix 0169 (PLA-416), 0172,
which empties a parked process's FEX band views in place (decision 0132), 0203, which gives a child that exits by
itself the same rules for its views, FEX's band included (decision 0143, PLA-413), and 0229 with wine-unix 0202,
which detach a parked thread's alert wait and free a view only it named (decision 0166, PLA-476), and 0230, which
counts finished teardowns for the dev host's post-teardown `[proc-mem]` sample (PLA-476)."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERIES = ROOT / "patches/madeira-unix"
PATCHES = ("0169-ntdll-wineserver-tear-down-a-pseudo-process-another-.patch",
           "0172-ntdll-empty-a-killed-process-s-FEX-band-views-in-pla.patch",
           "0203-ntdll-release-a-self-exited-child-s-FEX-band-views-a.patch",
           "0229-ntdll-detach-a-parked-thread-s-alert-wait-then-free-a-view.patch")
HEADER = "build/ntdll-unix/pp_proc_end.h"
DETACH_PATCH = ROOT / "patches/wine-unix/0202-ntdll-detach-a-parked-thread-s-alert-wait-from-the-shared-queue.patch"


def detach_source():
    """wine-unix 0202's one hunk in unix sync.c: ios_futex_unlink_tid and ios_detach_parked_wait."""
    hunk = DETACH_PATCH.read_text().split("\n@@ ", 1)[1].split("\n-- \n", 1)[0]
    return "\n".join(line[1:] for line in hunk.splitlines() if line.startswith("+")) + "\n"


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
        int peb_a = 0, peb_b = 0;
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


# Decision 0166: the wait-detach rules of pp_proc_end.h, and wine-unix 0202's unlink over a mock shared queue and
# waiter registry with Wine's types and interlocked calls.
WAIT_C = r"""
#include "pp_proc_end.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

typedef int LONG;
typedef uintptr_t ULONG_PTR;
#define IOS_ALERT_WAITER_MAX 4
struct ios_shared_futex_queue { void *next, *prev; LONG lock; };
static struct ios_shared_futex_queue ios_shared_futex_queues[256];
static struct { void *tid; const void *addr; unsigned long long since; int inf; } ios_alert_waiters[IOS_ALERT_WAITER_MAX];
static int sleeps;
static LONG InterlockedCompareExchange( LONG *dst, LONG xchg, LONG cmp )
{ return __sync_val_compare_and_swap( dst, cmp, xchg ); }
static LONG InterlockedExchange( LONG *dst, LONG value ) { return __atomic_exchange_n( dst, value, __ATOMIC_SEQ_CST ); }
static void *InterlockedCompareExchangePointer( void **dst, void *xchg, void *cmp )
{ return __sync_val_compare_and_swap( dst, cmp, xchg ); }
static int test_usleep( unsigned us ) { (void)us; sleeps++; return 0; }
#define usleep test_usleep
#include "detach.c"

#define BASE 0x7400000000ull
#define SIZE 0x190000000ull
#define WAIT 0x74000643e0ull

/* A parked thread with its whole saved set, none of it in [BASE, BASE + SIZE) but its wait address. */
static struct ppe_parked full(int in_view)
{
    struct ppe_parked t;
    unsigned i;
    memset(&t, 0, sizeof t);
    t.nrefs = PPE_REFS;
    for (i = 0; i < PPE_REFS; i++) t.refs[i] = 0x13ef00000ull + 0x1000 * i;
    t.refs[PPE_WAIT_REF] = in_view ? WAIT : 0x70334dc938ull;
    t.ready = 1;
    return t;
}

/* The fate the release gives [BASE, BASE + SIZE) for the dead process's parked threads all[0..n), of the
 * nall in the table, after its teardown detached each detachable wait (or found the bucket busy), as
 * ios_proc_end_release_views_locked does. */
static enum ppe_fate release(struct ppe_parked *all, unsigned n, unsigned nall, int busy)
{
    uint64_t refs[8 * PPE_REFS], dropped[8];
    unsigned i, nrefs = 0, ndropped = 0;
    enum ppe_fate fate;
    for (i = 0; i < n; i++)
        if (ppe_wait_detachable(&all[i]))
            all[i].wait_detach = ppe_wait_detach_result(busy ? PPE_NODE_BUSY : PPE_NODE_UNLINKED);
    for (i = 0; i < n; i++) {
        if (ppe_drop_wait(&all[i], &dropped[ndropped])) ndropped++;
        memcpy(refs + nrefs, all[i].refs, all[i].nrefs * sizeof(uint64_t));
        nrefs += all[i].nrefs;
    }
    fate = ppe_view_fate(PPE_PRIVATE, n, BASE, SIZE, refs, nrefs);
    if (fate != PPE_KEEP_REF && ndropped && ppe_referenced(BASE, SIZE, dropped, ndropped))
        fate = ppe_fate_after_detach(fate, BASE, SIZE, dropped, ndropped, all, nall);
    return fate;
}

struct node { struct node *next, *prev; const void *addr; unsigned int tid; };

/* The bucket of addr, as RtlWaitOnAddress leaves it: list_init on the first wait, nodes added at the tail. */
static struct ios_shared_futex_queue *bucket(const void *addr)
{
    return &ios_shared_futex_queues[(((ULONG_PTR)addr) >> 4) % 256];
}
static void enqueue(struct node *e, const void *addr, unsigned int tid)
{
    struct ios_shared_futex_queue *q = bucket(addr);
    struct node *head = (struct node *)q;
    if (!q->next) q->next = q->prev = q;
    e->addr = addr; e->tid = tid;
    e->next = head; e->prev = head->prev;
    head->prev->next = e; head->prev = e;
}
static unsigned queued(const void *addr)
{
    struct node *head = (struct node *)bucket(addr), *e;
    unsigned n = 0;
    for (e = head->next; e != head; e = e->next) n++;
    return n;
}

int main(void)
{
    struct ppe_parked all[4];
    enum ppe_fate fate;
    char row[128];

    assert(PPE_WAIT_REF == 52);

    /* Only the wait names the view: freed, as a view no parked address names (in a slot, outside the band). */
    all[0] = full(1);
    assert(release(all, 1, 1, 0) == PPE_FREE);
    assert(all[0].refs[PPE_WAIT_REF] == 0 && all[0].wait_detach == PPE_WAIT_DETACHED);
    /* Its own other waiting threads' waits elsewhere are detached too; a second process's thread names nothing. */
    all[0] = full(1); all[1] = full(0); all[2] = full(0);
    assert(release(all, 2, 3, 0) == PPE_FREE && all[1].wait_detach == PPE_WAIT_DETACHED && !all[1].refs[PPE_WAIT_REF]);
    assert(all[2].wait_detach == PPE_WAIT_QUEUED && all[2].refs[PPE_WAIT_REF]);
    /* A band view only the wait names takes the no-parked fate: freed, not emptied, whatever its class. */
    {
        struct ppe_parked u = full(1);
        uint64_t dropped;
        u.wait_detach = PPE_WAIT_DETACHED;
        assert(ppe_drop_wait(&u, &dropped) && dropped == WAIT);
        for (int cls = PPE_SPAN; cls < PPE_CLASSES; cls++) {
            fate = ppe_view_fate((enum ppe_class)cls, 1, BASE, SIZE, u.refs, u.nrefs);
            assert(ppe_fate_after_detach(fate, BASE, SIZE, &dropped, 1, &u, 1) ==
                   ppe_view_fate((enum ppe_class)cls, 0, BASE, SIZE, u.refs, u.nrefs));
            assert(ppe_fate_after_detach(fate, BASE, SIZE, &dropped, 1, &u, 1) == PPE_FREE);
        }
        assert(!ppe_drop_wait(&u, &dropped));                       /* dropped once */
    }

    /* Wait-only is false for: ref 51 (the TEB) or 31 (sp) in the view too. */
    all[0] = full(1); all[0].refs[51] = BASE + 0x1000;
    assert(release(all, 1, 1, 0) == PPE_KEEP_REF);
    all[0] = full(1); all[0].refs[31] = BASE + SIZE - 8;
    assert(release(all, 1, 1, 0) == PPE_KEEP_REF);
    /* A saved set of 52 (thread_info failed): index 51 is its wait, never detached. */
    all[0] = full(1); all[0].nrefs = 52; all[0].refs[51] = WAIT;
    assert(!ppe_wait_detachable(&all[0]));
    assert(release(all, 1, 1, 0) == PPE_KEEP_REF && all[0].wait_detach == PPE_WAIT_QUEUED && all[0].refs[51] == WAIT);
    /* Two threads: one waits in the view, the other's x15 lies in it. */
    all[0] = full(1); all[1] = full(0); all[1].refs[15] = BASE + 0x4000;
    assert(release(all, 2, 2, 0) == PPE_KEEP_REF);
    /* A later thread, of another process, parked after these, names the view (the whole table, exactly). */
    all[0] = full(1); all[1] = full(0); all[1].refs[7] = BASE + 0x8000;
    assert(release(all, 1, 2, 0) == PPE_KEEP_REF);
    all[0] = full(1); all[1] = full(0); all[1].refs[PPE_WAIT_REF] = WAIT + 0x40;   /* its wait, not detached */
    assert(release(all, 1, 2, 0) == PPE_KEEP_REF);
    all[0] = full(1); all[1] = full(0);
    assert(release(all, 1, 2, 0) == PPE_FREE);
    /* One being written names every view. */
    all[0] = full(1); all[1] = full(0); all[1].ready = 0;
    assert(release(all, 1, 2, 0) == PPE_KEEP_REF);
    /* A busy bucket keeps the wait and the view as before. */
    all[0] = full(1);
    assert(release(all, 1, 1, 1) == PPE_KEEP_REF);
    assert(all[0].wait_detach == PPE_WAIT_KEPT && all[0].refs[PPE_WAIT_REF] == WAIT && !ppe_wait_detachable(&all[0]));
    /* Claimed by another teardown and not finished: not dropped, kept. */
    all[0] = full(1); all[0].wait_detach = PPE_WAIT_DETACHING;
    assert(!ppe_wait_detachable(&all[0]) && release(all, 1, 1, 0) == PPE_KEEP_REF);

    /* Negative: a view any non-wait ref names keeps today's fate whatever was dropped, and a view no dropped wait
     * names keeps today's fate whatever the global table holds. */
    {
        uint64_t refs[2] = { BASE + 0x10, WAIT }, dropped = WAIT;
        struct ppe_parked other = full(0);
        other.refs[3] = 0x7c10000010ull;
        for (int cls = 0; cls < PPE_CLASSES; cls++)
            for (unsigned parked = 0; parked < 2; parked++) {
                fate = ppe_view_fate((enum ppe_class)cls, parked, BASE, SIZE, refs, 1);
                assert(ppe_fate_after_detach(fate, BASE, SIZE, &dropped, 1, &other, 1) == fate);
                fate = ppe_view_fate((enum ppe_class)cls, parked, 0x7c10000000ull, 0x100000, refs, 2);
                assert(ppe_fate_after_detach(fate, 0x7c10000000ull, 0x100000, &dropped, 1, &other, 1) == fate);
            }
    }

    /* The line. */
    ppe_wait_detached_row(row, sizeof row, 0x208, WAIT, PPE_NODE_UNLINKED);
    assert(!strcmp(row, "[proc-end] wait-detached tid=0208 wait=0x74000643e0 node=unlinked"));
    ppe_wait_detached_row(row, sizeof row, 0x1a0, 0x70334dc938ull, PPE_NODE_ABSENT);
    assert(!strcmp(row, "[proc-end] wait-detached tid=01a0 wait=0x70334dc938 node=absent"));
    ppe_wait_detached_row(row, sizeof row, 0x210, WAIT, PPE_NODE_BUSY);
    assert(!strcmp(row, "[proc-end] wait-detached tid=0210 wait=0x74000643e0 node=busy"));

    /* wine-unix 0202 over a mock bucket: the parked thread's node lies on its stack. */
    {
        static struct node stack[16], live[4];   /* the parked thread's stack; a live thread's */
        const ULONG_PTR lo = (ULONG_PTR)stack, hi = (ULONG_PTR)(stack + 16);
        const void *w = (const void *)(ULONG_PTR)WAIT, *other = (const void *)(ULONG_PTR)(WAIT + 0x1000);

        /* An empty, never initialised bucket: nothing queued. */
        assert(!bucket(w)->next);
        assert(ios_detach_parked_wait(0x208, w, lo, hi) == PPE_NODE_ABSENT);
        assert(!bucket(w)->next && !bucket(w)->lock);

        /* The parked node goes, a same-address node of another tid stays, and so do other addresses' nodes. */
        enqueue(&live[0], w, 0x300);
        enqueue(&stack[3], w, 0x208);
        enqueue(&live[1], other, 0x208);
        enqueue(&live[2], w, 0x301);
        ios_alert_waiters[1].tid = (void *)(ULONG_PTR)0x208; ios_alert_waiters[1].addr = w;
        ios_alert_waiters[2].tid = (void *)(ULONG_PTR)0x300; ios_alert_waiters[2].addr = w;
        assert(queued(w) == 4);
        assert(ios_detach_parked_wait(0x208, w, lo, hi) == PPE_NODE_UNLINKED);
        assert(queued(w) == 3 && stack[3].addr == NULL);
        assert(live[0].addr == w && live[1].addr == other && live[2].addr == w);
        assert(live[0].next == &live[1] && live[1].prev == &live[0]);
        assert(ios_alert_waiters[1].addr == NULL && ios_alert_waiters[2].addr == w);
        assert(!bucket(w)->lock);
        /* Again: the node is gone. */
        assert(ios_detach_parked_wait(0x208, w, lo, hi) == PPE_NODE_ABSENT && queued(w) == 3);

        /* The registry CAS leaves a recycled tid's entry waiting on another address. */
        ios_alert_waiters[1].addr = other;
        assert(ios_detach_parked_wait(0x208, w, lo, hi) == PPE_NODE_ABSENT);
        assert(ios_alert_waiters[1].addr == other);

        /* A node for (addr, tid) off the parked thread's stack is a recycled tid's: busy, nothing changes. */
        enqueue(&live[3], w, 0x208);
        enqueue(&stack[5], w, 0x208);
        ios_alert_waiters[1].addr = w;
        assert(ios_detach_parked_wait(0x208, w, lo, hi) == PPE_NODE_BUSY);
        assert(queued(w) == 5 && live[3].addr == w && stack[5].addr == w && ios_alert_waiters[1].addr == w);
        assert(!bucket(w)->lock);

        /* A lock another holder keeps: bounded tries, busy, nothing changes; the view stays kept. */
        sleeps = 0;
        bucket(w)->lock = -1;
        assert(ios_detach_parked_wait(0x208, w, lo, (ULONG_PTR)-1) == PPE_NODE_BUSY);
        assert(sleeps == IOS_DETACH_LOCK_TRIES && bucket(w)->lock == -1 && queued(w) == 5);
        assert(ios_alert_waiters[1].addr == w);
        all[0] = full(1);
        assert(release(all, 1, 1, 1) == PPE_KEEP_REF);
        bucket(w)->lock = 0;
    }
    return 0;
}
"""


class ProcessEndTests(unittest.TestCase):
    def compile_and_run(self, source, extra=None):
        cc = shutil.which("cc")
        self.assertIsNotNone(cc)
        scratch = ROOT / ".work" / "tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            d = pathlib.Path(td)
            header = shipped_header(d)
            for name, text in (extra or {}).items():
                (d / name).write_text(text)
            (d / "test.c").write_text(source)
            subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined",
                            "-I", str(header.parent), "-I", str(d), "-o", str(d / "t"), str(d / "test.c")],
                           check=True)
            subprocess.run([str(d / "t")], check=True)

    def test_shipped_header(self):
        self.compile_and_run(TEST_C)

    def test_wait_detach(self):
        """Decision 0166: which views a detached wait frees, the line, and wine-unix 0202's unlink."""
        self.compile_and_run(WAIT_C, {"detach.c": detach_source()})

    def test_detach_is_outside_virtual_mutex(self):
        """0229 detaches before the killed teardown and the self-exit release take virtual_mutex, and resumes
        nothing (the parked threads stay suspended, decisions 0127 and 0166)."""
        lines = (SERIES / PATCHES[-1]).read_text().splitlines()
        after = "\n".join(line[1:] for line in lines if line[:1] in " +" and not line.startswith("+++"))
        added = "\n".join(line[1:] for line in lines if line.startswith("+") and not line.startswith("+++"))
        self.assertIn("ios_proc_end_detach_waits( peb );   /* decision 0166 */\n"
                      "        server_enter_uninterrupted_section( &virtual_mutex, &sigset );", after)
        self.assertIn("if (peb && peb != self) ios_proc_end_detach_waits( peb );   /* decision 0166 */", added)
        self.assertIn("server_leave_uninterrupted_section( &virtual_mutex, &sigset );\n"
                      "        for (i = 0; i < n; i++)\n        {\n            int node = ios_detach_parked_wait(", added)
        self.assertNotIn("thread_resume", added)

    def test_teardown_count_follows_each_teardown_line(self):
        """madeira-unix 0230 (PLA-476): each finished teardown, killed or self-exited, counts after its line; the
        dev host forces a `[proc-mem]` walk when the count moves, on its own thread and never in a release build."""
        lines = next(SERIES.glob("0230-*.patch")).read_text().splitlines()
        after = "\n".join(line[1:] for line in lines if line[:1] in " +" and not line.startswith("+++"))
        bump = "        __atomic_add_fetch( &ios_proc_end_teardown_count, 1, __ATOMIC_RELEASE );"
        self.assertIn('dprintf( 2, "[view-owner] %s (PLA-413)\\n", row );\n    ' + bump.strip(), after)
        self.assertIn('dprintf( 2, "[proc-end] %s (PLA-416)\\n", row );\n' + bump, after)
        self.assertEqual(after.count("__atomic_add_fetch( &ios_proc_end_teardown_count"), 2)
        self.assertIn("unsigned int ios_proc_end_teardowns(void)", after)
        self.assertNotIn("ios_process_memory_log(", after)
        host = (ROOT / "app/Sources/S1Probe/LaunchCoordinator.swift").read_text()
        call = host.index('wine_host_process_memory_log("after teardown')
        self.assertGreater(call, host.rindex("#if !PLAYPORT_RELEASE", 0, call))
        self.assertLess(host.rindex("#if !PLAYPORT_RELEASE", 0, call), host.rindex("let teardowns = wine_host_process_teardowns()", 0, call))
        self.assertNotIn("#endif", host[host.rindex("#if !PLAYPORT_RELEASE", 0, call):call])

if __name__ == "__main__":
    unittest.main()

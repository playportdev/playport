# 0166: A parked thread's alert wait is detached at teardown, and a view only it named is released

**Status:** accepted, 2026-10-30, approved by the owner (PLA-476). Amends
[0127](0127-end-a-terminated-pseudo-process.md), [0132](0132-empty-a-parked-processs-fex-band-in-place.md)
and [0143](0143-release-a-self-exited-childs-fex-band-as-a-killed-childs.md). Shown on the phone in run
`20261030T122917-rdr2-p476l7` (IPA `5b38a50b`): 25 waits detached (24 unlinked, one absent, none busy), the
launcher helper's kind-3 view freed and its slot held again, and the game's helper granted kind 3 with no refusal
([evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l7-wait-detach-decision-0166)). Amended
2026-10-30 by the owner: a band view only a detached wait named is freed, not emptied (IPA `4f5f3b7c`,
Hollow Knight first frame; not yet shown in a teardown on the phone).

## Context

- **One wait address kept a whole Social Club slot.** In the layout runs l5 and l6
  ([l6 evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l6-the-second-metadata-slot)), the
  launcher helper's teardown kept its chrome_elf metadata view (kind 3, `0x7400000000+0x190000000`)
  whole. The only measured reference to it was ref #52 of 53 of one parked thread
  (`CompositorTileWorker1`, tid 0210 in l5 and 0208 in l6, waiting INFINITE at `0x74022290e0` and
  `0x74000643e0`). Ref #52 is that thread's alert-wait address, which 0132 added to the saved set.
  - l5: the game's helper was refused ELF_META, and chrome_elf failed to initialise.
  - l6: with a second metadata slot (madeira-unix 0228), the game's libcef committed at
    `0x7400002000` inside the kept view, was refused, and the game showed Social Club error 17.
  - The same thread, at offset `…3e0`, kept kind 3 in l2, l3 and l4 as well.
- **The wait address is not the host wait.** A parked thread is suspended in `__ulock_wait2` on the
  runtime's per-thread alert word (`futex=0x13ef40204` in l6), outside the guest window. The unix
  `NtWaitForAlertByThreadId` never reads through the guest address. It is a **key**:
  - in the app-wide `RtlWaitOnAddress` queue (`ios_shared_futex_queues`, ml441), through the
    thread's queue node `{list, addr, tid}` on its own stack, which stays linked;
  - in the waiter registry `ios_alert_waiters`, which `[waiters]`, `[census-hold]` and the lock
    reaper read.
- **Freeing the view without detaching would break a live process.** A later helper that puts a
  condition variable at the same address would have its `RtlWakeAddressSingle` find the dead node
  first (FIFO): the wake goes to the dead tid, and its own waiter hangs. A stale registry entry could
  count towards the lock reaper's threshold against someone else's lock word.
- **Never resuming is the real invariant.** 0127 and 0134 leave a parked thread Mach-suspended for
  ever. Its exception registry entry, trampoline slot and JIT ranges are already given back, so a
  resume would be fatal whatever views are kept. Keeping the whole view is not what makes parking
  safe. It only guarded the wait address's role as a key, and an explicit detach removes that role.

## Decision

- **Detach, at each teardown, outside `virtual_mutex`.** This applies to every terminated process
  (0127) and every child that exits by itself (0143). It covers each parked thread of the process whose
  53 saved addresses were all captured (`nrefs == PPE_REFS`). The guest registers are read only when
  its state was readable, and TPIDRRO_EL0 comes before the wait address, so index 52 is its wait address.
  - Take the shared queue's bucket lock for the wait address, trying a bounded number of times
    (200 tries, 50 µs apart). If it stays busy, fail closed: nothing changes and the view is kept
    exactly as before (`node=busy`).
  - Unlink that thread's node for (address, tid) and write the node's `addr` NULL with release
    semantics, as `RtlWakeAddress*` does. Only a node on that thread's own stack is its node. A
    matching node anywhere else belongs to a recycled tid, so nothing changes (`node=busy`). No node
    queued (`node=absent`) is a detach too: a waker took it, or the wait was direct.
  - Compare-and-swap its `ios_alert_waiters` entry's address from the wait address to NULL, only in
    the entry of that tid. A recycled tid's entry waiting elsewhere keeps its own address.
  - Drop ref #52 from its saved set: from the teardown's copy and from the parked table, so a later
    teardown does not count it either.
  - Log `[proc-end] wait-detached tid=%04x wait=0x%llx node=unlinked|absent|busy`.
- **Then the views.** A view of the dead process that only dropped wait addresses named is checked
  against **every** saved address of **every** parked thread of any process, the whole parked table.
  An entry still being written counts as naming every view.
  - If none names it, it takes the fate a process with no parked thread gives it (0127, 0143): it is
    freed, in FEX's band too, not emptied in place (amended by the owner, 2026-10-30). A Social Club
    slot is then held again by the existing `ppsc_owner_died_locked`.
  - Otherwise it is kept whole, as before.
  - Each such view logs `[proc-end] wait-only peb=… view=… fate=N (decision 0166)`.
- **Unchanged.** A view that any register, TPIDRRO or TEB ref names keeps the whole-view rule of
  0127/0132/0143. Parked threads stay Mach-suspended for ever: no new `thread_resume`, and nothing
  moves their host wait. Views kept by earlier teardowns stay as they are. i386 processes keep
  everything.
- **The diagnostic.** madeira-unix 0227's `keep-ref`/`slot-view` line now lists every parked thread's
  every ref in the view, not only the first. It keeps its 64-line cap and is quiet in the release app.

## Costs and risks

- **A freed band view's addresses go back to the band.** 0132 empties a parked process's band views
  so that their addresses stay reserved while its parked FEX state may name them. A view only a
  detached wait named is named by no saved address of any parked thread, and nothing that runs
  reads the rest of that state. FEX keeps no map of the band's free space: rpmalloc and the
  call-return stacks ask `NtAllocateVirtualMemoryEx` for a range inside the band, so Wine's view
  tree is the band's only allocator, and the freed range is a hole it knows. The dead process's
  own rpmalloc heaps, which may still list the range, belong to its own FEX instance, which no
  thread runs any more and into which no other instance frees (0127). A process with no parked
  thread already frees these views the same way.
- **A resume would now corrupt, not read stale data.** If the suspend invariant ever broke and the
  thread got a real alert, its caller would re-read the lock word at the old address, and might CAS
  it, in memory that now belongs to another process. With the view kept it would have read zeros or
  old data. Breaking that invariant is already fatal (0134), and no code path resumes a parked thread.
- **The thread's stack still holds the address** as a value (locals, spills). Nothing reads it.
- **A recycled tid waiting on the same address** keeps its node (the stack check), but its registry
  entry's address may be cleared. That entry is diagnostic, and it is rewritten on its next wait.
- **The teardown thread may wait** up to about 10 ms per busy bucket, outside `virtual_mutex`.
- **A recycled tid shares the parked thread's alert word.** `NtAlertThreadByThreadId` may still
  wake the suspended thread in the kernel instead of the live one. This is unchanged by this
  decision and is a lost wake that only a timeout recovers.

Implemented by madeira-unix 0229 (the teardown, `pp_proc_end.h`) and wine-unix 0202
(`ios_detach_parked_wait` in unix `sync.c`); the rules, the unlink and the lines are tested by
`tools/tests/test_proc_end.py` and `tools/tests/test_proc_end_keep_ref.py`.

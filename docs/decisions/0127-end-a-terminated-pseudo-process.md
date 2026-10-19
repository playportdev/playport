# 0127: A pseudo-process another process terminated is torn down by another process's thread; its stuck waiters are parked

**Status:** accepted, 2026-10-19, approved by the supervisor for the owner (PLA-416). Amends
madeira-unix 0154 (PLA-368), which released only the views of a child that exits by itself. Not
yet shown on the phone.

## Context

- **The run.** In run `20261019T161557` the session root ended the launcher's two
  SocialClubHelper processes at RDR2's first frame. The ending freed nothing
  ([evidence](../evidence/2026-10-19-rdr2-loading-memory.md)):
  - all 18 threads of pid 0x284 ended, but it stayed an `exited` `[proc-mem]` row holding about
    1 GB, and no `[view-owner]` line appeared;
  - pid 0x1b4 kept 11 of its 48 threads.
- **No process exit runs.** A process that exits by itself runs `process_exit_wrapper`. That
  releases its master socket, fd cache, JIT-pool ranges and tail carves, and queues 0154's view
  release. A process killed from outside never runs it. Its threads end through `abort_thread`,
  which calls `abort_process` only when `nb_threads` reaches zero, and that is one count for the
  whole Mach task.
- **FEX's per-thread state stays.** FEX's `ThreadTerm` runs only from the PE side's
  `NtTerminateThread`, which these threads never reach. So each thread's rpmalloc heap, call-return
  stack and L1 cache stay. 0154 keeps every view in FEX's band even for a self-exit.
- **Some threads never end.** A killed thread blocked in an x86-64 program's in-process wait
  (`NtWaitForAlertByThreadId`) never reaches a point the abort can divert it from. Only i386 waits
  are woken to end, and such a thread was retried for a minute, then left running.

## Decision

- **The server reports each ended process.** `finish_process_tracing`, called from
  `process_killed`, reports every ended process to ntdll.
- **Teardown, on another process's thread.** The check runs at each thread creation and
  reclamation, for every reported child that has not exited by itself. Once each of its threads
  has finished or is parked, that thread tears the child down, exactly once:
  - it takes the child's master socket slot atomically, closes it and records a dead child;
  - it releases the fd cache and the JIT-pool ranges;
  - it deletes the views 0154 deletes;
  - it also deletes the views in FEX's band: rpmalloc spans, call-return stacks, L1 caches and the
    rest. They belong to the dead process's own FEX instance, and no thread of that instance runs.
  - It logs one `[proc-end] … killed: freed image= private= spans= callret= l1= band_other= pool=
    MB, kept … MB; N finished, M parked thread(s)` line.
  - It clears the dead TEBs' PEB pointer and `TlsExpansionSlots`, so no later per-process walk
    and no `virtual_clear_tls_index` touches them.
  - The fixed-base main image is not retired: that needs a server call on the process's own
    thread.
- **Parking.** A killed thread of a process that is being terminated as a whole is parked, not
  ended, only when its Mach state and the state the runtime already tracks show both of these:
  - it is blocked in the futex wait of `NtWaitForAlertByThreadId`: `svc #0x80` before its pc,
    `__ulock_wait2` (`os_sync_wait_on_address`, iOS 17.4 and later) or `__ulock_wait` with
    `UL_COMPARE_AND_WAIT`, `in_alert_wait` set, and not an i386 wait;
  - it holds nothing: no FEX lock stamp, no FEX syscall callback, no uninterrupted section or
    tracked host mutex, and not its process's loader lock.

  A parked thread is left Mach-suspended for ever and counts as finished. Each one logs a
  `[proc-end] parked tid=… wait=…` line. Any other thread is refused, logged once as
  `[proc-end] not parked tid=…: <reason>`, and runs on as before.
- **What a parked thread keeps.** It keeps its TEB and its stacks, which are runtime views, and
  every view that one of its saved registers points into: x0-x28, fp, lr, sp and pc, and the
  guest's 16 GPRs and rip. Of its process's band, only the L1 caches go.
- **What does not change.** A process that exits by itself keeps 0154's rules. Parking also
  covers the threads its own `NtTerminateProcess(0)` kills. Its band views
  still stay; that is a follow-up. An i386 child that is killed keeps everything.

## Costs and risks

- **Parked threads stay.** Each parked thread keeps its TEB, stacks, call-return stack and its
  process's rpmalloc spans for the rest of the session.
- **A swallowed wake.** A parked waiter on a lock shared with a live process could swallow a
  wake. Locks of x86-64 pseudo-processes are their own, so this should not happen.
- **Where the teardown runs.** It runs at thread creation and reclamation, on whatever thread is
  there, outside `virtual_mutex`. The JIT-pool reclaim calls every live emulator's alias callback
  from that thread, as an image mapping does.
- **Never torn down.** A killed process with a thread that neither ends nor can be parked is never
  torn down, as before.

Implemented by madeira-unix 0169; the rules are in `pp_proc_end.h` and tested by
`tools/tests/test_proc_end.py`.

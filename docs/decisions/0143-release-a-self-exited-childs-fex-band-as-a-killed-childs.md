# 0143: A child that exits by itself has its FEX band views released as a killed child's

**Status:** accepted, 2026-10-20, directed by the supervisor for the owner (PLA-413). Amends
[0127](0127-end-a-terminated-pseudo-process.md) and madeira-unix 0154 (PLA-368). Not yet shown on
the phone.

## Context

- **0154 kept the band of a self-exit.** When a child ran `process_exit_wrapper`, 0154 released its
  private memory and images once all its threads had finished, but kept every view in FEX's band. It
  assumed FEX's `ThreadTerm` had already released them. 0127 kept that rule ("its band views still
  stay; that is a follow-up").
- **The assumption is false for `NtTerminateProcess(-1)`.** The Rockstar launcher's two
  `--type=renderer` SocialClubHelper.exe processes end themselves about 25 s after they start
  (`NtTerminateProcess(handle=0xffffffffffffffff, exit_code=0x0)`). Their other 16–17 threads end
  through `abort_thread`, as a killed process's do, and never pass `ThreadTerm`. Only the exiting
  thread's own band goes. Each renderer then logged `[view-owner] … exited: freed 270 views
  (3056 MB), kept 559 (680 MB)`.
- **What it cost.** At RDR2's Story press +60 s, 290–400 MB of those views were resident or
  compressed, in the runtime's `[proc-mem]` FEX row: 3033/294/75 MB (committed/resident/compressed) in
  run f2, against 2499/23/16 in s6, where the launcher killed both renderers first and 0127/0132
  emptied them (`[proc-end] … emptied=592 MB`). Which path a renderer takes is a race in CEF: 12 of
  14 RDR2 runs on 2026-10-20 took the self-exit path
  ([evidence](../evidence/2026-10-20-rdr2-owner-defaults.md)).

## Decision

- **Same rules.** Once every thread of a self-exited x86-64 child has finished or is parked, 0154's
  release takes its views by 0127's and 0132's rules, through the same code as a killed child's:
  - in FEX's band, every view it allocated goes: rpmalloc spans, call-return stacks, L1 caches and the
    rest. With a thread parked, the L1 caches are deleted and the rest is emptied in place (0132);
  - no view that holds an address a parked thread's saved state names changes, in the band or out of
    it. 0154 used to delete such a view outside the band;
  - outside the band 0154's rules stay: private memory and images go; other sections,
    `VPROT_SYSTEM` views, the JIT pool and WoW64 windows stay. Sections in the band stay too.
- **Only its own.** A view goes only if the child made it (`ios_owner_peb`), and each view is taken
  once (`ppe_take_view`). The band holds no donor-pool or swap-tier range.
- **What does not change.** The release still waits for every thread and runs on another process's
  thread. `process_exit_wrapper` still gives back the JIT-pool ranges and alias callbacks first. The
  child's TEBs keep 0154's handling, and an i386 child keeps every view.
- **The line.** `[view-owner] peb=… exited: freed image= private= spans= callret= l1= band_other= MB,
  emptied=N MB, kept K MB (V view(s) a parked register points into); F finished, P parked thread(s);
  footprint A->B MB`, as 0132's `[proc-end]` line.

## Costs and risks

- **A late reader of a deleted band view.** With no thread parked, the band views are deleted and
  their addresses go back to the band. That is 0127's rule for a killed child with no thread parked.
  The exiting thread itself marks itself finished in `process_exit_wrapper` and then makes no FEX call.
- **Not checked by a host test.** The walk runs only on the phone. `tools/tests/test_proc_end.py`
  checks the rules and the line.

Implemented by madeira-unix 0203; the rules are in `pp_proc_end.h`.

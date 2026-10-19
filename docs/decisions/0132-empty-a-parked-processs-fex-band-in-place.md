# 0132: A torn-down process with a parked thread has its FEX band views emptied in place

**Status:** accepted, 2026-10-19, design approved by the supervisor for the owner (PLA-416
follow-up). Amends [0127](0127-end-a-terminated-pseudo-process.md). Not yet shown on the phone.

## Context

- **0127 kept the band of a process with a parked thread.** Of such a process's views in FEX's
  band, only the L1 caches went. Its rpmalloc spans, call-return stacks and other band views stayed,
  as the parked thread's FEX state may name them.
- **Every killed process had a parked thread.** In run `20261019T210854` (IPA `a60a55e1`,
  [evidence](../evidence/2026-10-19-rdr2-khronos-vulkan-loader.md)) all seven teardowns logged at
  least one parked thread, so none freed its band:
  - the two SocialClubHelper processes the launcher ends itself (pids 0x338 and 0x2d4) kept 621 and
    472 MB, against a band of 568 and 417 MB committed (135 and 166 MB resident). The killed helpers
    keep that memory for the same reason;
  - the launcher tree's end kept 2,470 MB, mostly band.
- **What it cost.** Kept views lose their owner and count as the runtime's. The runtime's
  `[proc-mem]` FEX row went from 38/0/25 MB (committed/resident/compressed) before the helpers'
  end to 986/295/27 after it, and from 986/196/115 to 3,190/605/422 after the launcher tree's end.
  That is about 1.0 GB of footprint, of a peak 52 MB under the 8,192 MB limit.
- **Code is not in the band.** FEX's code buffers come from the JIT pool, which a teardown already
  gives back (`pool=`). A pool page must never be volatilized (ml87).

## Decision

- **Empty in place.** In a teardown with a thread parked, each of the dead process's band views
  that is not kept whole (below) and is not an L1 cache is emptied, not kept:
  - every whole host page of its committed runs is mapped over with fresh anonymous zero-fill, at
    the protection `mach_vm_region` reports for it. That is `decommit_pages`' mmap-over, which the
    band already uses on the phone;
  - the view, its vprot and its address range stay. Nothing else is placed there, and a reader finds
    zeros, not a fault;
  - its old pages, resident and compressed, leave the footprint;
  - an executable range is left as it is.
- **Which views.** Only the dead process's own valloc views in the band. Sections, file mappings,
  `VPROT_SYSTEM` views, the JIT pool and every view outside the band keep 0127's rules. L1 caches
  are still deleted, and a process with no parked thread still loses its whole band.
- **Kept whole.** A view that contains any address a parked thread's saved state names stays as it
  is. A register value inside a view keeps the whole view. The addresses are:
  - x0-x28 (x18 among them), fp, lr, sp and pc;
  - the guest's 16 GPRs and rip;
  - its TPIDRRO_EL0, read as `THREAD_IDENTIFIER_INFO`'s `thread_handle`. iOS owns and zeroes
    TPIDR_EL0, and no Mach state flavour returns it;
  - its TEB;
  - the address of its alert wait.
- **Once.** Each view is taken from its process once (`ppe_take_view`) and then belongs to the
  runtime, so a second teardown, or any later walk by process, never frees or empties it again.
- **Not unmapped.** Deleting the views would give their addresses back to the band, and a late
  reader or writer would then hit another process's memory. `MADV_FREE_REUSABLE` was not chosen:
  XNU applies it only to an entry with protection RW and maximum protection RWX, so on iOS anonymous
  memory and guard pages it may free nothing.
- **The line.** `[proc-end] … pool=… MB, emptied=N MB, kept K MB (V view(s) a parked register
  points into); … ; footprint A->B MB`. The kept bytes include emptied views. The footprint is the
  task's `phys_footprint` before and after the teardown.

## What can still point into an emptied view

| Holder | Where it is, and why it is safe |
| --- | --- |
| The parked thread itself: registers, TEB, stacks | Mach-suspended forever and never resumed, so it reads nothing. A view any saved register, TPIDRRO, its TEB or wait address names is kept whole. Its TEB and stacks are runtime views, outside the band. |
| Runtime thread tables: `teb_list`, thread data, the parked and exited-TEB tables | They hold TEB pointers and saved addresses, outside the band. The dead TEBs lose their PEB pointer and `TlsExpansionSlots` (0127), so no walk by process reaches them. `virtual_clear_tls_index` writes only `TlsSlots` inside the TEB. |
| Wait and futex tables | The futex word a parked thread sleeps on is in the runtime's per-thread alert table (`0x143b4…` in the run), outside the band. A late `NtAlertThreadByThreadId` writes there and wakes it in the kernel, and it stays suspended. The `ios_alert_waiters` entry keeps its wait address, which is kept whole. Its readers ([waiters], [hot-lock], [census-hold]) use `mach_vm_read_overwrite` or check `msync` first. |
| Lock reaping (`ios_srw_reap_exclusive`) | It reaps the lock a dead TEB's FEX stamps name. A parked thread has every stamp clear, or it would not be parked. A reap through a stale address would find a mapped RW zero page, not a fault. |
| `[proc-mem]`, the band census, `[guest-census]` | They walk views, vprot and `mincore`, never contents. Emptied views count as the runtime's, committed, with nothing resident. |
| JIT alias callbacks into the dead FEX instance | `ios_alias_forget_process` removes the dead emulator before any view is touched (`ios_jit_reclaim_process_bytes` runs first), so none is called again. |
| FEX's own lists: ThreadTerm, its thread list, rpmalloc heaps and caches | Each pseudo-process runs its own FEX instance. Its globals are in its own image and heap, and no other instance frees into its rpmalloc heaps (0127). No thread of it runs. |
| Other processes and the server | They never held the dead instance's band addresses. The server's thread objects are gone (0127). |

## Costs and risks

- **Address space stays.** Emptied views keep their reservation in the 16 GB band. Before, they kept
  their reservation and their pages. The band peaked at 5.7 GB.
- **Edges.** A committed run that shares a host page with another run keeps that page.
- **Measured only on the next phone run.** The saving is expected to match the band footprint above.
  The `footprint A->B` figure shows it.

Implemented by madeira-unix 0172; the rules are in `pp_proc_end.h` and tested by
`tools/tests/test_proc_end.py`.

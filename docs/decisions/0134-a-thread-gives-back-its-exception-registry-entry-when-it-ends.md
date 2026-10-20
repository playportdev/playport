# 0134: A thread gives back its exception registry entry and trampoline slot when it ends or is parked

**Status:** accepted, 2026-10-20, by the worker under the owner's unattended brief for PLA-364
(the brief asks for this fix and a record if behaviour changes). Amends
[0127](0127-end-a-terminated-pseudo-process.md): a parked thread gives both back too.

## Context

- **The run.** In run `20261020T073042-rdr2-m10b` (IPA `500381f6`) RDR2's Story reached gameplay.
  About 10 s later its thread 0878 logged `[thread-registry] FULL (512 slots)`, and RDR2 ended
  with 0xc0000005 at phys 7,153 MB, not at the memory limit
  ([evidence](../evidence/2026-10-20-rdr2-thread-registry.md)).
- **The registry.** The runtime's Mach exception thread registry maps a thread's port to its TEB
  and TEB-restore trampoline, so the exception server can deliver a fault to the right
  pseudo-process. Its entries were handed out once per thread, by a high-water mark, and never
  given back: thread exit freed nothing, and neither did a process's teardown (0127).
- **The count.** The session had registered 512 threads in all (every process: the session root,
  the Rockstar launcher tree ended under 0130, the game's Social Club ended under 0133, and RDR2).
  About 350 had ended (`[srv-kill] kill_thread`) and 35 were parked (`[proc-end] parked`) by then,
  so about 127 were running.
- **A thread not in the registry** has its Mach exceptions resolved to the slot-0 TEB, the first
  process's. The 513th thread's first fault is therefore delivered to the wrong process.
- **The trampolines.** The per-thread trampoline slots in the JIT pool's reserved first page were
  capped at 256 and never given back either. From the 257th thread on (line 80,397 of the run's
  log) every thread got slot 0 and wrote its TEB into the first thread's slot.

## Decision

- **A thread that ends gives back both** in `pthread_exit_wrapper`, last before `pthread_exit`:
  its registry entry (TEB cleared first, then port 0) and its trampoline slot. It clears its own
  thread-local trampoline, so a signal after that no longer redirects through one.
- **A parked thread gives back both when it is parked** (0127). It is Mach-suspended for ever and
  is never resumed, so it executes nothing and cannot fault.
- **A registration reuses the lowest free entry** before raising the high-water mark. The entry is
  claimed with `MACH_PORT_DEAD`, which matches no thread, and published port last. The lock-free
  readers keep scanning up to the mark.
- **No port name is recycled into a stale entry.** Registered port names stay pinned with extra
  send rights (ml401), so a new thread never carries an ended thread's name.
- **The trampoline page holds 1,024 slots**: the reserved page is 0x4000 bytes of 16-byte slots.
  Slot 0, the first thread's and every overflow's, is never given back.
- **The registry stays at 512 entries.** With the give-back, the phone runs had at most 284 entries
  live at once.
- **Logging.** Each give-back logs `[thread-slots] port=… ended|parked: idx=… tramp=… live=N`, and
  each registration line ends with `live=N`.
- **Where.** madeira-unix 0173, `pp_thread_slots.h`, `tools/tests/test_thread_slots.py`.

## Costs and risks

- **After the give-back an ending thread is a native thread.** A fault in `pthread_exit`'s own
  code is handled as a non-guest thread's, as the slot-0 fallback would have made it before.
- **Diagnostics lose ended threads.** The scans that walk the registry (the census and hold
  reports, the pump sampler) no longer see ended or parked threads. A thread that ends holding a FEX lock is
  still named by `[exit-hold]`.
- **The FULL path stays.** With more than 512 live threads the old fallback still applies.

## What the runs showed

On IPA `82b9cd29` ([evidence](../evidence/2026-10-20-rdr2-thread-registry.md), section 3):
- **Hollow Knight's check passed.**
- **Three RDR2 Story runs passed m10b's 512 registrations** (510–516), with no `FULL`. At most
  284 entries were live at once, and freed entries were reused (the highest index stayed at that
  count).
- **None ended with RDR2's 0xc0000005.** All three ended at the 8,192 MB memory limit, one after
  2.5 min of gameplay in which Arthur walked under the left stick.

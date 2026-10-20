# RDR2: the Mach exception thread registry ran full; threads now give their slots back (PLA-364)

**Linear:** PLA-364 (RDR2 gameplay), PLA-416 (ending terminated pseudo-processes).
**Decision:** [0134](../decisions/0134-a-thread-gives-back-its-exception-registry-entry-when-it-ends.md).
**Change:** madeira-unix 0173 (`pp_thread_slots.h`), test `tools/tests/test_thread_slots.py`.

## 1. What run m10b's log shows

This is run `$PLAYPORT_BUILD/ui-runs/20261020T073042-rdr2-m10b` (IPA `500381f6`), its
`pull/s1-host.log`. The log is counted up to the `[thread-registry] FULL` line (line 185,886);
see [the kk-memory evidence](2026-10-20-rdr2-kk-memory.md), section 6.

- **Registrations.** `Mach exception handler registered thread` appears 512 times. Every thread
  of every pseudo-process registers once, at `init_syscall_frame`.
- **Ended threads.** There are 350 distinct `[srv-kill] kill_thread tid=` lines, in 11 processes
  (`[srv-kill] kill_process`): the session root's helpers, the Rockstar launcher tree (ended under
  0130), the game's own Social Club helpers (0133 was on: `set:endGameSocialClubAfterSignIn=true`),
  and their restarts.
- **Parked threads.** There are 35 `[proc-end] parked` lines. Parked threads stay Mach-suspended
  for ever (0127).
- **Live threads.** So at the FULL line about 162 registered threads still existed, of which 35
  were parked. About 127 were running.
- **The registry never gave a slot back.** Entries were handed out by a high-water mark
  (`ios_thread_count`). Thread exit, `pthread_exit_wrapper`, did not touch the registry, and
  neither did a process's teardown. The only existing release, `ios_thread_registry_forget`, clears
  the TEB of a torn-down WoW64 window's threads but keeps the entry. Port names are pinned
  (ml401), so an entry was not even reused by a recycled name.
- **The trampolines ran out first.** The JIT pool's TEB-restore trampoline slots (256, also never
  given back) ran out at line 80,397 (`allocated trampoline slot 255`). From then on, 257 threads
  got slot 0 and wrote their TEB into the first thread's slot (`allocated trampoline slot 0` × 258).
- **What FULL means.** A thread that is not in the registry has its Mach exceptions resolved to
  the slot-0 TEB, the first process's. Thread 0878 of RDR2.exe (pid 0414) was the 513th; a second
  one, 087c, followed. RDR2 then ended with 0xc0000005.

## 2. The change (madeira-unix 0173)

- **At thread exit** (`pthread_exit_wrapper`, last before `pthread_exit`), a thread gives back its
  registry entry and trampoline slot.
- **A parked thread gives back both when it is parked.** It is never resumed, so it cannot fault.
- **A registration reuses the lowest free entry** before raising the mark.
- **The trampoline page holds 1,024 slots** (0x4000 / 16), not 256.
- **The logging.** Each give-back logs `[thread-slots] port=… ended|parked: idx=… tramp=… live=N`,
  and each registration line now ends with `live=N`.

**Host checks** (`tools/tests/test_thread_slots.py`, in `pp test`):
- the claim, publish, release and find order;
- a claimed entry naming no thread until it is published;
- a claim that races a free-entry scan at the mark;
- 8 threads making 160,000 registrations and releases with no entry held twice;
- the trampoline slots, with slot 0 never given back.

`./pp build` built the dev IPA `82b9cd29`, and `./pp test --quick` passed.

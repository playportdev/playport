# 0120: A full FEX host band ends the launch, as a full JIT pool does

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-408, option 4). Amends
[0022](0022-stop-a-game-that-ran-the-pool-out.md) and [0112](0112-a-launchers-open-outlasts-a-pool-exhaustion.md):
they now cover the band as well as the pool.

## Context

FEX keeps each emulator thread's host state in one fixed 16 GiB range, the band
([ARCHITECTURE](../ARCHITECTURE.md#the-fex-host-band)). Every request in it is FEX's own: a
thread's rpmalloc spans, its call-return stack, its L1 lookup cache, and the pooled buffers
(the IR emitter's 16 MiB working list, the frontend's buffer, code buffers).

In RDR2's Steam play (run `20261019T105650`, IPA `4232943d…`), the signed-in Rockstar launcher's
processes filled the band at 197 threads and it refused 24 requests
([evidence](../evidence/2026-10-19-rockstar-physicaldrive.md)). Two Social Club helpers then
faulted about 150,000 times each:
- `IntrusivePooledAllocator::ClaimBufferImpl` got null from `VirtualAlloc`, and its clients do
  not check.
- `IREmitter::ResetWorkingList` stored through `List = 0 + 8 MiB`.
- The thread's guest handlers continued the fault, and FEX retried the compile.

The launch did not end, because only a JIT pool exhaustion ends one. The screen stayed on the
launcher's logo for ten minutes, until the run was stopped.

Of the 1,428 recorded `pp ui` runs, a refusal appears only in two Rockstar Opens, and both failed.

## Decision

- **FEX ends the process** (`patches/fex` 0054). A pooled buffer the host refuses logs `[band] FEX
  could not allocate its <name> buffer, bytes=… band=…`. Then the guest process ends with
  `STATUS_COMMITMENT_LIMIT`, as FEX's JIT already does when it cannot go on (ml460). The report
  is allocation-free.
- **The app ends the launch.** A band reading with a refusal is an exhaustion, as the pool's
  is (`FexBand.Use.exhausted`):
  - the launch logs `band: ran out of emulator memory (N refused)`;
  - it ends after the same grace as a pool exhaustion: 10 s, or 240 s for the Rockstar launcher's
    Open and a play that starts that launcher (0112);
  - its outcome is *ran out of emulator memory*, with `band=exhausted` in the result line before
    the exit, and `pp ui` counts it not ok;
  - a launch whose pool also ran out keeps the pool's outcome, and its line carries both fields.
- **The alert says what happened.** The title is "*Game* ran out of emulator memory". The text
  says that the emulator holds a fixed amount of memory for each thread the game and its launcher
  run, that their threads filled it, and that the game runs more threads than Playport can hold.
  There is no setting for it.

## What stays

- The band's size, its placement and the per-thread cost are unchanged.
- A refusal of a rpmalloc span (the fextl `[alloc-fail]` trap, ml798) and a thread that cannot get
  its call-return stack fail as before. The app's outcome now names them.
- The restart after the launch (0029, 0030) ends the processes left running.

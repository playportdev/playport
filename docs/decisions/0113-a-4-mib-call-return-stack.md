# 0113: FEX's call-return stack is 4 MiB per thread

**Status:** not adopted, 2026-10-17 (owner): the next work trims Chromium's and the launcher's
threads instead; `patches/fex` 0047 and `patches/madeira-unix` 0157 were removed, and the
measurement stays in the [evidence](../evidence/2026-10-17-callret-stack.md).
[PLA-383](https://linear.app/playportdev/issue/PLA-383),
[PLA-381](https://linear.app/playportdev/issue/PLA-381),
[PLA-370](https://linear.app/playportdev/issue/PLA-370),
[plan](../plans/2026-10-16-cef-low-va-build.md),
[evidence](../evidence/2026-10-17-callret-stack.md).

## Context

Every emulator thread reserves its call-return stack in the FEX host band
([ARCHITECTURE](../ARCHITECTURE.md#the-fex-host-band)). Madeira raised it from upstream's 4 MiB to
16 MiB, because entries that SEH unwinds skip were filling it. It is a return-address predictor:
a CALL pushes the guest return address and a host label, a RET pops the pair and takes the label
only if the address matches, and otherwise looks the target up as usual. A reset or a stale entry
costs a prediction, never a result.

In the Rockstar Games Launcher's Open (IPA `0013352e…`, run `20261017T191412`), the band filled at
host +49.5 s: `[band-map] first refusal` used 16,202 MB with 204 call-return stacks, 694 rpmalloc
spans (11.1 GB), 204 L1 caches and 1,424 MB of other views. The stacks held 3.3 GB. The refusal was
a 16 MiB rpmalloc span, with `largest_free=16MB` but no free 16 MiB-aligned slot. FEX could not
allocate in Social Club's second renderer, the renderer died, and the launcher gave up waiting for
Social Club's window.

ARM64EC's inline guard (Madeira, `BranchOps.cpp`) already bounds a leaking stack: it keeps the
pointer in a window around the default location and resets it there when it leaves. Before this
decision the window was `[2 MiB, 6 MiB)` of the 16 MiB, so 10 MiB of each reservation was reached
only by the dispatcher's single-entry callback push.

## Decision

- **Size.** `CALLRET_STACK_SIZE` is 4 MiB for every title and both FEX modules (ARM64EC and WOW64),
  one constant (`patches/fex` 0047). No per-title setting, environment switch or driver option.
- **Geometry.** The pointer starts and resets at the middle (base + 2 MiB); the inline guard keeps
  it in `[1 MiB, 3 MiB)` (65,536 entries either way); the dispatcher's callback push tests the
  whole 4 MiB. `InternalThreadState.h` names these (`CALLRET_STACK_SHIFT`,
  `CALLRET_DEFAULT_OFFSET`, `CALLRET_LIVE_OFFSET`, `CALLRET_LIVE_SHIFT`) and every site that
  bounds or resets the pointer uses them; before, each site hard-coded the 16 MiB numbers.
- **Band census.** `patches/madeira-unix` 0157 knows a call-return stack by its 4 MiB shape, so
  `band: threads=` still counts the emulator threads.
- **Why 4 MiB, not 2.** The counted resets (`[callret] … resets=`) are the code-invalidation
  clears, which do not depend on the size; the inline guard's resets are not counted. What sets
  the floor is depth: in Hollow Knight's eight sampled clears (`[dc-census]`, run
  `20261017T191241`) 64 KB of the stack was touched, so 1 MiB a side is sixteen times that. 4 MiB frees 12 MiB a thread (about 2.4 GB at 204
  threads); 2 MiB would free 0.4 GB more and halve WOW64's headroom again (below).

## Measured savings

[Evidence](../evidence/2026-10-17-callret-stack.md), IPA `adf8ea8f…`: in the same Rockstar Open
the band peaked at 13,806 MB with no refusal (before: 16,203 MB, refused at 204 threads); the
896 MiB JIT pool then ran out instead, and Social Club still showed no window. Hollow Knight: the
same 17,408 invalidation clears in half the time; first frame +12.44 s against +10.75 s, one run.

## Risks

- **WOW64 has no inline guard.** A 32-bit thread that leaks entries walks from the default
  location down to the base, then past it (iOS does not fault on the guard page) until
  CompileBlock's `[CALLRET_OOB]` check resets it. Portal 2, Counter-Strike and the i386 GL test
  logged underflows of up to 0x47260 bytes below the base with 16 MiB stacks. At 4 MiB that walk
  is 2 MiB, not 4, so it happens about twice as often; what lies below a stack is usually the
  next thread's stack top, above the window ARM64EC keeps. A WOW64 inline guard would bound it; it is not part
  of this decision.
- **Leaking ARM64EC threads reset twice as often.** The window is ±1 MiB, not ±2; a reset costs the
  predictions of the frames then live. Not counted; Hollow Knight's first frame is the check.
- **Census shape.** A view of 4 MiB plus at most 64 KiB in the band is counted as a thread; an
  rpmalloc huge block of that size would be miscounted.

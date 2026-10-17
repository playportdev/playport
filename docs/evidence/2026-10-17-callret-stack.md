# A 4 MiB FEX call-return stack (PLA-383)

**Linear:** [PLA-383](https://linear.app/playportdev/issue/PLA-383),
[PLA-381](https://linear.app/playportdev/issue/PLA-381),
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Plan:** [low-VA CEF](../plans/2026-10-16-cef-low-va-build.md).
**Decision:** [0113](../decisions/0113-a-4-mib-call-return-stack.md).
Branch `dev/pla-291-rockstar-launcher`.

**Question:** Does a 4 MiB call-return stack per thread (was 16 MiB) keep the FEX host band from
filling in the Rockstar Games Launcher's Open, and what does it cost Hollow Knight?

## Source facts (the FEX tree with `patches/fex` 0001–0046)

- `FEXCore/include/FEXCore/Debug/InternalThreadState.h:118`: `CALLRET_STACK_SIZE {0x1000000}`;
  `:147-149` derive `CALLRET_DEFAULT_OFFSET` (SIZE/4), `CALLRET_LIVE_OFFSET` (SIZE/8) and
  `CALLRET_LIVE_SIZE` (SIZE/4), which no code used.
- Allocation: `Source/Windows/Common/CallRetStack.h:91` reserves SIZE plus two 4 KiB guard pages,
  in the band from the top down (0010), `MEM_COMMIT`s SIZE at `:173` and reads all of it once
  with `ZeroScrub` (`:194`). `GetInfoThread` (`:24-28`) puts the default pointer at base + SIZE/4.
  `ARM64EC/Module.cpp:1600` (0009's `[band]` lines) uses SIZE.
- ARM64EC inline guard, hard-coded for 16 MiB: `BranchOps.cpp:199-207` (CALL, linked path),
  `:259-269` (RET), `:311-321` (CALL, lookup path) test `(sp - (base + 0x200000)) >> 22` and reset
  to base + 0x400000; `Dispatcher.cpp:708-716` (callback sentinel push) tests `(sp - base) >> 24`.
  The pointer is therefore kept in `[2 MiB, 6 MiB)`; the guarded paths touch at most one 16-byte
  entry past it, the callback path can walk below it to the base.
- Overflow and underflow: the guard resets the pointer (ARM64EC); CompileBlock's check
  (`Core.cpp:1925-1958`) resets it to base + SIZE/4 when it is outside `[base, base+SIZE)`
  (`[CALLRET_OOB]`); `HandleAccessViolation` (`CallRetStack.h`, called from
  `ARM64EC/Module.cpp:1225`, `WOW64/Module.cpp:1061`) resets on a guard-page fault, which iOS does
  not raise. WOW64 is built without `ARCHITECTURE_arm64ec`, so it has no inline guard.
- Correctness: a RET takes a popped host label only when the popped guest address equals the
  target (`BranchOps.cpp`, `sub TMP1, TMP1, RipReg` / `cbz`); every code invalidation clears the
  whole stack (`ResetCallRetStack`, `Core.cpp:736`, `VirtualDontNeed` over SIZE). A reset or stale
  entry costs a prediction.
- `[callret] … resets=` counts those invalidation clears (sites `core`, `cpubackend`,
  `jit-rollover`), not the guard's resets, which are not counted.
- Band census: `patches/madeira-unix` 0038 counts a view of 16 MiB < size ≤ 16 MiB + 64 KiB as a
  call-return stack, and the app reports that count as `band: threads=`
  (`PlayportKit/FexBand.swift:60`). `span_slots` counts free 16 MiB-aligned 16 MiB blocks for
  rpmalloc and does not depend on the stack size. `[dc-census]` samples decommits of 4 MiB and
  more, so it still sees a 4 MiB clear.

## Before (IPA `0013352e…`)

- **Hollow Knight** `20261017T191241`: first frame at +10.75 s; `[callret]` resets 17,408 at the
  last line (17,371 `core`, 37 `cpubackend`), `reset_us=472997`, `max_us=6190`; 58 stacks. The
  eight `[dc-census]` samples of a 16 MiB clear: 64 KB dirty each.
- **Rockstar Open** `20261017T191412`: `[band-map] first refusal size=0x1000000 align=0x1000000:
  used=16202MB views=1838 largest_free=16MB span_slots=0 spans=694 callret=204 l1=204
  other=1424MB refused=1`; 232 stacks created.
- **WOW64 underflows** with 16 MiB stacks: `[CALLRET_OOB] UNDERFLOW` up to 0x47260 bytes below
  the base in Portal 2 (`20261011T081525`), 0x464c0 in the i386 GL test, 0x87c0 in
  Counter-Strike.

## Change

`patches/fex` 0047 and `patches/madeira-unix` 0157 (decision 0113).

## After

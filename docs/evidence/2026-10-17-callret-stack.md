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

IPA `adf8ea8f4b784da5f6e8b150e212bd9ad381b5dbcb3d32a463fc7160a0399d8e` (HEAD `2a16059`, 87 IPA
checks), installed in place and driven in one `pp phone lock` session (setting saved, Open, setting
cleared; all three `pp ui` steps ended as planned).

### Hollow Knight, `20261017T193843`

| | before `20261017T191241` | after `20261017T193843` |
| --- | --- | --- |
| first frame | +10.75 s | +12.44 s |
| `[callret]` resets (last line) | 17,408 (core 17,371, cpubackend 37) | 17,408 (core 17,371, cpubackend 37) |
| reset time, total / max | 472,997 µs / 6,190 µs | 219,310 µs / 261 µs |
| `[callret-geom]` | size 0x1000000, window `[+0x200000, +0x600000)` | size 0x400000, window `[+0x100000, +0x300000)` |
| band at the end | 3,805 MB, 55 threads | 3,041 MB, 55 threads |
| `[CALLRET_OOB]` | 0 | 0 |

The first frame is slower than in all 19 earlier Hollow Knight gates since 2026-10-15 (+9.20 to
+11.86 s), in a single run; the disk cache was as warm as before (69,960 hits against 70,061).
This run cannot say whether it is noise or the narrower guard window (the guard's resets are not
counted). The invalidation clears are as many as before and take half the time.

### Rockstar Games Launcher Open, `20261017T194000`

| | before `20261017T191412` | after `20261017T194000` |
| --- | --- | --- |
| band peak / refusals | 16,203 MB / 1 (first refusal at 204 threads, a 16 MiB span) | 13,806 MB / 0 |
| band at the end | 15,288 MB, 196 threads | 12,805 MB, 201 threads |
| most threads seen | 205 | 202 |
| JIT pool | `exhausted=head`, head_exhausted 19, tail_refused 0 | `exhausted=head`, head_exhausted 123, tail_refused 5, tail_fatal 1; room 0, head 511 of 528 MB live, tail 369 of 369 MB live, 404 images, 13 children |
| how it ended | the launcher exited on its own at +79.78 s | still running at the 240 s grace; ended at +298.6 s (`pool=exhausted:head still-running after_s=294`) |
| first window | +30.84 s | +35.24 s (the launcher's 500×400 window) |
| Social Club states | `FINISHED` at 7.8 s | `FINISHED` at 6.4 s of its log (`WAIT_BROWSER_WINDOW` … `START_SIGN_IN`, `FINISHED`) |
| launcher.log | `WaitForBrowser -> WaitForWindow`, never `Active` | the same, then nothing more |

- The band no longer filled: its peak was 2.4 GB lower at the same thread count (204 stacks of
  16 MiB were 3.3 GB; 4 MiB stacks are 0.8 GB).
- The JIT pool did: as the band filled before, the 896 MiB pool ran out at about 199 threads and
  13 processes. The first exhaustion was a utility process's `xtajit64.dll` copy (4.6 MiB) in the
  pool's head; then the second renderer (pid `03a0`) could not get a 16 MiB FEX code buffer from
  the tail (`JIT-pool tail exhausted for FEX EC_CODE`, the one `tail_fatal`). Chromium restarted
  utilities four times; they ended with `0xc0000017` (no memory) and `0xc0000142`. A third renderer
  started.
- Screenshots: at 30 s the Playport launch screen; at 45 s the launcher's "Connecting to Rockstar
  Games Services" window; from 60 s to the stop, black (the launcher hid its window and Social Club
  showed none). **The sign-in form was not visible.**

## Reading

A 4 MiB stack moves the Open's first limit from the band to the JIT pool; it does not bring
Social Club's window. The owner has chosen to trim Chromium's and the launcher's threads next, and
decision 0113 was not adopted (its patches were removed): this record is a measurement. Rockstar's text logs are in the build
area (`agent-notes/pla370-cef/inputs/pla383-rockstar-logs/`), not here (they hold a public IP).

# Plan: helper-owned RAM for large games

**Date:** 2026-10-03. **Status:** research plan, branch `research/extended-memory`.
**Goal:** find out whether memory charged to the JIT helper lets a game use more
RAM than the app's own 8 GiB limit, and stop early if it cannot.

## Where it stands

| Step | Result | Record |
| --- | --- | --- |
| Transport and probe | 4 GiB of incompressible data, owned by the helper, mapped and checked in the app; the app's footprint did not move. The no-footprint ledger flag is refused (`KERN_NO_ACCESS`). | [helper-owned memory](../evidence/2026-10-03-helper-owned-memory.md) |
| FEX data backing (madeira-unix 0049) | Works in Hollow Knight, with gameplay. App footprint 30 MiB lower: FEX's data band is too small to matter. | [FEX helper memory](../evidence/2026-10-03-fex-helper-memory.md) |
| Kingdom Come: Deliverance, FEX data only | No peak gain (one pair; the on run peaked 86 MiB higher, within noise). | [KCD helper memory](../evidence/2026-10-03-kcd-helper-memory.md) |
| Guest heap backing (madeira-unix 0050) | Built, host tests pass. **Not run on the phone.** Up to 2 GiB of live fresh RW guest data of at least 1 MiB in `[0x7000000000, 0x7c00000000)`. | none yet |

The one question the branch exists for has not been tested: does iOS let the
app and the helper together hold more than the app's 8 GiB? Nothing above
proves it. The phone has 11.7 GiB physically, and iOS keeps part of that, so
the best case moves the limit from 8 GiB to roughly 9 to 10 GiB in total.

## Known problems in 0050

1. **Partial release may not free pages.** Decommit, a protection change and
   copy-back map ordinary memory over *part* of a helper object. The object
   probably keeps those pages resident and charged to the helper until the
   whole mapping is gone, while `releaseGuest` already returned the bytes to
   the 2 GiB quota. The helper could then pass 2 GiB, and a decommit would
   free nothing. Unverified: step 2 measures it.
2. **A synchronous XPC call under `virtual_mutex`.** Each qualifying commit
   waits for the helper (3 s timeout) while every other thread that allocates
   or faults waits on the lock. A streaming game commits often.
3. **Copy-back doubles memory while it runs.** It `malloc`s the whole
   overlapping range under the lock, when memory is already tight.
4. **The helper may be killed first.** It is an extension; under pressure iOS
   may end it before the app in front. What happens to the app's mappings then
   is not known.

## Steps, in order

Each step stops the plan if its answer is no. Every run is a `pp ui` or
`pp perf` on a dev IPA through the UI, with its evidence record.

1. **Go/no-go: more than 8 GiB in total.** Hold the app near its limit
   (about 7 GiB, with a probe's local allocation or a game), then run
   `probe:memory-4096` in the helper. Record both footprints, the
   `jetsam` reason if either process dies, and the system's free memory.
   If the two cannot live together above 8 GiB, the mechanism only moves
   memory between ledgers: stop and drop 0049 and 0050.
2. **Decommit frees helper pages.** A probe action: back 64 MiB through the
   guest path, write it, decommit half, then read the helper footprint. If it
   does not fall, fix problem 1: back only ranges released whole, or move the
   whole object to ordinary memory on any partial release.
3. **The game heap path in a game.** Hollow Knight with *Extra guest RAM* on,
   to first-frame+10 and a 100 s `pp perf` with `hk-new-game`: no fault, the
   number of helper calls and their latency (problem 2).
4. **A game that needs it.** KCD with *Extra guest RAM* on and the 896 MiB
   JIT pool (`jitPoolSimulatedMB=896`), the setting in which one play was
   killed loading Rattay (decision 0036). Success: the app's peak footprint
   falls by about the live guest backing, and the play walks on past Rattay.
   Three plays each way, not one pair.
5. **Pressure.** A long KCD session (30 minutes) with other apps opened in
   between: the helper's survival (problem 4).
6. **If 1 to 5 hold:** move the broker out of `Dev/` behind a setting, decide
   whether the FEX-only switch stays (it gave 30 MiB), and write a decision.
7. **GPU memory, later.** Textures and buffers count against the app and are
   the larger part for big games. Try helper-owned pages under DXMT's and
   MoltenVK's shared upload buffers (`newBufferWithBytesNoCopy`). Private GPU
   memory cannot move this way.

## What this does not do for very large games

Red Dead Redemption 2 asks for 8 GB of RAM and 2 GB of video memory at its
minimum; on the phone both come from the same 11.7 GiB. KCD at its lowest
settings already peaks near 7.5 GiB. Even with steps 1 to 7 working, such a
game is probably past what the phone has. It also has blockers this plan does
not touch: the Rockstar Games Launcher and Social Club sign-in, the
video-memory budget notification that hangs it (see the
[DXMT rebase](../evidence/2026-09-24-dxmt-latest-rebase.md)), and CPU and GPU
speed. This plan helps games just over the limit, like KCD, first.

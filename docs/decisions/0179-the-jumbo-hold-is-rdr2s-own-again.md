# 0179: RDR2's address-space hold is RDR2's own again

**Status:** accepted, 2026-11-02, by the owner ("the proper fix would be option 3 as we may have
broken a lot of games with that RDR2 default"; [PLA-769](https://linear.app/playportdev/issue/PLA-769),
GitHub #66). Amends [0153](0153-rdr2s-settings-are-every-games-defaults.md): `jumbo-mb=8960` leaves
`LaunchSettings.everyGame` and goes back to RDR2's compatibility entry, where
[0126](0126-hold-rdr2s-address-space-from-the-start.md) put it.

## Context

- **0153 made the hold every game's.** `jumbo-mb=8960` holds an 8,960 MB gap below FEX's band,
  `[0x79d0000000, 0x7c00000000)`, from the runtime's start. Since
  [0129](0129-the-holds-serve-only-their-own-request.md), only a reservation of exactly 8,960 MB
  takes it. That is RDR2.exe's one reservation; no other game makes it, so in every other game the
  gap stays held all run.
- **Mewgenics (686060) ran out of address space next to it.** In a player's report from 0.5.0
  (iPhone 15 Pro, three launches, all alike):
  - The game reserves address space 1 GiB at a time (`MEM_RESERVE`). It commits almost none of it:
    33 reservations, 33,792 MB reserved, 6 MB committed.
  - The 34th reservation fails with `STATUS_NO_MEMORY`:
    `[jumbo-hold] keeping the holdback 0x79d0000000 +8960 MB from a 1024 MB request`, then
    `[alloc-fail] … STAGE=fixed-map err=3 at 0x79b18e0000`.
  - The game ignores the failure and writes through the NULL it got back. The process dies 13–15 s
    in with `c0000005` (a write to `0x8`), just after its loading screen.
- **0153 had measured the hold only on titles that start** (Hollow Knight and RDR2). Any game that
  reserves a lot of address space in pieces smaller than 8,960 MB pays for it.

## Decision

- **Every game's runtime keys no longer include `jumbo-mb`.** Without the key, the runtime holds no
  gap (`ios_jumbo_holdback_init`: absent means off).
- **RDR2's compatibility entry (`app-1174180`) sets `jumbo-mb=8960`** next to its video-memory keys.
  It goes into a release build's runtime keys as before (`LaunchSettings.releaseRuntime`).
  - Under the stock-CEF Social Club layout (0169), madeira-unix 0225 places the game's hold itself
    and ignores `jumbo-mb`, as before.
  - The Witcher 3's cohort entry keeps its own `jumbo-mb=32768 cage-hold=1`.
- **Only the hold changes.** 0153's other defaults stay every game's.

## Costs and risks

- **No game but RDR2 had a measured reason for the hold.** A game whose one large reservation
  happened to fit the 8,960 MB gap loses that gap. It still gets the space above the furniture
  ceiling that every reservation gets, as before 0153.
- **The Witcher 3's current build** (`short-reserve-mb=6144`) no longer starts with a hold that its
  first short grant must release (madeira-unix 0222).

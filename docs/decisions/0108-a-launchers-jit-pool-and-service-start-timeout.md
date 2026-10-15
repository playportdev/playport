# 0108: A launcher play's JIT pool and services.exe's start timeout

**Status:** accepted, 2026-10-16, by the supervisor of the publisher-launchers run (chunk 3, step
1 of the [launchers plan](../plans/2026-10-12-launchers.md)).
[PLA-275](https://linear.app/playportdev/issue/PLA-275),
[PLA-274](https://linear.app/playportdev/issue/PLA-274),
[PLA-254](https://linear.app/playportdev/issue/PLA-254). Amends
[0036](0036-one-512-mib-jit-pool.md) and [0107](0107-windows-services-for-a-flagged-play.md).

## Context

Red Dead Redemption 2's Steam copy starts the Rockstar Games Launcher, whose Rockstar Service
runs under services.exe (0107). Once wine-pe 0045 lets a service process start at all (it kept
the runtime's `WINE_IOS_JIT_*` variables out of a service's environment, so FEX refused to start
with `0xc0000001`), two limits ended it on the phone
([evidence](../evidence/2026-10-15-rockstar-stage0-phone.md), chunk 3):

- **The start timeout.** Wine's services.exe waits 10 s for a service it started to connect
  (`ServicesPipeTimeout`). Rockstar Service rewrites its own code for about 28 s under FEX
  first, so services.exe gave up and ended it (`process_send_start_message ... failed to start`,
  run `20261016T004627`).
- **The pool.** In the same run the 512 MiB pool ran out (`exhausted=head`; head 204 MiB, tail
  309 MiB) with the launcher, its bootstrapper and two service processes, before any Chromium
  process. A later service start then failed to map its images (`0xc0000135`). With an 896 MiB
  pool (the dev Simulated JIT memory) the service ran: head 213 MiB, tail 481 MiB, about 694 MiB
  in all (run `20261016T005101`).

## Decision

- **A per-game `jitPoolMB` setting**, the compatibility table's (0074) only, with no row of its
  own in Game options. A Play gets it instead of 0036's 512 MiB when:
  - it is at most `JitPool.maximumMB` (896, the executable's exec-time reservation); a larger
    entry is refused by the table's own check, and one between is a multiple of 16 MiB;
  - the memory limit read before the pool is blessed is at least 6 GiB (6,144 MB, with 64 MB
    of slack for how the limit reads): the reference phone with the Increased Memory Limit
    entitlement. Under it, the Play keeps 512 MiB, and the `jit pool:` line says why. Every
    byte of the pool comes out of the game's memory.
- The table sets 896 for Red Dead Redemption 2 (`app-1174180`). The Rockstar Games Launcher's own
  Open play (Settings › Launchers, PLA-271) is to use it too. Every other title is unchanged:
  `jit pool: 512 MiB`.
- A dev build's Simulated JIT memory still wins over both.
- **services.exe's start timeout** is two minutes (`ServicesPipeTimeout` = `"120000"` under
  `HKLM\System\CurrentControlSet\Control`, a string, as Wine reads it). It is topped up in the
  prefix for a play with `windowsServices` on, with RpcSs's entry (0107): written only where the
  prefix lacks it, never removed, and read only by services.exe, which only such a play starts.

## Costs and limits

- 384 MiB more of the app's limit for the launcher's play, from the bless on.
- 896 MiB is the most the reservation holds. Whether the launcher's Chromium processes fit in it
  is step 7's measurement (PLA-274); if they do not, that is a new decision.

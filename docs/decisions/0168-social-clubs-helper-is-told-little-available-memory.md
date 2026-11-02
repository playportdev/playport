# 0168: Social Club's helper is told little available memory

**Status:** accepted, 2026-10-30, approved by the owner (PLA-476). It hand-ports willfaust/Madeira `855bef4`
(`avail-phys-cef-mb`) and the Wine caller of willfaust/wine `pr/wine-avail-phys` as Playport patches, as
[0054](0054-madeira-frozen.md) requires. It adds a key to
[0153](0153-rdr2s-settings-are-every-games-defaults.md)'s every-game defaults. It gives the stock helper of
[0150](0150-dev-single-process-social-club.md) a runtime trim, alongside the compiled trims
[0114](0114-trim-social-clubs-chromium-and-the-launchers-threads.md) gives Playport's own CEF.
[Plan](https://linear.app/playportdev/issue/PLA-476),
[evidence](../evidence/2026-10-29-sc-stock-cef-probe.md).

## Context

- **The figure every process sees.** Wine's `get_performance_info` reports the phone's free and inactive
  pages as `SystemPerformanceInformation.AvailablePages`, which `GlobalMemoryStatusEx` returns as
  `ullAvailPhys`. Every process therefore sees gigabytes available, while this app ends at its own limit
  (8,192 MB on the reference phone).
- **Chromium never purges.** Chromium's Windows memory-pressure evaluator purges below 1,000 MB available
  (moderate, every 10 s) and below 400 MB (critical, every 5 s): a full V8 collection, PartitionAlloc and
  discardable purges, and dropped Skia, tile and decoded-image caches. In the game's Social Club helper
  (`SocialClubHelper.exe`, stock CEF) neither level is ever reached.
- **What Madeira does.** In `855bef4`, `ios_avail_phys(host_free)` has two keys, both off by default:
  - `avail-phys = 1`: every process sees what is left before the limit;
  - `avail-phys-cef-mb = N`: `SocialClubHelper.exe` and `steamwebhelper.exe` see at most N MB.

  Madeira's RDR2 lists set the first. No measurement of the second was found.
- **What is in reach (run l11, at Story's load step).** The game's helper B held image 293, private 66–77 and
  FEX 195–230 MiB (resident + compressed). Only the private row is Chromium's to purge.

## Decision

- **Only Social Club's helper is told less.** A process whose image is `SocialClubHelper.exe` sees at most
  `avail-phys-cef-mb` MB of available physical memory. Every other process keeps the phone's figure, the game
  and the launcher included.
  - `LaunchSettings.everyGame`'s runtime keys carry `avail-phys-cef-mb=300`, Chromium's critical level. It acts
    only where a Social Club helper runs, in both builds.
  - A dev build's Runtime keys row can set `avail-phys-cef-mb=0` (off), or 900 for the moderate level.
- **Patches (`Class: feature` and `ios-port`, `Offered-upstream: no`):**
  - **madeira-unix 0234:** `ios_avail_phys(host_free)` in `virtual_ios.c`. It reads the calling PEB's image
    name and caps the figure by the rule in `pp_avail_phys.h`, which reuses `pp_game_sc_refuse.h`'s name match
    and is host-tested. The key is read once.
  - **wine-unix 0203:** `get_performance_info`'s `AvailablePages` comes from `ios_avail_phys(freeram)`. The
    commit figures keep the phone's.
- **Logs.** `[avail-phys] SocialClubHelper.exe sees at most 300 MB available: Chromium's critical level`, then
  the first four answers (`… asked: 300 MB reported instead of N MB`).
  - **As built, 2026-10-30 (owner, PLA-476; madeira-unix 0237):** the four answers are per process, for each
    of the first eight PEBs told less (`ppap_log_slot`). In l12 the launcher's helper used up the app-wide
    four, and the game's helper's answers were never logged.
- **Not ported:**
  - `avail-phys = 1` for every process. RDR2 reads the figure too; a low one could make it lower its settings
    or show its own "out of memory" dialog.
  - The `steamwebhelper.exe` match. Playport runs no Windows Steam client
    ([0115](0115-a-steam-client-for-the-launched-app.md)).

## Consequences

- **Expected saving:** about 10–50 MB of the game's helper's private row while it lives (inferred, unmeasured
  here and by Madeira). The same holds in the launcher's helper, which ends at the game's sign-in.
- **Cost:** Social Club purges every 5 s. A full GC of a jitless, FEX-translated V8 costs CPU during the
  sign-in and Story's load. Pages may redraw images more slowly.
- **Risk:** Chromium does not refuse to run on a low figure, since the evaluator only signals pressure. Social
  Club's own checks, if any, are unknown. A missing or blank sign-in would point here or at
  [0150](0150-dev-single-process-social-club.md)'s GPU-off switches; 900 or 0 is the fallback.
- **Overlap with the GPU-off switches** (0150, amended the same day) is small:
  - The switches remove the ANGLE/Direct3D images and device memory (the image rows and graphics).
  - This record trims CPU-side heaps (the private row).
  - With software compositing, the raster caches it purges are in the private row too.
- **Proof:** the first layout run after it (l12) must show:
  - the `[avail-phys]` lines;
  - the helper's `[proc-mem]` private row against l11's at press-aligned points;
  - Social Club drawn and signed in.
- [0110](0110-own-cef-build-for-a-clients-cef.md) and the game-SC end ([0141](0141-end-rdr2s-own-social-club-no-sooner-than-120-s-after-its-sign-in.md))
  are unchanged.

# Runtime counters off in the release app

**Status:** built, checked on the host and played on the phone with the
counters on and off. Their cost has not been measured yet. **Date:** 2026-09-29. Plan:
[performance follow-up](../plans/finished.md#performance-follow-up-after-the-runtime-audit), step 3,
which has the audit table.

## What was found

`MADEIRA_NO_DIAGNOSTICS` (the release app's switch, [decision 0009](../decisions/0009-dev-and-release-builds.md))
stops the samplers that print `[xp]`, `[xp-api]`, `[srv]`, `[sync-census]` and
`[thread-sample]` (`patches/madeira-unix/0018`). It did not stop the
counters those lines read. They sit on hot paths:

- FEX's transition probe (`patches/fex-port/0061`): an LSE `ldadd` on an
  sp-sharded line on **every x64→EC call**, a second one and a store for every
  64th, and a `stadd` on each performed FPCR write and each emulated EC→x64 call;
- PE ntdll (`wine-port` 0054): the contended critical-section census with its
  `cntvct` timing and ring, spin-acquired and wake counters, the WaitOnAddress
  counters and the per-thread QueryPerformanceCounter gap histogram (plain
  stores on every QPC);
- unix ntdll (0054): a global atomic on every NtSetEvent, ResetEvent,
  PulseEvent, wait, yield and delay, and on each thread alert a timer read and a
  store, with a timer read and three atomics on the woken side;
- the wineserver census (`madeira-unix` 0037): two `mach_absolute_time` reads
  and a TEB-hash probe around every server request and blocked select.

## The change

A single flag, `ios_counters_on`. `__wine_main` sets it once
(`ios_counters_init`, `wine-unix` 0007): off under `MADEIRA_NO_DIAGNOSTICS` or
`MADEIRA_NO_COUNTERS`. The unix loader writes it into the new ntdll export of
the same name. It does this for the session's ntdll and each ARM64EC
pseudo-process's, before that process runs any code (`madeira-unix` 0047),
next to `ios_teb_tsd_offset`. The PE census tests it (`wine-pe` 0012), and FEX
copies it into `IosXpFexOn` at ProcessInit, where each probe loads it and
branches past the counting (`fex` 0011). Nothing that is behaviour moved:
CNTVCT QPC, the adaptive yield's streak, the ECO QoS poll, the alert spin and
the FPCR write itself stay.

A dev build keeps its counters on and can turn them off without losing the
samplers: Settings' Diagnostics, **Runtime counters** (off sets
`MADEIRA_NO_COUNTERS` from Playport's next start), or `pp perf --no-counters`.
The two sides of an A/B then carry the same sampler load, and only the counted
figures (`[xp-api]`, `[sync-census]`, `[srv]`) read zero.

## Checked on the host

- `pp test` and `pp build`, dev (70 IPA checks) and release (72), pass.
- `llvm-readobj --coff-exports`: both ntdll.dll builds export `ios_counters_on`.
- The disassembly of `libarm64ecfex.dll` has the load and `cbz` ahead of each of
  the three probes in `ExitFunctionEC` and `ios_ffs_no_bypass`.

## On the phone

IPA `4c73e9c7b894f4f7ed5bd9221ee863a1165122feaaf502fa7c3f64bf3235566d`, dev,
`pp ui --play app-367520 --until first-frame+10`:

| | counters on | Runtime counters off |
|---|---|---|
| first frame after Play | 11.29 s | 10.05 s |
| launch log | – | `diagnostics: runtime counters off (MADEIRA_NO_COUNTERS)` |
| `[xp-api]`, 1 s | SetEvent 50/s, wait1 370/s, yield 9091/s … | every field 0/s |
| `[srv]`, 1 s | req=1232, rt=111.2 ms | req=0, rt=0.0 |
| `[xp]` census | live | live (P=18 E=217, Minst=575) |

Both played on. The setting was undone at the app's next launch outside the
session.

**Found on the way:** the PE-side counters have had no reader in this app
since titles started running as the session root's children. `[xp-api]`'s
FEX fields (x64→EC, FPCR writes, EC→x64) read 0/s with the counters on, in
this build and in the one before (`a2f29a31`). The sampler's
`[xp-api] ml1131b blocks` line, which it prints once it finds the game
process's modules, is in neither log, so it never reads FEX's `IosXpFex` or
ntdll's `ios_xp_nt`. Until this change, a dev build and the release build
both paid for the x64→EC atomic and the PE lock and QPC census with nothing
reading them. The unix-side counters and `[srv]` are read, as the table shows.

## Measured: no difference at 720/60

2026-09-30, the same IPA, `pp perf --secs 300 --cool 15` at
`{"screen":"720","frameLimit":60}` on the `hk-new-slot` route, order on, off,
off, on, battery 100 → 88 %, no charger. Run directories are in
`$PLAYPORT_BUILD/perf-ab/cnt-*`. The window is the roam loop, 120–300 s after
the first frame:

| run | FPS | p99 / p99.9 ms | ≥25 / ≥50 ms | Mi instructions/frame | CPU % | CPU mW | phone mW |
|---|---|---|---|---|---|---|---|
| `cnt-on-1` | 59.6 | 29.2 / 29.2 | 589 / 5 | 69.6 | 118 | 616 | 3002 |
| `cnt-off-1` | 60.0 | 25.0 / 29.2 | 543 / 0 | 62.8 | 116 | 535 | 2426 |
| `cnt-off-2` | 60.0 | 25.0 / 29.2 | 541 / 0 | 63.0 | 115 | 542 | 2446 |
| `cnt-on-2` | 60.0 | 25.0 / 29.2 | 458 / 0 | 63.3 | 119 | 539 | 2529 |

`cnt-on-1` does not compare. It was the only run to start a new game, and its
Knight died in King's Pass, which saved the slot: the other seven runs loaded
that save and played a different route (see the baseline record's route
notes). Among the three that compare, work per frame, CPU power and tails agree
within 1 %, and none has a frame of 50 ms. The counters' cost is below what
these runs resolve: under 0.5 Mi instructions a frame, under 10 mW. So the
flag does no harm, and the release app saves no measurable CPU or power on
this route at 60 FPS. A CPU-bound mode (free-running) could show more. That
was not run. The whole phone's draw varies by up to 800 mW between runs that
agree on everything else, so it cannot resolve a difference this small.

## Still to run

The same A/B at a CPU-bound mode (720 free-running), if anyone wants a figure
where the CPU sets the frame rate. The original plan follows.

A/B/B/A `pp perf` runs, with and without `--no-counters`, on the
   `hk-new-slot` route, at the plan's baseline mode. The measurement is frame-time
   tails, CPU and phone power, and instructions per frame. No benefit is
   claimed until they have run.

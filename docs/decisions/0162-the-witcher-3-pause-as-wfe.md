# 0162: The Witcher 3's compatibility default compiles x86 PAUSE to WFE

**Status:** accepted, 2026-10-28, in an unattended session the owner asked to raise The Witcher 3's
frame rate (PLA-455). Amends the `app-292030` entry of [0074](0074-per-title-compatibility-defaults.md)'s
table. Revisit if a person's play shows input lag or a stall, or if another title is measured with it.

## Context

- **The clamp and the spin.** In sustained play of the 4.x build, the SoC's power clamp parks the P cores.
  The game's render thread then spins on `pause` and QueryPerformanceCounter for up to 5 ms per wait, on
  an E core. RenderDispatcher1/2 and mod.io's thread spin the same way.
- **FEX's PAUSE is a NOP.** FEX compiles PAUSE to YIELD, which is a NOP on Apple's cores.
- **`patches/fex` 0083** adds `MADEIRA_FEX_PAUSE=wfe`, which compiles PAUSE to WFE. The core waits for the
  next event, and on this phone that comes within 1–10 µs.
- **Measured on the phone** ([2026-10-28-witcher3-perf.md](../evidence/2026-10-28-witcher3-perf.md)): Kaer
  Morhen, +60 to +150 s after the first frame, on battery, two IPAs.
  - **Frame rate:** 24.38 fps with WFE (8 runs) against 22.43 with YIELD (6 runs), **+8.7 %**. One more YIELD
    run sped up to 27 fps mid-run for a reason not found; with it, the gain is +6.5 %.
  - **E-core clock:** 1.23 → 1.56 GHz.
  - **No fault, and no stall.**
- **What does not help:** ISB (22.72 fps) and `MESA_KK_BATCH2=1` (22.47 alone, 24.44 with WFE).

## Decision

- **The entry.** `app-292030`'s compatibility default runtime keys become
  `short-reserve-mb=6144 env.MADEIRA_FEX_PAUSE=wfe`.
- **Overrides.** A person's Runtime keys override it by key (0091): `env.MADEIRA_FEX_PAUSE=yield` gives FEX's
  behaviour back.
- **Scope.** Every other title keeps YIELD.

## Costs and risks

- **Waiting threads count as running.** A thread waiting in WFE counts as running: it holds its core
  and reports more CPU (RenderDispatcher1/2 25 % → 78 %). A title with more spinning threads than free cores
  could lose by that.
- **Spins counted in PAUSEs last longer.** A spin that counts PAUSEs, not time, now spins about 100 times
  longer before it blocks.
- **The defaults reach the release build** (0126).
- **Only one scene was measured,** about 150 s at a time, and nobody played. The classic 1.32 branch, which
  reads the same entry, is not measured with it.

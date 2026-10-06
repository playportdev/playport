# 0055: FEX translates at most 500 instructions a block for every game, as Proton does

**Status:** accepted, 2026-10-06, by the owner. Supersedes the `MaxInst` part of
[0021](0021-fex-ordering-per-game.md) (with 0048, Proton's other values for
`X87ReducedPrecision`); the rest of 0021 stands. Closes item A1 of the
[Proton alignment plan](../plans/2026-10-05-proton-arm64-alignment.md).

## Decision

- **Proton's global `MaxInst=500` is taken.** Every launch passes FEX
  `FEX_MAXINST=500`, the value in Proton's global `FEX_Config.json` on every
  branch (proton_11.0, experimental, bleeding-edge), in place of FEX's own 5000.
- **A profile entry still goes over it,** as for x87 (0048). None of Proton's
  per-game entries sets one today.
- **A game's page overrides it.** The Developer section's *Block size* picker
  (dev builds, decision 0034) keeps *Default* (now 500, shown) and offers 500,
  1000, 2000 and 5000, saved per game as `LaunchSettings.maxInst`.

## Why

The owner's direction (2026-10-06): Proton's defaults are taken as given, so
that Playport runs where Valve's ARM64 testing is, and divergence from Proton
is the exception that needs a reason. FEX's 5000 was only ever kept because
nothing had measured 500 (0021).

## Costs and what was measured

Taken without a new measurement, as the owner asked. The one pair measured
before (one `pp perf` run per arm per title, on the unmerged `madeira-main`
branch, 2026-10-06) showed no gain from 500 and no loss beyond single-run
spread: Hollow Knight 58.3 FPS either way, 69.6 against 71.8 M instructions a
frame; Portal 2 58.7 against 58.8 FPS, more 25 ms hitches and a slower chapter
load with 500 (p10 51.5 against 59.7), and a larger JIT pool tail (289 against
161 MB). A game that regresses gets a profile entry or a choice on its page;
smaller blocks mean more block transitions and more, smaller compiles.

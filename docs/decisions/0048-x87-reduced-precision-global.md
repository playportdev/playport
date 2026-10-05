# 0048: FEX runs x87 at 64-bit precision for every game, as Proton does

**Status:** accepted, 2026-10-05. Supersedes the `X87ReducedPrecision` part of
[0021](0021-fex-ordering-per-game.md); the rest of 0021 stands. The
measurements are in the
[evidence record](../evidence/2026-10-05-portal2-cpu-spin.md).

## Decision

- **Proton's global `X87ReducedPrecision=1` is taken.** Every launch passes
  FEX `FEX_X87REDUCEDPRECISION=1`, so x87 floating point runs on the CPU's
  64-bit doubles rather than FEX's 80-bit software floating point. This is
  the value in Proton's global `FEX_Config.json`, Valve's ARM64 default.
- **A profile entry still goes over it.** Proton's per-game entries keep
  their value: The Witcher 3's `setup*` programs run at 80 bits
  (`X87ReducedPrecision=0`).
- **A game's page overrides it.** The Developer section of a game's page
  (dev builds, as the ordering and block size under decision 0034) has an
  *x87 precision* picker: *Default* (the profile's value, shown), *64-bit* or
  *80-bit*, saved per game as `LaunchSettings.x87Reduced`. The player's app
  runs the profile's value.
- **Proton's other global values are unchanged here.** `MaxInst=500`,
  `Multiblock` and `ProfileStats` stay as 0021 left them; aligning them with
  Proton is planned separately.

## Why

Portal 2's engine does its vector math on the x87 stack (`engine.dll`:
`fsqrt`, `fdivp`, `fmul` in its hottest loops). At 80 bits FEX runs each such
instruction as a call into software floating point. At 64 bits, in the same
scripted play at 60 FPS, the main thread's work fell from 23.9 to 14.8 M
instructions a frame. Its share of a core fell from 40 % to 29 %, and the CPU's
power from 562 to 343 mW. Less CPU work is less heat, which is what keeps the P
cores in play for the 720p, 60 FPS target. A 32-bit title compiled
for x87 pays this everywhere it does floating point; an x86-64 title
does little x87, and Hollow Knight did not change.

Valve runs every game this way under Proton on ARM64 and carries an exception
only where one broke (The Witcher 3's setup). Taking the value keeps Playport
where Proton's testing is.

## Costs

- A game that relies on 80-bit intermediates (64-bit integers through
  `fild`/`fistp` beyond 2^53, extended-precision accumulation) can compute
  different results. The page's picker turns it back to 80 bits per game in
  a dev build; a game found to need it gets a profile entry.
- FEX's warning stands: "may result in rendering bugs". Portal 2's menu,
  lighting, particles, HUD and subtitles were checked in screenshots, and
  Hollow Knight plays as before; a portal placed and looked through is left
  to the next human play, and other games are checked as they are played.

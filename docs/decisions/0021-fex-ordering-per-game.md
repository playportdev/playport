# 0021: FEX's memory ordering is a per-game launch setting over Proton's profiles; LRCPC2 comes from the host

**Status:** accepted, 2026-09-28; its `X87ReducedPrecision` part is
superseded by [0048](0048-x87-reduced-precision-global.md) and its `MaxInst`
part by [0055](0055-maxinst-500-global.md) (Proton's global values are now taken). Settles item 4 of the
[runtime-risks plan](../plans/2026-09-27-runtime-risks.md) (FEX's memory
ordering has a known gap). The measurements are in the
[evidence record](../evidence/2026-09-28-fex-memory-ordering.md).

## Decision

- **The gap stays the default.** Every launch runs FEX with scalar TSO and
  half barriers, and without vector or `rep movs`/`rep stos` ordering
  (`tso=1 halfbar=1 vector=0 memcpyset=0`). These are Proton's own global FEX
  values, so a game without a profile runs as it would under Proton on ARM64.
- **Proton's FEX profiles are data.** PlayportKit `FEXProfile` carries
  Proton's global FEX configuration (`FEX_Config.json`) and its per-game
  `fex_application_profiles` (by Steam app ID, then executable pattern, as
  FEX's `AppOverrides`), as ValveSoftware/Proton has them. A launch matches
  the game's Steam app ID and the executable it runs, and passes FEX the
  result as `FEX_*` environment variables, FEX's highest configuration layer.
  - The four ordering switches (`TSOEnabled`, `VectorTSOEnabled`,
    `MemcpySetTSOEnabled`, `HalfBarrierTSOEnabled`) come from the profile.
  - A profile's `X87ReducedPrecision`, `Multiblock` and `MaxInst` are passed
    on as they are.
  - Proton's other global values are not taken: `X87ReducedPrecision=1` and
    `MaxInst=500` would change every game's code generation unmeasured, and
    `ProfileStats` writes Linux's stats shared memory.
  - What Steam itself passes Proton per game (`STEAM_FEX_TSOENABLED`,
    `STEAM_FEX_MULTIBLOCK`, from Steam's own app data) is not public and is
    not carried.
- **A game's page overrides each switch.** The *x86 memory ordering*
  section of a game's page has one picker per switch: *Default* (the
  profile's value, shown), *On* or *Off*. It is saved with the game's launch
  settings (`LaunchSettings.ordering`), per game only, and a `FEX_*`
  variable the player sets in the game's environment wins over it.
- **LRCPC2 from the host.** FEX cannot read the ID registers on iOS and
  builds its feature set by hand (`patches/fex-port` 0009). The app asks the
  kernel (`sysctl hw.optional.arm.FEAT_LRCPC2`, `HostCPU.swift`) and adds
  `enablelrcpc2` to `FEX_HOSTFEATURES`, which `patches/fex` 0008 honours: FEX
  then sets `SupportsTSOImm9` and emits a TSO load or store with a small
  offset as one `LDAPUR` or `STLUR`. A player's `FEX_HOSTFEATURES` is kept
  and added to; one that names `lrcpc2` is left as it is.

## Why

**The gap held after the Wine plan.** `patches/wine-valve` took none of
Valve's FEX work, and a Play on this build still logs `tso=true
halfbar=true vector=false memcpyset=false`.

**Proton ships the same gap.** Its global FEX configuration has exactly
these four values, and its one per-game FEX profile (The Witcher 3's setup
programs) is about x87 precision, not ordering. Taking Proton's values as the
defaults keeps every game as it ran, and puts the ordering in the player's
hands for a game that needs more, as Proton's per-game data would.

**Vector ordering is not free.** On The Witcher 3 it cost about 4 % of the
frame rate (+3.5 % frame time in play, +4.7 % over the run, both vector runs
slower than both default ones) and about 5 % more CPU work per frame. Hollow
Knight's frames did not change (held at 120 Hz, then by heat), and its CPU
work rose by about the same share. Turning it on for every
game would tax exactly the vector-heavy work the product runs, for a gap no
tested game has shown; a per-game switch does not.

**LRCPC2 is on the phone, and FEX could not know.** The A19 Pro reports
FEAT_LRCPC2; with it FEX needs fewer instructions for each TSO access, and
Hollow Knight plays. Reading the kernel's answer rather than a chip list
covers every chip that has it.

## Costs

- A per-game ordering picker is a way for a player to make a game slower or
  subtly wrong. The pickers show the profile's value as the default, and the
  footer says what each costs.
- The profile data is a copy: a Proton change reaches Playport only when
  `FEXProfile` is updated by hand from ValveSoftware/Proton.
- The `FEX_*` variables are inherited by the game's own child processes, so a
  profile entry for a child's executable pattern (Proton's Witcher 3
  `setup*`) applies only when the app launches that executable itself.
- FEX's disk cache (off, [first-run stutter](../evidence/2026-09-26-first-run-stutter.md))
  keys compiled code on the configuration values that affect code generation
  but not on `HostFeatures`; turning it on again means flushing it when
  LRCPC2 changes.

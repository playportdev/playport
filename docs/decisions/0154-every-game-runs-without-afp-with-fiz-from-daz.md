# 0154: Every game runs FEX without AFP, with FPCR.FIZ from MXCSR.DAZ

**Status:** accepted, 2026-10-21, under the owner's rule of decision 0153 ("everything that works for RDR2 is
enabled for everything else"; this step relayed by the supervisor, PLA-364). Amends
[0153](0153-rdr2s-settings-are-every-games-defaults.md) (its one exception goes) and
[0142](0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md) (RDR2's `disableafp` moves to every
game). [Evidence](../evidence/2026-10-21-afp-fpcr-and-qpc.md): Hollow Knight and RDR2 on dev IPA 0dfe14fe.

## Context

- RDR2 has run without FEAT_AFP since 0142 (`env.FEX_HOSTFEATURES=disableafp`): FEX then writes no FPCR at
  each x64 <-> ARM64EC switch. 0153 kept it RDR2's own, because Hollow Knight drew black without AFP.
- Without AFP, FEX leaves FPCR.AH and FPCR.FIZ clear for x64 code ([afp-off](../evidence/2026-10-21-afp-off.md)).
  fex 0080's `MADEIRA_FEX_AFPOFF_FPCR` sets them as a switch: `fiz` (FIZ follows MXCSR.DAZ), `ah` (AH and
  FIZ for the whole thread), `ahx` (AH and FIZ inside the JIT only).
- On IPA 0dfe14fe, Hollow Knight at first frame+25 without AFP: mode 0 black; `fiz`, `ah` and `ahx` each
  the menu. `fiz` is the smallest: no FPCR write per switch, only on LDMXCSR (or when FIZ is wrong after a
  runtime call), and AH stays clear, so ARM64EC code keeps IEEE behaviour.
- RDR2 with `fiz` (af1) drew the cabin as the no-switch baseline did, at 19.6 fps and E 1.60 GHz (12.3 fps
  per E-GHz against qd1b's 12.5 at a hotter 1.33 GHz), peak 7,662 MB, no fault, no jetsam.

## Decision

- `LaunchSettings.everyGame`'s runtime keys add `env.FEX_HOSTFEATURES=disableafp` and
  `env.MADEIRA_FEX_AFPOFF_FPCR=fiz`, in dev and release.
- RDR2's compatibility entry keeps only `graphics: vulkan`.
- A game that needs AFP gets `env.FEX_HOSTFEATURES=enableafp` in its compatibility entry; the keys merge by
  key (0091), so that replaces the default's value.

## Costs and risks

- Two titles show it: Hollow Knight's menu (one run per mode) and RDR2's cabin (one run). x64 code still
  sees ARM's NaN results without AH (+NaN where x86 gives -NaN, ARM's NaN operand order) and MXCSR.FTZ
  flushing inputs as well as outputs; a game that depends on those draws or computes wrongly without AFP,
  and gets `enableafp`, or `ah` once that mode's effect on native code is checked against the Arm ARM.
- The host features key FEX's disk cache, so a game's first launch on this default compiles afresh, as
  after any new FEX build.

# Direct3D backends for Playport: DXMT and the alternatives

**Date:** 2026-09-26. **Kind:** desk research. Nothing here was run on the phone.
**Pins read:** `dxmt` 7c8dee1 (3Shain/dxmt `main`, 2026-09-17) and `madeira`
8c050d0, as in `pins.lock`.

## Questions

1. Is DXMT the best-performing way to run D3D11 games here, and is there an alternative?
2. What can run D3D12?
3. Is Apple's D3DMetal a workable option on iOS, and would it be faster?
4. Why did Madeira pick this stack?

## Short answers

1. **Keep DXMT for D3D11.** It is the only D3D11 layer that works on a
   non-jailbroken iPhone. D3DMetal cannot run here (see 3), and DXVK needs a
   Vulkan driver with geometry shaders, which iOS does not have. On macOS, where
   both DXMT and D3DMetal run, neither is faster across the board.
   CrossOver 26 ships DXMT, D3DMetal, DXVK and wined3d, and picks one per game
   from its own database. Also, the only title we have measured is not limited by
   the graphics layer: Hollow Knight at native resolution is bound by its main
   thread under FEX ([baseline](../evidence/2026-09-26-hk-native-baseline-wine-11.18.md)).
2. **Nothing that runs D3D12 is ready for Playport.** There are three candidates:
   upstream DXMT's own `d3d12` (in development, off by default, DXBC only),
   Madeira's `madeira-d3d12` (built on Metal Shader Converter, handles DXIL,
   parked, and no longer matches our winemetal ABI), and vkd3d-proton on
   MoltenVK (blocked by geometry shaders, never shown on iOS).
3. **No.** D3DMetal is a closed macOS framework that ships as x86_64 only, and its
   licence covers evaluation, not redistribution. See §3.
4. DXMT goes straight from D3D11 to Metal with no Vulkan layer, compiles DXBC
   directly to AIR, emulates geometry shaders and tessellation, and was open
   source under MIT. DXVK was blocked by MoltenVK, and D3DMetal is proprietary.
   See §4.

## 1. D3D11 options

| Layer | Path | On iOS here | Notes |
| --- | --- | --- | --- |
| **DXMT** (in use) | D3D11 → Metal; DXBC → AIR (LLVM bitcode) → metallib | **works** (Madeira's port + `patches/dxmt`) | Open source; LGPL-2.1+ since after v0.80. The PE side is ARM64EC and the unix side (winemetal) is native arm64, so no DXMT code runs under FEX. |
| D3DMetal | D3D11/12 → Metal, closed | **not possible** | See §3. |
| DXVK → MoltenVK | D3D11 → Vulkan → MSL → Metal | **blocked** | DXVK requires the Vulkan `geometryShader` feature. MoltenVK lacks it (PR #1815 is still unmerged), so DXVK does not create a device. It would also add a second translation step and runtime MSL compiles. |
| DXVK → KosmicKrisp | D3D11 → Vulkan (Mesa, Metal 4) → Metal | **not available** | Mesa's docs describe it as a conformant Vulkan driver for macOS 26+ only. It has no iOS support yet, although A14 and later GPUs were considered in its design. It is worth watching: a conformant Vulkan driver would make DXVK and vkd3d-proton possible. |
| wined3d | D3D → OpenGL/Vulkan | **not viable** | iOS has no desktop GL, and wined3d's Vulkan path would need MoltenVK. It is the slowest option even on macOS. |

**Performance, DXMT against D3DMetal.** No controlled benchmark exists, only
community comparisons of single games on Macs, and they go both ways. DXMT's
author has argued (dxmt discussion #15) that D3DMetal shares its synchronization
with its D3D12 implementation and therefore synchronizes more than D3D11 needs,
while DXMT relies on Metal's own hazard tracking, which matches D3D11's implicit
model. This design point favours DXMT for D3D11, but nobody has measured it
across many games. CrossOver's per-game database is the practical evidence that
neither layer wins everywhere.

**What matters more on the phone.** The CPU part of the graphics layer has to run
as native arm64. DXMT does that through ARM64EC and the unix calls. Any layer
that would run under FEX (an x86_64 D3DMetal, for example) would pay emulation
cost on every API call. In the one game measured so far, the GPU frame time is
12–13 ms at a 33 ms frame interval, and the main thread is 99 % busy
([baseline](../evidence/2026-09-26-hk-native-baseline-wine-11.18.md)).
Replacing DXMT would not raise that frame rate. The graphics layer's own cost
shows only as GPU time per pass ([passes](../evidence/2026-09-26-hk-gpu-passes.md)),
and that is fixed inside DXMT, not by moving to another layer.

## 2. D3D12 options

| Option | State | Shaders | Fit for Playport |
| --- | --- | --- | --- |
| **Upstream DXMT `src/d3d12`** | In development since 2025-07 (target created in `2fb1f51d`). More than 200 commits, the last on 2026-09-14. About 9.3k lines. Behind `-Denable_d3d12=true` (default `false`). **It is already inside our pin**, but we do not build it. | SM 5.x DXBC only: `InitializeShader` returns `E_NOTIMPL` when it finds a DXIL blob (`d3d12_pipeline_graphics.cpp`) | This is the cheapest path: same tree, same winemetal and same licence. But most real D3D12 games ship SM 6 DXIL, so few titles would start today. |
| **Madeira `research/madeira-d3d12`** | Native D3D12 → Metal on Apple's Metal Shader Converter (MSC). It passes its M1–M5 milestones (textured cube) on an A15. UE 5.4 (Empire of the Ants) renders with Nanite at about 2 FPS through remote Metal. The work is parked (2026-09-16). | DXIL (SM 6.x) through MSC, converted on the device when a pipeline is created | It handles the shaders that modern games use. Against it: it needs Apple's MSC dylib in the IPA, a reading of the MSC licence (decision 0006 keeps this open), and a port to our winemetal ABI. Decision 0007 records that it "no longer matches this winemetal ABI". |
| vkd3d-proton → MoltenVK | Proposed in Madeira's analysis as the near-term route. Nobody has shown it working. | DXIL → SPIR-V → MSL | Blocked by geometry shaders (as for DXVK), and it needs many Vulkan 1.3 features that MoltenVK only partly provides. It is two translation layers deep. |
| vkd3d-proton → KosmicKrisp | Only possible once KosmicKrisp supports iOS | DXIL → SPIR-V → Metal | For the future. |
| D3DMetal | Supports D3D12 on macOS | its own | Not possible on iOS (§3). |

A possible combination: DXMT's d3d12 runtime with MSC for DXIL shaders only, and
DXMT's own airconv for DXBC. This is speculative. Nobody upstream has proposed
it, and DXMT's author has said he wants no proprietary piece in DXMT
(discussion #15). It would have to stay a Playport patch.

## 3. Apple's D3DMetal on iOS

Four separate blockers, each enough on its own:

1. **Wrong platform.** `D3DMetal.framework` is a macOS framework from the Game
   Porting Toolkit's evaluation environment. The iOS dynamic loader does not load
   a Mach-O built for macOS, and Apple ships no iOS build.
2. **Wrong architecture.** The framework ships as x86_64 only. On Apple silicon
   it runs under Rosetta 2, together with the rest of Apple's Wine
   (utmapp/d3dmetal-native: "the entire process must be x86_64"). iOS has no
   Rosetta. FEX in this stack translates Windows PE code through ARM64EC and
   cannot run a macOS Mach-O that calls Metal. Even if it could, the whole
   D3D runtime would then run emulated, which would make it slower than DXMT
   rather than faster.
3. **Host interface.** It expects Apple Wine's private `GFXT` host interface
   for windows, events, the registry and memory. utmapp shows this can be
   reimplemented, but only on macOS and only for x86_64.
4. **Licence.** The GPTK licence grants use for developing, testing and
   evaluating games for Apple platforms. CrossOver ships D3DMetal under its own
   arrangement with Apple. The licence gives Playport no right to put the
   framework in an IPA for testers. It also conflicts with Playport's
   Corresponding Source obligations (DISTRIBUTION.md).

The part of Apple's work that *is* usable on iOS is **Metal Shader Converter**
(DXIL → metallib, iOS 17+, argument buffers tier 2). That is what Madeira's
D3D12 path uses. Madeira's analysis also notes that Apple's licence forbids
reverse engineering D3DMetal.

## 4. Why Madeira chose Wine ARM64EC + FEX + DXMT

These reasons are from `upstream/madeira/ARCHITECTURE_ANALYSIS.md` §4–6
(2026-08-25) and its README:

- **No Vulkan in the middle.** DXMT targets Metal directly ("one less
  translation layer"). Its shaders compile DXBC → AIR, the same LLVM-based IR
  Apple's own Metal compiler produces, so no MSL text is compiled at run time.
- **Geometry shaders and tessellation.** DXMT emulates geometry shaders with
  mesh/object shaders (`dxbc_converter_gs.cpp`) and maps tessellation to Metal's.
  Missing geometry shaders are the "fatal DXVK blocker" on MoltenVK.
- **It already had a Wine integration** (winemetal unix calls) that fits a Wine
  running as one process, and a native mode. The Metal APIs it uses are the same
  on iOS, so porting was mostly a matter of SDK and feature-set changes.
- **D3DMetal is proprietary and x86_64-hosted**, so it is ruled out (§3).
  CrossOver's use of DXMT beside D3DMetal counted as evidence that Wine + DXMT is
  a proven combination.
- **Licensing** at the time: DXMT was MIT, FEX MIT, Wine LGPL, all compatible
  with Madeira's GPL-3.0. The Madeira Converter Exception exists to keep the MSC
  (D3D12) route open.
- **CPU side:** ARM64EC with FEX's `xtajit64` emulates only the game's own x86
  code. Wine and DXMT run as native arm64, and Madeira ruled out a Linux VM or
  full-system emulation as far too slow.

Madeira's analysis estimated the overhead against native Metal at 5–15 % for
DXMT, 15–30 % for vkd3d-proton → MoltenVK, and 5–15 % for a native D3D12 → Metal
layer. These are estimates, not measurements.

## What would change this

- **KosmicKrisp adds iOS.** DXVK and vkd3d-proton become possible on a
  conformant Vulkan driver. That would give a real A/B test against DXMT, and a
  well-supported D3D12 path.
- **DXMT's d3d12 gains DXIL**, or a Playport patch adds MSC for DXIL. Then D3D12
  can come through the tree we already carry. This needs a new decision
  (decision 0003 limits Playport to D3D 10/11) and a reading of the MSC licence
  (decision 0006).
- **A D3D11 title that is GPU-bound, or bound by DXMT's CPU work, on the phone.**
  Only then would comparing D3D11 layers pay off. Until then, the effort belongs
  in FEX and in DXMT's per-pass GPU cost.

## Sources

- `upstream/madeira/ARCHITECTURE_ANALYSIS.md` §4–6; `upstream/madeira/research/madeira-d3d12/README.md`, `PARKED-2026-09-16-ue5-state.md`
- Decisions [0003](../decisions/0003-runtime-backend.md), [0006](../decisions/0006-licence.md), [0007](../decisions/0007-dxmt-on-upstream.md)
- 3Shain/dxmt at 7c8dee1: `meson.options` (`enable_d3d12`), `src/d3d12/`; GitHub commit history of `src/d3d12`
- https://github.com/3Shain/dxmt/discussions/15 (DXMT vs D3DMetal synchronization; why DXMT does not use MSC)
- https://support.codeweavers.com/miscellanous/advanced-settings-in-crossover-mac-26 (CrossOver 26 backends and the per-game Auto choice)
- https://github.com/utmapp/d3dmetal-native (D3DMetal is x86_64-only and needs the GFXT host)
- https://docs.mesa3d.org/drivers/kosmickrisp.html (macOS 26+ only, no iOS yet)
- https://github.com/KhronosGroup/MoltenVK/pull/1815 (geometry shader emulation, unmerged)
- https://developer.apple.com/games/game-porting-toolkit/, https://developer.apple.com/metal/shader-converter/

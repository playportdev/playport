# 0186: DXVK skips a draw whose pipeline is still compiling

**Status:** accepted, 2026-11-13, by the owner (grilling session on cold shader compiles). Not
built yet. Evidence: [cold shader compiles](../evidence/2026-11-13-cold-shader-compiles.md).
Companion records: [0185](0185-kosmickrisp-builds-cheaper-msl-under-one-compile-budget.md) and
[0187](0187-pipeline-records-and-shader-preparation.md). In the spirit of
[0153](0153-rdr2s-settings-are-every-games-defaults.md): one default for every game.

## Context

- **D3D11 freezes, D3D12 does not.** KosmicKrisp does not offer fast-linking pipeline libraries
  (0158 keeps its GPL off), so DXVK compiles every whole pipeline at its first draw, on its one
  `dxvk-cs` thread, and the game's frame waits.
  - THPS3+4 froze 77, 125 and 79 s on a cold cache.
  - Moonlighter 2's frame gaps over 1 s were 89 % compiling.
  - D3D12 games under vkd3d-proton create their pipelines at load on several threads, so RDR2
    compiles 800 s cold and barely stalls.
- **A cache is not guaranteed.** A first play, a purge by iOS, an iOS update or a KosmicKrisp
  change that alters its MSL all leave the caches cold. 0185 makes each compile cheaper, but a
  level's hundreds of new pipelines still take tens of seconds.
- **Others skip the draw.** Projects that run DXVK on weak or non-fast-linking drivers ship a
  patch that compiles on DXVK's workers and skips the draw meanwhile: the Android Wine front ends,
  and the macOS DXVK builds' async option.
  - Upstream DXVK declines it, because skipping a draw is not accurate rendering, and relies on
    fast-linking drivers, which the phone lacks.

## Decision

- **Wait, then skip.** On a graphics pipeline miss, DXVK queues the compile to its workers at high
  priority and waits up to 30 ms (about two frames at 60 FPS).
  - If the pipeline is ready, the draw renders.
  - If not, the draw is skipped and later draws use the pipeline once it is built.
- **Only where a skip is invisible soon.** A draw may be skipped only when every render target it
  binds has been drawn to in each of the last 5 frames. Other draws compile synchronously as
  today: one-off passes such as probe or cubemap bakes, and the first draws into a new target.
  Compute dispatches always compile synchronously.
- **Scope.** DXVK's graphics pipelines, so Direct3D 9, 10 and 11 alike.
  - vkd3d-proton is untouched (D3D12 builds its pipelines at creation).
  - So is DXMT ([0100](0100-vulkan-is-the-direction.md)).
- **Budget.** The worker compiles share KosmicKrisp's compile budget (0185) as builds a draw is
  waiting for.
- **Default on.** On for every game, dev and release.
  - A DXVK option turns it off; a compatibility entry's graphics options set it for a title that
    renders wrongly.
  - A dev build sets it through Graphics options
    ([0137](0137-graphics-options-set-any-variable.md)).
  - There is no game page toggle.
- **A `patches/dxvk` patch.** `Class:` feature; `Offered-upstream:` no, since upstream declines
  the approach.
- **Gate.** The same as 0185: the Hollow Knight smoke run, and the owner's cold play of THPS3+4,
  Moonlighter 2 and Witcher 3.

## Why

- **It turns freezes into late geometry,** with no driver work: the only way to keep a first play
  responsive while hundreds of pipelines compile.
- **The 30 ms wait** keeps small pipelines (most build in under 100 ms once 0185 lands) from ever
  showing as missing for more than a frame or two.
- **The 5-frame rule** keeps a skip from leaving a permanent artefact: a target drawn every frame
  is drawn again next frame.

## Costs

- **What a player sees:** objects, effects or post-processing missing for the length of a compile
  in a scene's first moments.
  - A temporal effect may carry the gap for a few frames.
  - A title where that is unacceptable gets the off key.
- **More DXVK to own:** a patch carried on every DXVK rebase.

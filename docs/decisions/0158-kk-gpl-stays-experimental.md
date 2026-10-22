# 0158: KosmicKrisp's graphics pipeline library stays experimental, off by default

**Status:** accepted, 2026-10-22, by the supervisor for the owner (the owner was away; the
session ran unattended), from G5's evidence, as the plan's G6 step required
([PLA-424](https://linear.app/playportdev/issue/PLA-424);
[plan outcome](../plans/finished.md#kosmickrisp-graphics-pipeline-library)). It keeps the
owner's 2026-10-21 decision: full GPL, staged behind `MESA_KK_EXPERIMENTAL=gpl`, off by default
until the phone shows it works. Evidence:
[host](../evidence/2026-10-21-kk-gpl-host.md) and
[phone](../evidence/2026-10-22-kk-gpl-phone.md#g5c-separate-links-with-an-unspecified-topology-class-mesa-0101-hollow-knight-twice-with-the-flag-on),
dev IPA `0712b0cec80845d5147f6aa823625c270e07ecf1134e183f6a4959308ae00f56`.

## Decision

- **Behind the flag only.** KosmicKrisp exposes `VK_EXT_graphics_pipeline_library` and its
  `graphicsPipelineLibrary` feature only when `MESA_KK_EXPERIMENTAL=gpl` is set
  (`patches/mesa` 0096–0101). A dev build sets it per game in Graphics options
  ([0137](0137-graphics-options-set-any-variable.md)).
- **Default off.** No compatibility entry, `LaunchSettings.everyGame` default or release build
  sets it. Without the flag, KosmicKrisp builds whole pipelines as before: nothing changes.
- **Release unchanged.** The release app ignores the Graphics options row, so it never turns
  GPL on.

## Why

- **It works.** With the flag on, Hollow Knight (Steam 367520) fast-links 40 of 40 pipelines in
  two launches, with 0 `link FAIL`. On the second launch, the 54 library shaders come from Mesa's
  disk cache, and the 40 links take 40 ms in all. The game renders as with the flag off, at
  60 FPS.
- **No benefit has been measured.** Hitches are the same on and off: gaps over 0.3 s were 35 and
  36 on, against 38 off. First frame is +11.2 s on, +11.1 s off. Hollow Knight has no stall for
  GPL to remove, because with the flag off its 64 whole pipelines all come from the pipeline
  cache (`deserialized=64`).
- **It has costs.**
  - Memory: 135 more live shaders, 40 more pipelines and about 1.6 MB more MSL (1.9 MB against
    0.3 MB).
  - A cold cache: about 1.2 s of link builds on the draw path in all (up to 102 ms each), on top
    of the library compiles.
  - DXVK still builds every optimized pipeline in the background, which adds load on
    `MTLCompilerService` ([0139](0139-kosmickrisp-drops-costly-unroll-hints-and-skips-known-failing-msl.md)).
- **Not measured:** a title whose pipelines are not cached (Portal 2's chapter loads; Portal 2
  was not installed), D3D12 through vkd3d-proton, and GPU time on against off (`pp perf`).
- **Not conformance-tested.** No Vulkan CTS runs here. A layer or a stencil export with the
  flag on has not been exercised on the phone.

## What would change it

[PLA-429](https://linear.app/playportdev/issue/PLA-429): a title whose pipelines are not cached
shows a clear stall reduction with the flag on, with the same rendering, and D3D12 and GPU time
show no regression. A new record would then turn the flag on by default.

## Follow-ups

- [PLA-430](https://linear.app/playportdev/issue/PLA-430): with the flag off, the whole-pipeline
  path lowers DXVK's `0x1` sample mask at one sample as a partial mask. That adds a sample-mask
  write, and KK_WORKAROUND_7's discard, to every fragment shader.
- [PLA-428](https://linear.app/playportdev/issue/PLA-428): the link key hashes the dynamic blend
  constants. The layer and stencil-export separate-link rules are untested on the phone.
- [PLA-425](https://linear.app/playportdev/issue/PLA-425): native Vulkan games (RDR2) create
  whole pipelines themselves and do not use GPL. Their compile stalls are tracked there.

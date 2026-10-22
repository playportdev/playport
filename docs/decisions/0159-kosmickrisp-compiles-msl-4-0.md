# 0159: KosmicKrisp compiles MSL 4.0 on iOS 27

**Status:** accepted, 2026-10-22, by the supervisor for the owner (the owner was away; the
session ran unattended), from PLA-437 step 4's rule: no compile failure, a cold stall at least
10% lower on Portal 2 and Hollow Knight, and the Hollow Knight smoke gate
([PLA-437](https://linear.app/playportdev/issue/PLA-437)). Evidence:
[cold cache](../evidence/2026-10-22-kk-gpl-cold-cache.md#msl-40-against-41-and-library_size_opt-cold-pla-437-step-4),
dev IPA `a9867db432f0ca851d316db1d42b1096ad1f0124db7719f9749778acc3704319`.

## Decision

- **MSL 4.0 by default.** KosmicKrisp asks Metal for MSL 4.0 on every OS, iOS 27 included,
  where upstream asks for 4.1 (`patches/mesa` 0106, 0107). The MSL text is unchanged; only the
  compile option is.
- **One feature fewer.** The device no longer advertises `shaderSharedFloat32AtomicAdd`
  (`VK_EXT_shader_atomic_float`), the one feature KosmicKrisp gates on 4.1.
- **4.1 on request.** `MESA_KK_EXPERIMENTAL=msl41` (a dev build's Graphics options,
  [0137](0137-graphics-options-set-any-variable.md)) gives 4.1 and the feature back.
- Dev and release alike.

## Why

- **Metal's front end is the cost, and 4.0 is cheaper.** On the phone the same MSL builds 2–2.6×
  faster in `newLibrary` as 4.0 (check A: a Portal 2 fragment library 350 against 136 ms, a whole
  pipeline's fragment shader 160 against 64 ms); render pipelines take the same time.
- **Games stall less with a cold cache** (two runs each, Clear first):
  - Portal 2: 14.3 s against 17.0–17.1 s (−16%); gameplay hitches 0.4 s against 0.8–1.4 s.
  - Hollow Knight: 5.3 s against 7.5–7.6 s (−30%).
  - Whole-pipeline builds take half the time (fragment median 56–66 against 146–161 ms).
- **Nothing failed:** 0 failed builds and links, the same pipelines and rendering. The Hollow
  Knight smoke gate passed.
- **Nothing used the feature:** DXVK and vkd3d-proton do not read
  `shaderSharedFloat32AtomicAdd`.

## Costs

- A native Vulkan game that wants shared float atomic add loses it (none known). Such a game
  needs `msl41`.
- Mesa's pipeline cache key includes the language version, so the first launch after this build
  compiles again what a 4.1 build had cached; Metal's own caches key on the options too.
- **Not measured:** Red Dead Redemption 2 (native Vulkan) at 4.0, GPU time (`pp perf`) at 4.0
  against 4.1, D3D12 titles. The runs measured FPS only (the same 60 FPS in the walk).

## What would change it

A title that fails or renders wrongly at 4.0 and not at 4.1, or a GPU-time regression at 4.0. A
new record would then return to 4.1, by default or per title.

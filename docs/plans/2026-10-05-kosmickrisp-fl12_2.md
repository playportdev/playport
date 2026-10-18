# Plan: Direct3D 12 feature level 12_2 on KosmicKrisp

**Linear:** [PLA-81](https://linear.app/playportdev/issue/PLA-81).
**Review:** research-only; no implementation or phone certification found for this
plan. Promoted from `.work/plans/` after removing private inventory and stale
storage/pricing assumptions. This is separate from [backend convergence](2026-10-06-kosmickrisp-default.md)
(PLA-77) and [existing Vulkan performance work](2026-10-06-vulkan-performance.md)
(PLA-72). Decision 0032's FL12_0/SM6.6 support is not FL12_2.

**Review 2026-10-13:** still research-only; no commit implements a chunk
(`build/mesa-host-test/run-vkd3d.sh` is still missing). Coordination:
- [Decision 0100](../decisions/0100-vulkan-is-the-direction.md) makes Vulkan the
  rendering direction, with DXMT to be dropped later and no DXMT-only fixes. Direct3D 12
  is Vulkan-only already, so this plan's route is unchanged; it is now part of the
  stated direction rather than a side path.
- PLA-65 (Valheim's video) is Done on Vulkan through decisions
  [0101](../decisions/0101-vulkan-shared-memory-through-metal-heaps.md) and
  [0102](../decisions/0102-unshared-texture-handle-on-request.md). The Valheim blocker
  that PLA-77 cited is gone; it was never an input to this plan.
- The PLA-72 `vulkan-performance` work is merged to main (99a38c3).
- Pins and series: `mesa` b39d173 + `patches/mesa` 0001–0035; `vkd3d-proton` 31d1f89 +
  `patches/vkd3d-proton` 0001–0004, the same as on 2026-10-05. Neither pin has moved
  since then. Mesa 0017–0035 add iOS fixes, Zink/EGL and diagnostics. None of them
  changes a feature in the tables below:
  - 0032 exposes `VK_EXT_custom_border_color` to Zink instances only, not to
    vkd3d-proton ([0093](../decisions/0093-opengl-border-colours-and-fans-on-kosmickrisp.md)).
  - 0030 keeps workaround 6 (coherent device memory) in every stage except fragment
    shaders ([evidence](../evidence/2026-10-11-kk-ios27-workarounds.md)).
- Decision 0101 enables `VK_EXT_external_memory_metal` on every iOS Vulkan device, and
  winios reports it as `VK_KHR_external_memory_win32`. This is not a feature-level input.
  vkd3d-proton's shared heaps may now see that extension, but this is untested: 0101
  covers Direct3D 11 only, and no title ran its import path.
- The Witcher 3 DX12 candidate is still blocked by AVX (PLA-43; see the candidates
  below).

**Update 2026-10-17 (RDR2 on Vulkan, [PLA-386](https://linear.app/playportdev/issue/PLA-386)):**
RDR2's own Vulkan renderer was measured on the workstation
([evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md)). It needs none of the 12_1/12_2
features below, but it hits three KosmicKrisp defects that the host mock shows. They are
chunks V0–V4 in [RDR2 on Vulkan](#rdr2-on-vulkan-chunks-v0v4), run before chunk 0. See
[Runner state](#runner-state) for what is running.

**Date:** 2026-10-05. **Kind:** research and plan.
**Status:** proposed, not executed. Research, upstream status, game requirements
and estimates below are the original snapshot, not newly verified facts. Before
execution, refresh them against the patched trees and current hardware. Current
`pins.lock` already has Mesa `b39d173` and vkd3d-proton `31d1f89`; reconcile chunk 3,
not a second automatic rebase. In particular, validate VRS emulation and any sparse
waiver against required semantics: if faithful behaviour cannot be provided, record
the blocker and leave the feature unavailable. Forced caps are never shipped.

**Pins originally read:** `mesa` 82d4f86 + `patches/mesa` 0001–0016; `vkd3d-proton` 472989a +
`patches/vkd3d-proton` 0001–0004. These are the trees in `$PLAYPORT_BUILD/run/mesa/mesa`
and `$PLAYPORT_BUILD/run/vulkan-pe/vkd3d-proton`.

**Upstream heads checked in the original research:**
- Mesa `main` b39d173 (2026-10-05). It has only 2 `src/kosmickrisp` commits past our pin,
  both trivial.
- vkd3d-proton `master`: 20 commits past the pin. None of them touches the feature-level
  gate.

**Raw material** is in `$PLAYPORT_BUILD/scratch/fl122/`:
- the Metal feature-set tables;
- the first 100 pages of the MSL 4.1 spec;
- private account inventory, kept only in the build area; never commit or copy it
  into Linear. Public test candidates below do not disclose ownership.

Measured or cited facts carry a source. Inferences are marked **(inference)**.

---

## Goal

**The owner's goal:** every Direct3D 12 game that Proton plays on Linux today should also
work here, as far as the GPU feature set decides it.

Proton's reference GPU (Steam Deck, RDNA2 on RADV) gives vkd3d-proton the full 12_2 set.
Mesa `main`'s `docs/features.txt` lists every relevant extension as DONE for
`radv/gfx10.3+`:
- interlock;
- conservative raster, where RADV reports `degenerateTrianglesRasterized` and
  `fullyCoveredFragmentShaderInputVariable`, i.e. tier 3;
- shading rate;
- mesh;
- ray query and ray tracing pipelines;
- 64-bit image atomics;
- barycentrics;
- 3D sparse;
- quad control;
- device-generated commands.

So the target is **12_2 backed by real or faithful features**, plus the vkd3d-proton
features beyond 12_2 that Proton games use (the "Proton parity" chunk).

Steps on the way:
1. `D3D12CreateDevice(..., 12_2)` succeeds on the reference phone (iPhone18,4, A19 Pro,
   `MTLGPUFamilyApple10`, iOS 27).
2. Each 12_2 part is exercised by vkd3d-proton's test suite and by a title.
3. Authorised test titles selected from the candidates below get past device creation
   and render; ownership, availability and purchases are settled with the owner.

**The phone's limits stay.**
- MultiVersus (UE 5.1, 12_0) runs Training at 26–31 fps with a 6.8–7.2 GB footprint out
  of the 8 GB limit ([evidence](../evidence/2026-09-30-d3d12-feature-level-12.md)).
- Refresh storage and installed-title state before selecting a gate title.
- So "plays" means it starts and renders. Performance comes per title afterwards.

## Settled (owner, 2026-10-05)

1. **Faithfulness.** Target what Proton plays: a feature is emulated only where games
   cannot tell the difference. The research below decides each part:
   - **Conservative rasterization is implemented properly, to tier 3.** Forspoken uses it
     on D3D12 (vkd3d-proton logs show it; its Polaris problems came from tier 1 only).
     RADV reports tier 3.
   - **VRS is reported at tier 2 and ignored.** VRS only drops shading work.
     - Shading at full rate gives the same or a better image.
     - vkd3d-proton ships exactly this itself: an emulated tier 2 for Crimson Desert on
       RDNA1, which "just exits on startup" without VRS (`device_workarounds.c`).
     - Metal has no per-draw or per-primitive coarse shading. Its rasterization rate maps
       resample the whole target, so they are no substitute **(inference)**.
     - The only visible difference is speed.
2. **vkd3d-proton's `d3d12` test suite may run on the phone** as a dev-only title,
   started from the UI. This needs a new decision record that amends 0035 for the dev
   variant only; 0012 still holds, because the UI starts it (chunk 1).
3. **Titles:** use authorised copies where possible; public candidates are below.
   Candidate lists are not permission to purchase or change installed games.
4. **The Mac** (0031): when a chunk reaches shader debugging that phone logs cannot
   settle (likely chunks 6–8), the session stops and asks the owner to borrow one.

## What 12_2 means in vkd3d-proton

`d3d12_device_caps_init_feature_level()` (`libs/vkd3d/device.c` ≈9606–9651, patched
tree):

| Level | Requires (beyond the previous level) |
|---|---|
| 12_0 | tiled ≥ tier 2 (our 0001 waives this with no `sparseBinding`), binding tier ≥ 2, typed UAV loads |
| 12_1 | **ROVs** (pixel **and** sample interlock), **conservative raster ≥ tier 1** |
| 12_2 | SM ≥ 6.5, VP/RT index without GS, wave ops, int64, depth bounds, copy-queue timestamps, typed-format casting, binding tier 3, **conservative tier 3**, **tiled tier 3**, **DXR 1.1**, **VRS tier 2**, **mesh tier 1**, **sampler feedback ≥ 0.9** |

How each tier is derived:

- **Tiled** (≈8898):
  - Tier 1 needs `sparseBinding`, `sparseResidencyAliased`, `…Buffer`, `…Image2D`,
    `residencyStandard2DBlockShape`, and a queue with `SPARSE_BINDING`.
  - Tier 2 adds `shaderResourceResidency`, `shaderResourceMinLod`,
    `residencyNonResidentStrict`, no `residencyAlignedMipSize`, and min/max filtering.
  - Tier 3 or higher adds `sparseResidencyImage3D` and `residencyStandard3DBlockShape`.
- **Conservative** (≈8923): tier 1 is the extension. Tier 2 is
  `degenerateTrianglesRasterized`. Tier 3 is `fullyCoveredFragmentShaderInputVariable`.
- **DXR** (≈8959):
  - 1.0: RT pipeline + acceleration structures, hit attributes ≥ 32, handle size == 32,
    alignments, and the vertex formats RG32F, RGB32F, RG16F, RG16_SNORM, RGBA16F and
    RGBA16_SNORM.
  - 1.1 adds `rayQuery`, `rayTraversalPrimitiveCulling`, and the formats RGBA16/RG16_UNORM,
    A2B10G10R10 and RGBA8/RG8 UNORM/SNORM.
- **VRS** (≈1002): needs `VK_KHR_fragment_shading_rate`, or the emulated tier 2
  (`d3d12_device_allow_emulated_vrs_tier_2`, `device_workarounds.c` ≈1150). The emulated
  path sets `VKD3D_SHADER_QUIRK_IGNORE_PRIMITIVE_SHADING_RATE`.
- **Mesh** (≈9103): `meshShader` + `taskShader`. vkd3d-proton turns mesh off globally
  without `VK_KHR_fragment_shader_barycentric`, as a UE5 workaround (≈1054).
- **Sampler feedback 0.9** (≈9113): `shaderInt64` + `shaderImageInt64Atomics`. The
  feedback itself is emulated in software by vkd3d-proton.

`VKD3D_FEATURE_LEVEL=12_2` forces every tier with nothing behind it. Decision 0012 and
the empty `GraphicsBackend.runtimeEnvironment` mean there is no route for it in a
shipped build. Chunk 2 uses it on a branch only.

## Which games use what (research)

Sources:
- the vkd3d-proton per-game table (`device_workarounds.c`);
- the vkd3d-proton GitHub issues;
- the vendor notes cited in each row.

| Feature | Used by (D3D12, plays on Proton) | Consequence |
|---|---|---|
| Mesh shaders | Alan Wake 2 (launch requirement; patch 1.2.10 added a non-mesh path). FF7 Rebirth. Remnant II and other UE5 Nanite titles when mesh + barycentrics exist (vkd3d #1664). vkd3d-proton: "not many games use mesh shaders outside of UE5 Nanite fallbacks" | real implementation needed. Barycentrics come with it |
| DXR, hardware RT | **Metro Exodus Enhanced Edition requires it.** Control (pinned to DXR 1.0), Hellblade, PARANOID, Persona 3 Reload, Tracing Decay, Cyberpunk, Witcher 3 Remastered, Shadow of the Tomb Raider: optional | real implementation needed (Mesa MR !43303) |
| ROV | A Plague Tale: Requiem: decals and shadows flicker without it (vkd3d #1437 → #1440). CoD Warzone (#370) | real: Metal raster order groups |
| Conservative raster | Forspoken (D3D12). Most other known uses were D3D11.3 (Just Cause 3, The Division, Watch Dogs 2) | real, tier 3, emulated through `poly` |
| VRS | Gears 5 and Gears Tactics, Hellblade 2 (#2003), Crimson Desert (**exits without it**, #3088), and many as an option | report and ignore, as vkd3d-proton does |
| Sampler feedback | none known that requires it. vkd3d-proton built the emulation (#1737–#1775) mainly for completeness and 3DMark | follows from 64-bit image atomics |
| Sparse / tiled | Monster Hunter Wilds (PRT sparse), AC Valhalla (a sparse resource) | real: Metal 4 placement sparse |
| 64-bit atomics | UE5 Nanite's visibility buffer **(inference)**. SM 6.6 | real if MSL allows (chunk 0) |
| 16-bit I/O | Resonance: A Plague Tale (#3243, pipeline creation fails without 16-bit ops) | KK has `storageInputOutput16 = false` (a CTS failure); fix it in the parity chunk |

Vulkan-native titles (Doom: The Dark Ages, Indiana Jones, both with RT required) also run
through Proton, through winevulkan straight onto the driver. The KK ray-tracing and mesh
work serves them too.

## Where KosmicKrisp and the A19 stand

Sources:
- KK: `kk_physical_device.c`.
- Metal: Apple's Feature Set Tables (2026-05-21), which put the A19 in Apple10.
- APIs: the iPhoneOS SDK headers in xtool's darwin SDK.

| Need | KK today | Metal on Apple10 | Route | Size |
|---|---|---|---|---|
| ROV, pixel and sample interlock | absent | raster order groups, Apple4+, 8 per function | lower the interlock region to `[[raster_order_group(0)]]` on the resources it touches (MoltenVK maps the extension the same way) | S–M |
| Barycentrics | absent | Apple7+ `supportsShaderBarycentricCoordinates`; per-vertex values on Apple10 | native | S–M |
| 64-bit buffer and image atomics | `KHR_shader_atomic_int64 = false` | the tables say "full set from Apple9"; third parties (naga #79, Slang, MoltenVK #1692) say MSL accepts only min/max on `atomic_ulong` | **chunk 0 probe decides** whether this is real or partly emulated | S–M |
| Compute derivatives | absent | quad and SIMD permute | `ddx`/`ddy` → `quad_shuffle` (linear quads) **(inference)** | S–M |
| Conservative raster, tier 3 | absent | **no API** (no hit in the Metal headers, no row in the tables) | `poly` pre-raster path from patch 0005:<br>• dilate each triangle by the half-pixel diagonal<br>• clip to the triangle's AABB in the fragment shader<br>• emit degenerate triangles<br>• "fully covered" from flat edge equations<br>The cost lands only on pipelines that use it | L |
| Sparse buffers and 2D/3D images | none (`kk_image.c` refuses residency). Heaps are already placement heaps with `sparsePageSize` | Metal 4 placement sparse, Apple8+ (`supportsPlacementSparse`, `MTL4CommandQueue updateTextureMappings`/`updateBufferMappings`). Unmapped reads return 0. MSL `sparse_sample` | native, 64 KiB pages. **Unknown:** whether the tile shapes equal Vulkan's standard block shapes, and whether 3D works (chunk 0) | L |
| VRS tier 2 | absent | rate maps only | the vkd3d-proton emulated tier 2 extended to KosmicKrisp | S |
| Mesh and task shaders | absent | mesh shading Apple7+, indirect Apple9+, `MTL4MeshRenderPipelineDescriptor`, 16 KB payload | NIR → MSL `[[object]]`/`[[mesh]]`. Metal footnote 6: no ray tracing in a mesh render pipeline | XL |
| DXR 1.1 | absent | RT in compute and render, Apple6+; hardware RT Apple9+ | Mesa **MR !43303** (Draft, 11 commits, 2026-08-11):<br>• acceleration structures, ray query, RT pipelines fused into one compute kernel<br>• handle size 32 and attributes 32, as vkd3d-proton requires; sets `rayTraversalPrimitiveCulling`<br>• triangle watertightness is a known gap | L |
| The rest of 12_2 | met: depth bounds (family ≥ 10), one queue with 64 timestamp bits, layer and viewport output, subgroups, int64 **(inference; chunk 0 logs it)** | — | — | — |

### Proton parity beyond 12_2

These are what vkd3d-proton uses on RADV that KK lacks:

- **SM 6.7/6.8:** KK has maximal reconvergence but no `shaderQuadControl`.
- **ExecuteIndirect tier 1.1:** `VK_EXT_device_generated_commands`.
- **Descriptor buffer or heap:** a performance path.
- **`storageInputOutput16`.**
- **`shaderFloat64`:** Metal has no `double`. D3D12 doubles are optional, and a title
  that needs them gets a compile failure. Emulate in NIR only if a title needs it.

Alternative not taken: D3DMetal and Metal Shader Converter are proprietary and would
replace vkd3d-proton (decisions 0015, 0032, 0039–0041).

## Public test candidates

These are feature-coverage suggestions from the original research, not an account
inventory or a purchase list. Recheck access, download size, prerequisites and phone
storage with the owner at the matching chunk. Remove a game only from its page with
the owner's approval; never uninstall Playport itself.

- **The Witcher 3: Wild Hunt — Remastered** (292030): optional DX12/DXR. Do not
  replace the working classic 1.32 regression copy blindly: the current-build AVX
  launch blocker is already [PLA-43](https://linear.app/playportdev/issue/PLA-43).
  An update alone is not proof that the game can reach a GPU feature gate.
  **Review 2026-10-13:** the blocker stands in the tree. The patched FEX still sets
  `SupportsAVX = false` for the iOS host (`patches/fex-port` 0009). The current build's
  `bin/x64_dx12` executable stopped at a VEX `vmovaps`
  ([evidence](../evidence/2026-10-02-witcher3-executable.md)). PLA-132's host-CPU
  switches (33162cf) disable absent ARM features and do not add AVX. The classic
  `bin/x64` copy reaches its intro on DXMT
  ([evidence](../evidence/2026-10-07-pool-x64-images.md)). Chunks 2 and 8 cannot use
  Witcher 3 DX12 until PLA-43 is fixed; its Linear state was not checked in this review.
- **Metro Exodus Enhanced Edition** (1449560): required hardware RT; proposed DXR
  gate, subject to access, storage and other launch prerequisites.
- **Shadow of the Tomb Raider** (750920): optional DXR shadows, lower priority.
- **MultiVersus:** historical UE5 SM6.6 regression, with existing phone evidence.
  Recheck availability/installation before scheduling it; no reinstall is implied.
- **3DMark** (223850): candidate Mesh Shader (1498800), Sampler Feedback (1498801),
  VRS (556150), Steel Nomad, and Solar Bay tests. Solar Bay may exercise KK RT
  through winevulkan **(inference)**. Speed Way (2019730) and Port Royal (496103)
  are additional candidates for DX12 Ultimate and DXR. Confirm licensing, price,
  availability and SystemInfo prerequisites before buying or using any test.
- **Later feature-specific games:** Alan Wake 2 or a UE5 Nanite title such as
  Remnant II for mesh; A Plague Tale: Requiem for ROV; Forspoken for conservative
  raster. Confirm each current build actually exercises the intended feature.

Online-only and anti-cheat titles are not suitable gates. A benchmark passing does
not establish compatibility for games that use different combinations of features.

## How it is checked

- **Host:**
  - `build/mesa-host-test`: mock Metal bridge reporting Apple10 and iOS 27. It fails on
    untranslated NIR, but cannot compile MSL.
  - `d3d12-caps.c` prints the levels `D3D12CreateDevice` accepts and the tiers behind
    them. Its runner `run-vkd3d.sh` is **missing from the tree**; restore it in chunk 0.
- **Phone:**
  - vkd3d-proton's `d3d12` test suite as the dev title (chunk 1), filtered per feature.
    Its pass/fail list goes in each evidence record.
  - The vkd3d-proton and KK capability log lines from `pull/s1-host.log`.
- **Titles:** 3DMark tests and the titles above.
- **Regressions:** every chunk ends with Hollow Knight (DXMT) `--until first-frame+10`
  and MultiVersus `-dx12` on Vulkan to the title screen, on the committed IPA.
- **Mac:** at the first shader bug that phone logs cannot locate, stop and ask the owner
  to borrow one (0031: attach and replay only).

## RDR2 on Vulkan (chunks V0–V4)

**Why here:** this is the KosmicKrisp feature plan, and RDR2's Vulkan route (RDR2 plan D6)
runs on KosmicKrisp with no D3D layer. The measurement
([evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md)) found:

- **Covered already:** every extension RDR2 enables except `VK_AMD_memory_overallocation_behavior`
  (it goes on without it); every SPIR-V capability its 13,233 modules use; every format and
  usage it creates; dual-source blending, depth bounds, depth clamp, clip and cull distance,
  geometry and tessellation through `poly`; one queue and one memory type. Under a
  KosmicKrisp profile on RADV it reached its landing page.
- **Not needed from this plan:** mesh, ray tracing, ROV, VRS, sparse, conservative raster,
  int64/float64, 16-bit types, subgroups, barycentrics. Chunks 0–11 below stay for D3D12
  titles; RDR2's DX12 fallback through vkd3d-proton would need only 12_0, which already works
  (H3: it played at 11_1 under the profile).
- **Missing (V1–V4):** what the game reaches and the host can test; V4 needed no driver change.

The chunks are host-only: the side copy has no phone. Each ends with commits, the mesa host
test (`build/stages/mesa.sh` `host hosttest`), the iOS build and import check of the patched
KosmicKrisp (`ios check`), `pp names`, `pp secrets` and `pp test --quick`. The phone checks
(Hollow Knight on Vulkan, then RDR2) are owed and listed per chunk.

### V0. A replay harness for captured pipelines

- **Done** (2026-10-17, PLA-386; host only). `build/mesa-host-test/run-replay.sh FOZ...`
  replays Fossilize databases on the host mock (after `hosttest`; `KK_MOCK_ICD`,
  `FOSSILIZE_REPLAY`), replays each crashed pipeline alone for its message, prints the
  crashes grouped by message, exits 1 on any. The capture/profile layer
  (`vk-capture-layer/`, profile from a device report) and the report program (`devinfo.c`)
  are beside it; [BUILDING.md](../BUILDING.md#kosmickrisp) has how to build and run them.
  Game data stays in the build area.
- **Result:** the RDR2 database gives one group, 151 graphics pipelines at
  `kk_nir_lower_descriptors.c:534: lower_tex: Assertion '!sampler' failed` (153 in the
  first replay: Fossilize skips pipelines that share a module with a crashed one, so the
  count moves between runs).

### V1. Sampling an undefined image

- **Done** (2026-10-17, PLA-386; host only, **not checked on the phone**). V0 is `1fc4605`.
  The game samples an OpUndef image with a defined sampler. `patches/mesa` 0037
  (`upstream-bug`) drops such a texture instruction (undefined result) first in
  `kk_preprocess_nir`, before the runtime's descriptor heap lowering turns the undefined
  image into `texture_heap_offset` 0 and `lower_tex` aborts on the sampler beside it.
  Mesa `main` (335d5698) has no fix. Fixing only the runtime pass was tried and moves the
  crash to `nir_vk_lower_ycbcr_tex`; the runtime is left as it is.
- `kk-host-test` builds `shaders/undef-image.frag.spvasm` (hand-written SPIR-V); it aborted
  before the patch.
- **Result:** the RDR2 replay has no crash (graphics 1,923 of 1,940 built, compute 731 of
  788; the rest are modules Fossilize refuses as unsupported, below).
- **Follow-ups (not fixed here):** 73 modules use `ImageMSArray`, which Vulkan gates on
  `shaderStorageImageMultisample` and KosmicKrisp does not report, so Fossilize skips 17
  graphics and 57 compute pipelines; and a storage image load from an undefined image
  crashes in `nir_shader_gather_info` (seen on a test shader, not in the corpus).
- **Phone, owed:** Hollow Knight on Vulkan first frame+10.

### V2. Pipeline-statistics query pools

- **Done** (2026-10-17, PLA-386; host only, **not checked on the phone**). RDR2 creates a pool
  of 8 pipeline-statistics queries (all 11 counters) without enabling
  `pipelineStatisticsQuery`; `kk_reports_per_query` reached `UNREACHABLE` at pool creation.
  `patches/mesa` 0038 (`feature`, tolerance of the application's invalid usage) gives the
  pool one report per enabled counter and records nothing between begin and end: results
  are the reset's zeros, the end sets availability, and host results and
  `vkCmdCopyQueryPoolResults` take the existing paths. `pipelineStatisticsQuery` stays
  unreported (Metal has no statistics counters).
- `kk-host-test` creates, resets (host and command), begins/ends around draws, copies
  (64-bit with availability and wait, 32-bit partial) and reads such a pool (11 values per
  query, nothing past them); it aborted before the patch.
- **Phone, owed:** Hollow Knight on Vulkan first frame+10.

### V3. Pipelines that ask for more samples than reported

- **Done** (2026-10-17, PLA-386; host only, **not checked on the phone**). RDR2 builds 96
  pipelines with `rasterizationSamples = 8`; KosmicKrisp reports 1, 2 and 4 and passed 8 to
  Metal as the pipeline's raster sample count (and as an attachment-less pass's default).
  The mock now aborts on a raster sample count the device does not support; the replay then
  crashed on 51 pipelines (one group; module skipping hides the rest).
- **Choice:** `patches/mesa` 0039 (`feature`) clamps the count Metal sees to the highest
  supported one not above the request. Failing the build instead would hand the game an
  error at load for a pipeline it can only draw into its 4-sample images; a valid
  application never asks for an unsupported count, so it sees no change. No reported limit
  changes.
- `kk-host-test` builds an 8-sample pipeline and draws it into a 4-sample image and without
  attachments; it aborted in the mock before the patch. Replay: 0 crashes again.
- **Phone, owed:** Hollow Knight on Vulkan first frame+10. What Metal itself does with an
  unsupported count was not seen.

### V4. Sampled multisample arrays without `shaderStorageImageMultisample`

- **Done, no driver change** (2026-10-17, PLA-386; host only, **not checked on the phone**).
  73 RDR2 modules declare `ImageMSArray`; Vulkan gates it on
  `shaderStorageImageMultisample`, which KosmicKrisp does not report, so Fossilize skipped 17
  graphics and 57 compute pipelines. The game itself creates them: KosmicKrisp does not
  check module capabilities.
- **What the modules do:** only 11 have a multisample array image at all, and every
  multisample image in the 73 is sampled (`Sampled 1`), read by `OpImageFetch` with a
  sample index and sized by `OpImageQuerySize`; SPIR-V needs the capability only for
  storage. spirv_to_nir implements it and only warns that it is unsupported.
- **Forced replay:** a scratch layer (build area, not committed) reported the feature to
  Fossilize and stripped it at device creation: every pipeline built (graphics 1,940 of
  1,940, compute 788 of 788), 0 crashes, no untranslated MSL; 14 MSL libraries read a
  `texture2d_ms_array` with `.read(coord, layer, sample)`.
- `kk-host-test` builds and draws `shaders/ms-array.frag.spvasm` (hand-written: declares the
  capability, fetches two samples of a 4-sample 2-layer image through a 2D array view) and
  checks the MSL has `texture2d_ms_array`. It passes with no patch;
  `shaderStorageImageMultisample` stays unreported.
- Follow-up found in V1: [PLA-387](https://linear.app/playportdev/issue/PLA-387)
  (storage load from an undefined image), fixed in H6b (mesa 0040).
- **Phone, owed:** Hollow Knight on Vulkan first frame+10; that Apple's compiler takes the
  `texture2d_ms_array` reads, and that the A19 makes a 2D multisample array texture, are not
  checked.

### Not in V0–V4

- The VRAM message box ("does not meet the minimum requirements for video memory"): found in
  H2 ([evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#video-memory-warning-2026-10-17-h2))
  to come from `RDR2.exe` when its own Vulkan instance sees a `DEVICE_LOCAL` heap of 1,927 MiB
  or less. The profile runs showed it because the capture layer gave that instance a 256 MiB
  heap (RADV's RDR2 driconf). KosmicKrisp's 8 GiB heap is above the threshold (inference: no box
  on the phone), so PLA-269 needs nothing for it.
- The phone run of RDR2: after PLA-295 (launcher) and PLA-300 (first native Vulkan title).
- What the host cannot show: Apple's MSL compiler, `poly` at run time, depth bounds on the A19.
- **Linear-tiled images KosmicKrisp does not support** (found in H1,
  [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#in-story-mode-2026-10-17-h1)): the game
  never queries image format properties and creates linear images with color-attachment usage,
  3D, 2–8 layers (Story mode) or 7 mip levels; KosmicKrisp reports none of these, and
  `vkCreateImage` makes a buffer-backed Metal texture anyway. H1b, at the phone's heap: the same
  rows in Story mode, and the Graphics settings page creates about 4,300 more, never bound to
  memory. H7 (mesa 0041, [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#linear-images-h7)):
  the arrays, 3D images and mip chain get a texture of Metal's own layout. The 2D ones, colour
  attachments included, stay buffer-backed, which Metal allows. Whether the game accesses those
  three groups through a mapping is not measured; if it does, it sees other data.

## Runner state

- **Branch:** `dev/pla-386-rdr2-vulkan-kk`, off `main` at f7ac25f, in the side copy
  `$PLAYPORT_BUILD/worktrees/pla-386-rdr2-vulkan` (owner-authorized 2026-10-17, with its own
  reflinked `.work/cache`, `.work/inputs` and, since 2026-10-18, `.work/run`, with build
  directories that named main's path removed). The owner authorized it to build (beyond
  decision 0069); no install or phone. Its build records are not canonical (the build path
  differs). Not merged, not pushed.
- **Done:** the measurement (2026-10-17, PLA-386, evidence above); V0 (replay harness,
  `1fc4605`); V1 (undefined image, mesa 0037, `33e2194`); V2 (pipeline-statistics pools,
  mesa 0038, `efed211`); V3 (8-sample pipelines, mesa 0039, `f4f407b`); V4 (sampled
  multisample arrays: host test only, no patch); H1 (Story mode captured and replayed: 1,948
  graphics and 788 compute pipelines, 0 crashes on 0001–0039, no new patch; linear-tiled
  images found, [above](#not-in-v0v4)); H2 (the video-memory warning: the SGA instance's heap
  size, box at 1,927 MiB or less, not 1,928; a profile-layer artifact at 256 MiB, [above](#not-in-v0v4));
  H1b (capture layer fixed, `73a9323`; Story mode at an 8,192 MiB heap: the game picks the same
  `Safe` settings, no box, 1,950 graphics and 788 compute pipelines, 0 crashes on 0001–0039, no
  new patch; the Graphics settings page adds about 21,000 unbound probe images,
  [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#story-mode-at-the-phones-heap-2026-10-18-h1b));
  H3 (capture layer budget by KosmicKrisp's rule, `1e86305`; RDR2 on D3D12 through Proton's
  vkd3d-proton under the profile: feature level 11_1 and SM 6.5 there, Story mode played, no
  linear images, 1,607 graphics and 758 compute pipelines, 0 crashes on 0001–0039 once the
  profile's float-controls gate is bypassed, no new patch,
  [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#dx12-route-2026-10-18-h3));
  H4 (the dev IPA with mesa 0037–0039 built in this copy at `99c60b9`: sha256 `1fb1fb9e…`,
  `verify-ipa` 85 checks passed, 0 failed; build records not committed, since their changed rows
  come from the copy's path, [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#dev-ipa-with-mesa-00370039-h4));
  H6 (tooling: `run-replay.sh --bypass-feature-gate`, `667f8fe`, replays both corpora as the
  scratch layers did, with no scratch layer; the profile copies float controls, subgroup sizes,
  the driver ID and extension formats, and devinfo prints them,
  [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#replay-and-profile-tooling-h6));
  H6b ([PLA-387](https://linear.app/playportdev/issue/PLA-387), mesa 0040: a storage image
  read, write or size query of an undefined image no longer crashes; host test only, replays
  unchanged, [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#host-fixes-2026-10-17-chunks-v0v4));
  H7 ([PLA-388](https://linear.app/playportdev/issue/PLA-388), mesa 0041: a linear image Metal
  cannot make from a buffer (array, 3D, mip chain) gets a texture of Metal's own layout. The mock
  checks Apple's rules for buffer textures; host test, replays unchanged,
  [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#linear-images-h7)); H7b (PLA-388, desktop
  runs; the capture layer logs linear-image use: with a discrete device type RDR2 makes 2 linear
  images instead of 521 and still picks `Safe`; the CPU writes the 9 mip chains and 3 of the 3D
  images through the mapping and the GPU writes 1 more for host reads, so 0041's fallback is
  enough only for the arrays,
  [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#linear-image-use-and-the-device-type-h7b)).
  Host only; not checked on the phone.
- **Blocked:** H5 (Apple's Metal compiler for Windows under Wine on the replay's MSL). The
  download needs an Apple account sign-in, and the tools' licence is not published, so whether
  Wine on Linux is permitted is unknown. Nothing downloaded; the owner's step is in the
  [evidence](../evidence/2026-10-17-rdr2-vulkan-needs.md#apples-metal-compiler-on-the-generated-msl-h5).
- **Queue (owner-approved 2026-10-17, host only):** next H5d (commit the H5 results under the
  owner's Wine decision of 2026-10-18, fix `fcanonicalize`); then H8 the dev IPA with mesa
  0037–0041. Then chunk 0 below (needs the phone).
- **Running:** none. Reports: `h1-h3.md` (H1), `h2.md` (H2), `h1b.md` (H1b), `h3.md` (H3),
  `h4.md` (H4), `h5.md` (H5), `h5c.md` (H5, results not yet committed), `h6.md` (H6), `h6b.md`
  (H6b), `h7.c6627d62.md` (H7), `h7b.md` (H7b).
- **Phone:** not used by these runs; Hollow Knight on Vulkan first frame+10 is owed for V1–V3,
  H6b and H7 (mesa 0037–0041), on an IPA with 0041 (H4's has 0037–0039 only), then RDR2 after
  PLA-295 and PLA-300.
- **Reports and scratch:** `$PLAYPORT_BUILD/agent-notes/rdr2-vk/` in the main checkout
  (capture runs, Fossilize database, analysis); child reports under
  `agent-notes/rdr2-vk/reports/` of the side copy.

## Chunks

Each chunk is one writer session that ends with commits, an evidence record and the
plays above.

### 0. Facts on the device

- Restore `run-vkd3d.sh`.
- Diagnostics patches: KK logs, at device init:
  - `supportsPlacementSparse`;
  - sparse tile sizes (2D, 2DArray and 3D at 64 KiB, for the common formats) against
    Vulkan's standard shapes;
  - raster order groups, barycentrics, raytracing and function-pointer support;
  - the result of compiling MSL that uses `atomic_fetch_add`, `compare_exchange` and
    `max` on `device atomic_ulong*` and on a `ulong` read/write texture.
- vkd3d-proton logs every input of the 12_1/12_2 gate.
- Evidence: `<date>-fl12_2-baseline.md`.

### 1. The test suite as a dev title (owner's yes)

- A decision record amending 0035 for the dev variant.
- Build vkd3d-proton's `tests/d3d12` in the `vulkan` stage, dev only. `pp verify
  --variant release` fails the release IPA if it carries the suite.
- The dev library shows it, and Play runs it with a test filter given as launch
  arguments.
- `pp ui --play` collects its output.
- Record a baseline pass/fail list at today's caps.

### 2. What titles call (branch only, never merged)

- Force 12_2 at build time on a throw-away branch.
- Run 3DMark (once bought), Witcher 3 DX12 (after PLA-43) and Metro EE if installed.
- Record which feature each one hits first. This reorders chunks 4–8.

### 3. Reconcile the Mesa move

- The original dependency plan's Mesa move has already changed the pin. Check what
  landed or remains; this is not a separate upgrade. (Review 2026-10-13: any later move
  now rebases 35 Mesa patches, not 16, including the Zink and EGL patches.) Coordinate any remaining move
  with [Proton alignment](2026-10-05-proton-arm64-alignment.md) (PLA-76) and respect
  held/frozen dependencies.
- Upstream MR !44786 ("kk: Add geometry shader support") may replace or conflict with
  our 0005. Re-run the GS/XFB host tests either way.

### 4. Cheap native features

- Barycentrics, pixel and sample interlock (→ ROV), 64-bit atomics (as chunk 0 found
  them), compute derivatives.
- Retire vkd3d 0002's waivers wherever the feature is now real, in a new decision that
  amends 0032.

### 5. Conservative rasterization to tier 3 → **12_1**

- Implement it as in the KK table above.

### 6. Sparse → tiled tier 2/3

- Retire vkd3d 0001.
- If the A19 cannot do 3D placement sparse with standard block shapes, investigate
  faithful emulation and document the result. The original draft suggested a tier-3
  waiver like 0001; do not advertise tier 3 without the required behaviour.

### 7. Mesh and task shaders

- Order: mesh, then task; direct, then indirect; multiview and queries last.
- A mesh pipeline that uses ray queries fails with a log line, because Metal cannot
  build it.
- **Mac likely.**

### 8. Ray tracing: port !43303 → DXR 1.1

- Port it as `patches/mesa`, keeping authorship.
- Expose the acceleration-structure vertex-format features.
- Title: Witcher 3 DX12 with RT, then Metro EE.
- **Mac likely.**

### 9. VRS emulation and the 12_2 gate

- vkd3d patch for the emulated tier 2 on KosmicKrisp.
- A decision record listing every emulated part.
- Done when `D3D12CreateDevice(12_2)` succeeds on the phone, and Speed Way and the 3DMark
  feature tests run.

### 10. Proton parity

- Quad control, then SM 6.7/6.8.
- `storageInputOutput16`.
- Device-generated commands.
- The descriptor-buffer path.
- float64 only if a title needs it.

### 11. Titles and performance

- `pp perf` with the owner at the controller, at 720p with a 60 fps target.

**Rough size (inference):** 0–3 take a few sessions; 4 is 2–3; 5 is 2–3; 6 is 3–4;
7 is 5+; 8 is 3–4; 9 is 1; 10 is 3+.

**Milestones:**
- UE5 SM 6.6 with no waivers after chunk 4.
- 12_1 after chunk 5.
- 12_2 after chunk 9.

## Order across the plans

The original order followed the dependency strategy's step 3, with one shared Mesa
move. Reconcile that historical dependency with PLA-76 before execution. Chunks 0–2
are diagnostics, the test title and a branch; they decide what remains worth porting,
not permission to advance pins independently.

## Risks

- **64-bit atomics** in MSL may be min/max only. Nanite's main path needs only max
  **(inference)**.
- **Untested KosmicKrisp workarounds on iOS 27** (Review 2026-10-13,
  [evidence](../evidence/2026-10-11-kk-ios27-workarounds.md)). iOS 27 turns off
  workaround 3 (subgroup ballot/any/all inside a conditional) and workaround 5 (an
  always-taken discard drops earlier UAV writes). No title has shown either bug, but
  12_2's wave ops and chunk 4's ROV and pixel UAV work would hit them first. The A19's
  Apple10 family was assumed from Apple's tables and has not been read from a log;
  chunk 0 logs it.
- **Memory and compile time:**
  - the fused RT kernels and mesh pipelines are large MSL;
  - the app is near 8 GB in a UE5 title;
  - RT titles are heavier still.
- **!43303 was a draft in the research snapshot.** Recheck its current status before
  porting; preserve authorship and the required patch trailers.
- **Mesa moves weekly**, so every KK patch adds rebase cost.
- **Games' own checks**: vendor IDs, NVAPI/AGS and VRAM can refuse a start after 12_2
  passes. Chunk 2 finds this early.
- **Storage**: 12_2 titles mean uninstalling others, one feature at a time.
- **3DMark**'s SystemInfo may need workarounds.

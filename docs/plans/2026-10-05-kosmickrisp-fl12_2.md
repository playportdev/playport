# Plan: Direct3D 12 feature level 12_2 on KosmicKrisp

**Linear:** [PLA-81](https://linear.app/playportdev/issue/PLA-81).
**Review:** research-only; no implementation or phone certification found for this
plan. Promoted from `.work/plans/` after removing private inventory and stale
storage/pricing assumptions. This is separate from [backend convergence](2026-10-06-kosmickrisp-default.md)
(PLA-77) and [existing Vulkan performance work](2026-10-06-vulkan-performance.md)
(PLA-72). Decision 0032's FL12_0/SM6.6 support is not FL12_2.

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
- Run 3DMark (once bought), Witcher 3 DX12 and Metro EE if installed.
- Record which feature each one hits first. This reorders chunks 4–8.

### 3. Reconcile the Mesa move

- The original dependency plan's Mesa move has already changed the pin. Check what
  landed or remains; this is not a separate upgrade. Coordinate any remaining move
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

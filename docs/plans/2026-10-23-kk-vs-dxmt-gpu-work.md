# Plan: what KosmicKrisp asks of the GPU where DXMT asks less, and the throttled-frame gap that follows

**Linear:** [PLA-439](https://linear.app/playportdev/issue/PLA-439) (this plan);
parent [PLA-72](https://linear.app/playportdev/issue/PLA-72) (the Vulkan-performance
umbrella, still In Progress). Related: [PLA-77](https://linear.app/playportdev/issue/PLA-77)
(KosmicKrisp default), [PLA-430](https://linear.app/playportdev/issue/PLA-430)
(sample-mask lowering, Done as mesa 0103).

**Date:** 2026-10-23. **Kind:** plan — desk research done, no build and no phone run
performed while writing it; execution not started. **Branch:** main checkout, branch
`dev/kk-proton-parity` at HEAD `1948309` (this plan is documentation only; the branch's
own work is PLA-431 and is unchanged by it).

**Pins read** (`pins.lock`, unchanged): `mesa` b39d173 + `patches/mesa` 0001–0120;
`dxvk` e5ffd0f + `patches/dxvk` 0001–0005; `vkd3d-proton` 31d1f89 + `patches/vkd3d-proton`
0001–0004; `dxmt` 68af85e + `patches/dxmt` 0002–0012 + `patches/dxmt-port` (frozen, decision
0054). **Trees read:** `$PLAYPORT_BUILD/run/mesa/mesa/src/kosmickrisp`,
`$PLAYPORT_BUILD/run/dxmt-patched/dxmt/src`, `$PLAYPORT_BUILD/run/vulkan-pe/dxvk`
(including `subprojects/dxbc-spirv`).

**Scope:** the D3D11 route only (DXVK → KosmicKrisp) against **DXMT D3D11**, which is the
only thing DXMT runs. vkd3d-proton shares KosmicKrisp, so a finding that is KosmicKrisp-wide
is noted as such and read against vkd3d's +4 % GPU ms / +12 % energy, and a finding that is
DXVK-specific is read against that split. [PLA-72's plan](2026-10-06-vulkan-performance.md)
stays the exit-criteria owner; this plan's job is to name the remaining work, in order.

## Why a work gap becomes a much lower frame rate

The throttled figures are the same gap seen at the phone's power budget, not a separate
defect. From the cooled native/free runs ([profile](../evidence/2026-10-08-vulkan-perf-profile.md)),
once pressure reaches level 10 the P cores park, the GPU clock follows CPMS ÷ energy-a-frame,
and time a frame is its inverse: KosmicKrisp's GPU time a frame doubles (13.4–16.15 ms
against DXMT's 7.46–8.15) and FPS halves (52–58 against 91–109) while energy a frame is
+40–104 %. Warm and cool records agree on the underlying quantities: GPU ms +29 %
([standing](../evidence/2026-10-08-vulkan-perf-standing.md)) and +14 % in the 2026-10-22
stationary ABBA ([resume](../evidence/2026-10-22-vulkan-perf-resume.md)), tiler busy ms/frame
+25 %, Mi/f +11–44 %, sys mJ/f +12–17 %. **Judge every candidate below as bytes moved a frame,
ALU a frame, or lost pass overlap** — never as frames.

`patches/mesa` 0019 (texture usage that keeps lossless compression, mirroring `patches/dxmt`
0009's rule) is the one lever in this area already kept: **21–33 % less phone energy a frame**
in warm native/60 pairs ([typeless-usage](../evidence/2026-10-08-vulkan-perf-typeless-usage.md)).
That is also the strongest evidence that memory layout and compression is where this energy
lives — and that more of it is unclaimed.

## The differences, ranked, with code

Facts marked **measured** carry their record; **inferred** means read from the code, not run.
Paths are under `$PLAYPORT_BUILD/run/mesa/mesa/src/kosmickrisp` (KK),
`$PLAYPORT_BUILD/run/dxmt-patched/dxmt/src` (DXMT) and
`$PLAYPORT_BUILD/run/vulkan-pe/dxvk` (DXVK).

### 1. Where an image's memory comes from — shared, sparse, aliased heaps vs private standalone textures (inferred, untested with 0019 on; largest)

- **KK:** every `vkAllocateMemory` is a placement heap — `vulkan/kk_bo.c:66 mtl_new_heap(...)`,
  `bridge/mtl_heap.m:23-26` `type = MTLHeapTypePlacement` **and `sparsePageSize =
  MTLSparsePageSize16`** — and `vulkan/kk_bo.c:72` then creates
  `mtl_new_buffer_with_length(handle, size_B, 0u)`, a **whole-heap CPU-mapped alias**
  (`bo->map`, `bo->cpu = mtl_get_contents(map)`, `bo->gpu = mtl_buffer_get_gpu_address(map)`).
  `vulkan/kk_private.h:47-50` fixes the options to `STORAGE_MODE_SHARED | DEFAULT_CACHE |
  TRACKING_MODE_UNTRACKED`; images live inside those heaps
  (`bridge/mtl_heap.m mtl_new_texture_with_descriptor` copies `hp.resourceOptions`).
- **DXMT:** `dxmt/dxmt_texture.cpp:206,244` and `d3d11/d3d11_context_impl.cpp:5586` set
  `WMTResourceStorageModePrivate`; textures are standalone `newTextureWithDescriptor`
  (`d3d11_resource_helper.cpp`, `winemetal/unix/winemetal_unix.c:5069`). The King's Pass
  captures confirm it: descriptor word 13 is **0 = shared inside a placement heap with a
  whole-heap buffer** on the Vulkan route against **2 = private, standalone** on DXMT
  ([kings-pass-capture](../evidence/2026-10-08-vulkan-perf-kings-pass-capture.md)).
- `allowGPUOptimizedContents` is computed true for Hollow Knight's images
  (`vulkan/kk_image_layout.c:87 kk_image_layout_can_optimize` → `bridge/mtl_heap.m:54`), so
  the driver *asks*; whether Metal can honour it for a sparse, CPU-aliased, heap-backed
  resource is the open question. Apple's conditions for optimised layouts (heaps, aliasing,
  sparse pages) are not in this repository — **check them against Apple's own text before
  believing this.**
- Corroborating measurements: Mi/f +11.4 % at native/60, +44 % at native/free in the cooled
  pair, and GPU-driver memory **1.08 GB on Vulkan against 0.35–0.39 GB on DXMT**
  ([resume](../evidence/2026-10-22-vulkan-perf-resume.md), "a separate, uninvestigated lead").
- Status: **the combination is untested.** `private_memory` (chunk 8's draft) was measured
  before 0019 existed and its scene targets still carried pixel-format-view (`0x15`), so that
  record "says nothing about compression". `patches/mesa` 0020 is now the `draws`/`solid`
  diagnostics, so a port needs a new number.

### 2. Copies and resolves: Metal 4 compute-encoded blit commands vs DXMT's blit encoders (inferred; D3D11-shape difference)

- **KK:** `vulkan/kk_cmd_copy.c` records every `vkCmdCopyImage`/`CopyBufferToImage`/`CopyBuffer`
  in a **compute encoder** (`cs_get_compute(cmd)` at `:29,94,124,183,300`), and the texture→buffer→texture
  fallback inserts `mtl_barrier_after_encoder_stages(encoder, MTL_STAGE_BLIT, MTL_STAGE_BLIT)`
  between its two halves (`:~289`) — two round trips through memory plus a GPU sync for one
  logical copy.
- **DXMT:** dedicated blit encoders (`dxmt/dxmt_context.cpp:1122,1219,1251,1284
  blitCommandEncoder()`, counted by `dxmt/dxmt_statistics.hpp:50 blit_pass_count`), driven
  straight from D3D11 (`d3d11/d3d11_context_impl.cpp` `ResolveSubresource` → `CopyTexture`,
  `GenerateMips`). The captures show the same frame role as "a blit encoder on DXMT and a
  compute encoder on Metal 4".
- Cost: Hollow Knight's full-screen grabs are 13.8 MB read and 13.8 MB written each at
  2736×1260, 3–10 of them a frame. Metal's blit encoder uses the copy units and tile memory;
  a compute-encoded blit does not.

### 3. Attachment load/store bookkeeping: DXMT optimises an encoder list, KosmicKrisp has none (partly measured; small on this frame)

- **DXMT** defers its own encoder list and optimises it before encoding
  (`dxmt/dxmt_context.cpp` ~1340–1500): a clear folds into the next pass's load action
  (`clear_pass_optimized`), a store becomes `WMTStoreActionDontCare` when a later clear
  overwrites it (`:1403-1408`), resolves fold into store actions, consecutive passes with the
  same attachment signature merge (`render_pass_optimized`, `:1475-1489`), and encoders with
  no data dependency reorder (`DXMT_ENCODER_LIST_OP_SWAP` / `hasDataDependency`).
- **KK** encodes what it is given, and on a pass restart forced by a barrier it **forces LOAD
  on every attachment** (`vulkan/kk_cmd_draw.c:456-486`), with `force_attachment_load`/`force_attachment_store`
  set from `!is_whole_framebuffer` or SUSPEND/RESUME (`:433,439`). Stores stay `Unknown`; the
  capture shows `setColorStoreAction 1 / setDepthStoreAction 1 / setStencilStoreAction 1` at
  every pass end.
- Measured instance: the stored depth in King's Pass pass 20, **17.2 MB a frame where DXMT
  stores none**. Measured headroom: `MESA_KK_DEBUG=passes` (mesa 0113) counted **zero fold,
  merge or dead-DS candidates** on Hollow Knight's DXVK frame, and `ds_dont_care` (0115) had
  no eligible discard. So the rule is real but DXVK's command stream is already folded —
  keep this behind the copy item, not in front of it.

### 4. Sync: an all-stages barrier at every encoder end vs DXMT's per-subresource, per-stage fences (inferred; bounded by measurement)

- **KK:** `vulkan/kk_cmd_buffer.c:415 end_encoder` does
  `mtl_barrier_after_stages(encoder, MTL_STAGE_ALL, MTL_STAGE_ALL)` under the driver's own
  `TODO_KOSMICKRISP This is probably overkill`; intra-pass, `kk_barrier_requires_encoder_split`
  (`:522`) splits the render pass when a write is later read as a texture, and `:583` says
  barriers are not yet lightened to the requested stages. Hollow Knight's frame: **24 render +
  5 compute encoders**, 24 vertex waits in 25 render encoders (96 %), no render splits, and
  20.8–25.0 ms p99 with the GPU busy 84–95 % of the frame.
- **DXMT:** `dxmt/dxmt_context.hpp` keeps a fence model per subresource and mip
  (`fenceTrackers[...]` at `:346,375,377,393,398`) with separate `fence_wait` and `fence_wait_vertex`
  sets (`:201`) merged across encoders (`dxmt_context.cpp:1372-1489`), and waits only on real
  dependencies, so a pass's vertex work overlaps the previous pass's fragment work.
- Cost: ~29 hard syncs a frame at native, which keep the tiler from overlapping passes.
  Bounded, not proven: `narrow_barriers` (0114) was rejected on vertex-dependency safety
  (96 % vertex waits) rather than measured cost, and it showed nothing.

### 5. Blending: lowered into the fragment shader vs Metal's fixed-function blend (inferred; unmeasured, per-pixel, and nobody has touched it)

- **KK:** `vulkan/kk_shader.c:532 kk_lower_fs_blend` → `nir_lower_blend` (`:589`), called from
  `kk_lower_fs` at `:656` for every non-GPL fragment shader when `blend_enable`. The King's Pass
  capture found **15 of 30 fragment shaders reading `[[color(0)]]`**. Metal's fixed-function blend
  exists only on the experimental GPL path — the mapping is already written at
  `bridge/mtl_compiler.h:81-88 mtl_render_pipeline_descriptor_set_color_attachment_blend` and
  `bridge/mtl_compiler.m:215-233 map_vk_blend_factor` — and GPL stays off by default
  ([0158](../decisions/0158-kk-gpl-stays-experimental.md)).
- **DXMT:** D3D11 blend state maps to Metal's blend factors and equations
  (`d3d11/d3d11_state_object.cpp:116-141 kBlendFactorMap` / `kBlendAlphaFactorMap`), so the blend
  is the ROP's.
- Cost: a per-pixel shader blend with a tile-memory attachment read in fp32, plus the shader-read
  requirement on the attachment. Hollow Knight at native is largely full-screen alpha-blended
  sprites. This is KosmicKrisp-wide (vkd3d pays it too), but no probe has measured it at all, and
  it is the largest untouched per-pixel delta against DXMT.

### 6. Shader content and precision: DXVK arrives precision-loaded; DXMT arrives LLVM-fast (measured at 6.4 %, so not the whole gap)

- **DXVK:** `subprojects/dxbc-spirv/dxbc/dxbc_converter.h:110 ir::OpFlags defaultFlags =
  ir::OpFlag::ePrecise`; with fxc's `refactoringAllowed` it only drops `ePrecise` and adds `eNoSz`
  (`dxbc_converter.cpp:701-702`), never `eNoNaN`/`eNoInf`. So every op reads as NaN/Inf-preserving,
  and the 2026-10-22 shader inspection confirmed every float op is `NoContraction` under float-controls-1.
- **KK** then emits: KK_WORKAROUND_14's multiply guard (`compiler/nir_to_msl.c:257 alu_needs_fmul_guard`,
  "Metal folds NaN * 0.0 to 0.0 under relaxed math", written as `!&buf0.contents[0] ? 1 : a * b`,
  which also stops FMA fusion), KK_WORKAROUND_17's `isnan()`/`!isnan()` around **every float
  comparison** (`:276`), a `#pragma METAL fp math_mode(...)` block per op (`:2125 alu_fp_math_mode_pragma`,
  `:2183-2206`), and `precise::` function prefixes (`:239 alu_funclike_precise`). The library compiles
  at `MTL_MATH_MODE_FAST` unless `MESA_KK_SAFE_MATH` (`vulkan/kk_shader.c:2364`).
  KK_WORKAROUND_6 additionally makes **every global access** `coherent device`
  (`compiler/nir_to_msl.c:1147-1156 global_access_qualifier`); `patches/mesa` 0030 keeps it on for
  every stage but fragment on iOS 27, and turning it on for fragment **halved the frame rate**
  ([kk-ios27-workarounds](../evidence/2026-10-11-kk-ios27-workarounds.md)) — which bounds how expensive
  it is. Hollow Knight has ~14,000 vertices/frame reading a root table through 64-bit address arithmetic.
- **DXMT** never sees this: `airconv/dxbc_instructions.cpp:564 .precise_mask =
  refactoringAllowed ? m_PreciseMask : 0b1111` honours DXBC's own precise mask, and DXMT writes
  its LLVM module straight into a metallib (`airconv/metallib_writer.cpp:20 MetallibWriter::Write(const
  llvm::Module &)`), no MSL text, with fast-math IR and `MTLMathModeFast`/`MTLMathFloatingPointFunctionsFast`
  for its own libraries (`winemetal/unix/winemetal_unix.c:5429-5432`).
- Measured: `no_fp_preserve` (0109) bought +6.4 % GPU time in a matched stationary ABBA;
  `ubo_unbounded`/`ubo_vec4_bounds` shrank host AIR without the predicted tiler drop;
  `root_table_loads` did nothing. So this class is real but is not most of the gap.

### 7. Present path: two full-res passes vs one (measured, bounded)

- **KK/DXVK:** DXVK draws into its own swap-chain image and the Metal WSI blits that into the
  drawable (`vk_meta_blit_image2`, `kk_wsi.c` + `wsi_common_metal.c`; kept work is `patches/mesa`
  0035 and 0083) — 2 blits, ~27.6 MB a frame at native. **DXMT:** one quad into the drawable
  (`dxmt/dxmt_presenter.cpp:183 setRenderPipelineState(present_blit_)`). Item 4 of PLA-72 concluded
  the extra pass is not removable safely, because an image view's Metal texture is fixed at view
  creation while a drawable changes every acquire and the drawable is `framebufferOnly`.

### 8. Per-pass Metal state the game never asked for (inferred; CPU-side mostly)

- **KK** sets the render pass **visibility buffer** for every pass
  (`vulkan/kk_cmd_draw.c:450 mtl_render_pass_descriptor_set_visibility_buffer(dev->occlusion_queries.bo->map)`)
  and `mtl_render_pass_descriptor_set_visibility_accumulate(pass_descriptor, true)` (`:468`), and
  flushes a pass's deferred query/marker writes as one `libkk_write_u32` compute dispatch each
  (`flush_post_render_writes`; `patches/mesa` 0095's message names the cost: "a pool upload, two
  barriers, the pipeline and the root bound again" per write). **DXMT** sets a visibility buffer
  where needed and chains whole command lists per encoder call
  (`dxmt/dxmt_resource_initializer.cpp:733-735 b.encodeCommands(&blit_cmd_head)`).
- The same class of per-frame CPU cost is already named by the un-defaulted `MESA_KK_BATCH2`
  items (`patches/mesa` 0091–0095, measured for RDR2 in [batch2](../evidence/2026-10-21-batch2.md)):
  the default re-uploads the **whole 2.2 KiB root table per draw** (~96 draws a frame), one Metal
  command allocator per command buffer never gets reset (950 allocators, 1.2 GB on RDR2),
  vertex-amplification is set per render encoder without multiview, and the residency set is
  committed at every submit. For Hollow Knight's D3D11 route these are the **smallest GPU-side**
  candidates — the profiles put `dxvk-cs` at 4.53 Mi/f against `dxmt-encode-thr` 4.23 Mi/f — but
  they are the CPU half of the energy budget on a phone whose P cores are parked.

### 9. Robustness shapes only Vulkan pays (latent, not current cost)

- `vulkan/kk_cmd_draw.c:1866` KK_WORKAROUND_12/13 and `requires_unroll_robustness`: with
  `pipelineRobustness`/`robustBufferAccess2` (DXVK enables them), an indexed draw whose index buffer
  is unaligned or over-reads is **unrolled in a compute pass**; DXMT's D3D11 frontend has no such
  concept. Hollow Knight's counters showed **no unrolling**, so this is a risk to keep off the hot
  path, not the current cost. Same class: workaround 16's level query, which the PLA-72 review called small.

## What PLA-72 already ruled out

Pass structure and forced loads (the King's Pass captures match pass by pass; Vulkan moves
**fewer** nominal attachment bytes, 449 MB against 625 MB), MSAA and render size, tiler mode
(decision 0066, kept off, Mi/f −5 %), KosmicKrisp's own CPU time (0.6–1.0 % of samples),
`dxvk-submit` trims (0.4 %), private storage **without** 0019, sample-mask lowering as a probe
(though the real fix, `patches/mesa` 0103, is kept and did not close the gap), `one_time_submit`,
`fp_precise_only`, `root_table_loads`, `ubo_vec4_bounds`, border colours and fans (Zink only).

## Queue, cheapest decisive step first

Each step is one change, kept or reverted, with the protocol below. Sizes: S = small, M = medium.

1. **S — settle the memory lead without a phone run.** Capture a Hollow Knight frame on the current
   IPA on both backends (`pp gpu capture --frame N`, `pp gpu read --json`, the descriptor reader in
   `tools/gputrace.py`) and read each full-res target's **storage mode, `allowGPUOptimizedContents`,
   sparse/heap backing and the compression type Metal recorded**, against DXMT's `0x5`/private/standalone
   targets. Check Apple's own conditions for optimised layouts (heaps, buffer aliasing, sparse pages).
   This is the same mechanism 0019 already bought 21–33 % energy on, and the only place the Mi/f and
   the 1.08 GB driver-memory deltas can live. No build.
2. **M — give an image whose memory is never host-shared or exported a private, standalone,
   non-aliased, non-sparse allocation** (chunk 8's `private_memory` redone as a new `patches/mesa`
   number, on top of 0019's usage rule; the whole-heap alias in `kk_bo.c` stays for memory that
   Vulkan imports/exports or maps). Land it behind `MESA_KK_EXPERIMENTAL=private_storage`, off by
   default, until a Metal-side citation for the alias/sparse restriction and a correctness check exist.
   Then one warm native/free DXVK pair (control, change) read as GPU ms, Mi/f and sys mJ/f, plus the
   end screenshot; and one vkd3d pair, since the change is driver-wide.
3. **M — put Vulkan copies on a real copy path** instead of compute-encoded blit commands, and stop
   chaining texture→buffer→texture with a BLIT-stage barrier when `can_do_image_to_image_copy`
   already matched. One warm native/free DXVK pair, watch Mi/f; a screenshot for the game's grab passes.
4. **M/L — carry the Vulkan blend state in Metal's fixed-function blend on the normal path**, reusing
   the GPL mapping at `bridge/mtl_compiler.m:215-233`, so blended draws stop reading `[[color(0)]]`.
   Correctness risk to carry, not to assume away: write masks, a repeat blend after a depth test,
   sRGB/blend-in-linear semantics, D3D11's blend-with-coverage. Needs the host MSL mock
   (`build/mesa-host-test/run.sh`) before the phone, then a DXVK pair and a screenshot.
5. **S/M — narrow the encoder-end barrier only where the vertex stage of a later pass cannot read
   what the earlier pass wrote**, extending what `narrow_barriers` (0114) had to refuse; count encoders
   and vertex waits with `MESA_KK_DEBUG=passes`/`vertex_stats` first, and skip the ABBA at the helper's
   stopping rule.
6. **S — the two known per-pass Metal costs:** set a visibility buffer only when a pass uses
   occlusion queries, and batch a pass's deferred query writes as one dispatch on the normal path
   (0095's `oq` behaviour, no longer behind `MESA_KK_BATCH2`). One 720/60 CPU-side pair plus one native/free
   GPU pair.
7. **Leave for PLA-72:** the D3D12 CPU side (UnityGfxDeviceWorker, +9 Mi/f, FEX/ARM64EC transitions),
   and the cooled exit runs plus the gate.

## Protocol (inherited from PLA-72's owner directions, 2026-10-07/08)

- **One run per change.** Build, `pp test`, install, the gate (Hollow Knight and Portal 2 to
  `first-frame+10` in one locked session), then **one** route run, compared with that route's control.
  A rendering change also gets one look at the end screenshot.
- **Mode follows the target.** A GPU or throughput change gets a native/free run
  (`{"screen":"native","frameLimit":0}`) read as FPS, GPU ms and energy a frame (sys and CPU mJ/f);
  a CPU or power change gets a 720/60 run (`{"screen":"720","frameLimit":60}`) read as CPU mW, phone mW and Mi/f.
- **Warm paired runs:** control and change back to back in one `pp phone lock` session, no `--cool`;
  record `thermal_start`, `first_pressure_s`, `max_pressure` and flag a pair whose pressure differs.
  A cooled run is never compared with a warm one; exit runs stay cooled.
- **Power counts as much as FPS.** Raw mW is not comparable across different FPS; read mJ/f there.
- **Keep** what helps (commit with its run in an evidence record); **revert** what does not, and say
  why in the record. Do not run an unchanged thing again to "confirm"; look at the code or the profile
  and change something.
- A Graphics-option lever is a `patches/mesa` switch read through the game's Graphics options
  (decision 0137), never a raw environment push, and hazardous probes stay explicitly named
  (`patches/mesa` 0118's rule).

## Exit criteria for this plan

Not its own exit: this plan's exit is the evidence that each of queue items 1–6 either moved
GPU ms/energy at native or is ruled out, so that PLA-72's remaining gap is attributable.
Concretely: after the last kept change, one cooled native/free DXVK run reaches GPU ms ≤ DXMT + 5 %
and sys mJ/f ≤ DXMT + 5 %, or the record names the measured residual and where it sits. The
gate (Hollow Knight and Portal 2 to `first-frame+10`) passes after every kept change, and every
run ends in play.

## Limits and unrun gates as written

No build, no phone run, and no capture was taken while writing this plan. Nothing here is a
measured speedup: items 1–6 are inferences from the two code bases and our patch series. The
per-frame GPU counter we do not have: `pp gpu read` reports what Metal was **asked** for
(the [profile](../evidence/2026-10-08-vulkan-perf-profile.md) record says Metal reports only
the compression type it was asked for), and per-pass limiters need a Mac, which
[0031](../decisions/0031-a-mac-for-analysis-only.md) proposes and has not accepted. Portal 2
is not installed on the phone as of the 2026-10-23 sessions, so Portal 2 gates are unrun until
it is reinstalled. Unsafe/hazardous probes stay opt-in and explicitly named
(`patches/mesa` 0118, decision on unsafe UBO consent).

## Findings to carry into Linear and evidence

Every kept or reverted change gets an evidence record under `docs/evidence/` with the IPA sha256
and the run directories; Hollow Knight's latest result goes to its compatibility issue
[PLA-42](https://linear.app/playportdev/issue/PLA-42) with the IPA and run directory, as each
played run already does. This plan does not change any default until a record says to.

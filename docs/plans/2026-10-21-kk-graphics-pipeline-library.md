# Plan: VK_EXT_graphics_pipeline_library in KosmicKrisp

**Linear:** [PLA-424](https://linear.app/playportdev/issue/PLA-424).
**Date:** 2026-10-21. **Kind:** plan, in progress. **Branch:** `dev/kk-gpl`, built in the side copy
`.work/worktrees/kkgpl` ([0117](../decisions/0117-side-copies-that-build.md)); its phone gates run
from the main checkout after the branch moves there. **Pins read:** `mesa` b39d173 + `patches/mesa`
(95), `dxvk` d942d78 + `patches/dxvk`.

**Owner's decision (2026-10-21):** implement full GPL, staged behind
`MESA_KK_EXPERIMENTAL=gpl`, off by default, until the phone shows it works.

## Runner state

- **Branch:** `dev/kk-gpl` in the side copy `.work/worktrees/kkgpl`, not merged, not pushed.
  Workstation only (owner, 2026-10-21): no phone gate until the branch moves to the main checkout.
- **Done:**
  - G0's host harness and G1 in `ea258b0` (`patches/mesa` 0096; host test `check_gpl`).
  - G2 in `8c31a22` (`patches/mesa` 0097; dev IPA `5a25af6e`, side copy, not installed). The vertex library is built at library creation; a
    fast link compiles only the fragment side at its first draw.
  - G3 in the commit "MESA_KK_EXPERIMENTAL=gpl compiles a library's fragment shader on its own
    (mesa 0098, G3)" (`patches/mesa` 0098; dev IPA `417caed8`, side copy, not installed). Both
    libraries are built at library creation; a fast link only builds the Metal pipeline.
  - Evidence: [2026-10-21-kk-gpl-host](../evidence/2026-10-21-kk-gpl-host.md).
  - G0's phone baseline is not run.
- **Running:** none.
- **Queue:** G4 next (cache and accounting, workstation); then G0's phone baseline and G5 from
  the main checkout; G6.
- **Phone:** not used by this plan yet.
- **Notes:** reports in the side copy's `.work/agent-notes/kk-gpl/reports/` (G2: `g2.md`, G3:
  `g3.md`).

## Why

KosmicKrisp (KK) exposes neither `VK_EXT_graphics_pipeline_library` (GPL) nor
`VK_EXT_shader_object`. `kk_physical_device.c` fills in GPL's properties, but the extension and
the `graphicsPipelineLibrary` feature are off. DXVK uses GPL only when
`DxvkDevice::canUseGraphicsPipelineLibrary()` is true, which needs that feature and
`graphicsPipelineLibraryIndependentInterpolationDecoration`.

Without GPL, DXVK builds each graphics pipeline monolithically on its CS thread when a draw
first needs it. In KK that build is NIR lowering, then NIR→MSL, two Metal libraries
(MSL→AIR) and a Metal render pipeline, all inside `vkCreateGraphicsPipelines`. The game stalls
until it finishes. On Proton, GPL removes that stall: DXVK compiles each shader into a library
on a worker thread when the game creates it, and at draw time only *fast-links* the libraries.
It then builds the optimized (link-time-optimized) pipeline in the background and swaps it in.
Since [0153](../decisions/0153-rdr2s-settings-are-every-games-defaults.md), Vulkan is every
game's default backend, so every DXVK title has these hitches.

**Who benefits.** GPL is an API the caller has to use; the driver cannot apply it on its own.

- **DXVK (D3D9/10/11): fully.** D3D11 has no pipeline objects, so DXVK finds out which shader
  goes with which state only at a draw. GPL is how it moves that compile off the draw.
- **vkd3d-proton (D3D12): partly.** D3D12 games create whole pipelines up front
  (`CreateGraphicsPipelineState`), on their own threads, and vkd3d-proton compiles them in full
  there; GPL changes nothing for those. At our pin it uses GPL only when a pipeline's state is
  unknown at creation (`d3d12_pipeline_state_init_static_pipeline` in `libs/vkd3d/state.c`):
  - an unknown depth/stencil format with a depth test;
  - topology type `UNDEFINED`;
  - tessellation with an unknown patch count.

  In those cases it builds a partial library and links at the draw instead of compiling the
  whole pipeline there. Like DXVK, it turns GPL off without
  `graphicsPipelineLibraryIndependentInterpolationDecoration`.
- **Native Vulkan games (RDR2): not at all.** The game creates its own pipelines with
  `vkCreateGraphicsPipelines`, on threads it picks itself. As far as we know RDR2 never uses
  GPL (inferred). Its compile stalls are
  [PLA-425](https://linear.app/playportdev/issue/PLA-425): a persistent Metal cache or
  binary archive, or cheaper MSL.

**Where KK's compile time goes.** On the phone, `MESA_KK_DEBUG=compile` logged 942 render
builds over 20 ms, all of them RDR2's (`.work/ui-runs/*rdr2*/pull/s1-host.log`). They are used
here only for the split between the libraries and the pipeline; this plan does not help RDR2
(above):

| step | total |
| --- | --- |
| vertex library | 260 s |
| fragment library | 1,080 s |
| Metal pipeline | 206 s |

Building the libraries (MSL→AIR) is about 87 % of the time and the pipeline about 13 %. So a
fast link that only builds the Metal pipeline from libraries made earlier would take most of
the stall off the draw thread. No such split exists yet for small DXVK shaders (Hollow Knight,
Portal 2), because their builds stay under the 20 ms logging threshold. G0 measures it.

## What stands in the way

The Mesa runtime (`src/vulkan/runtime/vk_pipeline.c`) already implements GPL for `vk_shader`
drivers (NVK, HK and panvk expose it this way):

- each library partition (pre-rasterization stages; fragment) is compiled through
  `vk_device_shader_ops::compile` with only that library's state;
- a fast link reuses the library `vk_shader`s, binds them with `cmd_bind_shaders` and sets every
  other piece of state as dynamic state;
- a `LINK_TIME_OPTIMIZATION` link recompiles from the retained precompiled NIR as one
  partition. That is KK's existing monolithic path.

KK's compile assumes it sees the whole pipeline:

1. **Vertex shader ← vertex input state.** `kk_lower_vs_vbo` pulls vertices with the formats,
   bindings and divisors baked into the MSL. DXVK keeps vertex input in its own library.
2. **Fragment shader ← fragment output state.** `kk_lower_fs_blend` always blends in the shader
   (`nir_lower_blend`, which reads the framebuffer). The colour formats also set output
   signedness and component counts, and the swizzle of non-native formats. From the multisample
   state come alpha to coverage/one, the static sample mask (`msl_lower_static_sample_mask`) and
   workaround 7. The depth/stencil formats decide whether depth writes are stripped.
3. **One Metal pipeline needs both functions.** `kk_compile_graphics_pipeline` builds the vertex
   and fragment libraries and the `MTLRenderPipelineState` on the vertex `kk_shader`, and
   `kk_flush_pipeline` binds it from there. A fast link pairs shaders that were compiled
   apart, so the pairing must happen somewhere else.
4. **Partial state.** `kk_hash_graphics_state`, `kk_lower_nir`, `gather_shader_info` and
   `kk_compile_shaders` dereference `state->ia`, `state->vi`, `state->rp`, `state->cb` and
   `state->ms` without checks. A library partition has some of these as NULL.
5. **Cross-stage links.** The two compiles share information:
   - `nir_opt_varyings_bulk` compacts varyings across stages;
   - a fragment shader behind a geometry shader reads `gl_PrimitiveID` as a varying;
   - the fragment stage's clip/cull lowering takes `num_cull_distances` from the previous stage.

## Design

Two compile modes, picked per partition in `kk_compile_shaders`:

- **Monolithic** (today's path, unchanged): non-GPL pipelines and LTO links. DXVK's optimized
  background pipelines therefore stay exactly what they are now.
- **Separate**, when the runtime compiles a vertex-only or fragment-only library partition
  (`VK_SHADER_CREATE_LINK_STAGE_BIT_EXT` clear and a library's partial state). The shader's MSL
  must depend on nothing outside its own library. The Metal library (MSL→AIR, the expensive
  step) is built at that point, on the application's thread, which for DXVK is a worker thread.
  The `kk_shader` keeps the `mtl_library` and a serialized copy of its input NIR, so that a
  fallback can do a monolithic compile.

**Separate vertex shader.**
- **Vertex fetch from a runtime layout.** Each attribute load reads its binding, offset,
  format class and divisor from the root draw data, which `kk_flush_dynamic_state` fills from
  `dyn->vi`, through one uniform switch over the formats KK advertises for vertex buffers. The
  same lowering would give `VK_EXT_vertex_input_dynamic_state` later. Fast-linked pipelines pay
  a few ALU ops per attribute until DXVK swaps in the optimized pipeline.
- **No dependence on topology.** The shader always writes a point size; the topology class
  goes on the Metal pipeline at link time.

**Separate fragment shader.**
- **Blend in Metal, not the shader.** Blending, the write mask and alpha to coverage/one move
  to the Metal pipeline's fixed-function state (`MTL4RenderPipelineColorAttachmentDescriptor`).
  Outputs keep their SPIR-V types, and dual-source outputs are `index(1)`.
- **Clamp and sample mask from the root.** Depth clamp emulation is already driven by root
  flags. The sample mask comes from the root when it is not all ones.

**Fast link, at draw time.** A device-wide cache maps (vertex shader, fragment shader, link key)
to an `MTLRenderPipelineState` and its depth/stencil state. The link key holds the colour,
depth and stencil formats, the blend state, the multisample state, the topology class and the
view count. `kk_flush_pipeline` looks the entry up when the bound shaders are separate, using
`dyn` and the rendering state. A miss builds only the Metal pipeline, from the two `mtl_library`
objects. Entries go away with either shader. Keying on bound shaders rather than on pipelines
also serves a later `VK_EXT_shader_object`.

**Fallback at link time.** The link does a monolithic compile from the kept NIR, which is
today's cost, and caches it in the same table, whenever separate mode cannot express the
pipeline:

- a logic op or advanced blend, or a non-native colour format that needs a swizzle;
- a fragment depth write with no depth attachment;
- input attachments;
- tessellation or geometry stages; the first cut keeps these monolithic;
- a fragment shader that reads `gl_PrimitiveID` or clip/cull distances;
- an attribute format outside the fetch switch.

`[kk-compile] link` lines count fallbacks by reason.

**Not chosen:**
- **Driver-side async with skipped draws.** This is the old dxvk-async: not conformant, and it
  leaves visible gaps. The owner chose GPL.
- **A vertex-fetch prolog and blend epilog joined with Metal 4
  `MTL4StaticLinkingDescriptor.privateFunctionDescriptors`.** It would keep today's MSL for the
  fast link, but `nir_to_msl` emits only an entry point, and every link would pay an IR link.
  Revisit it if the runtime fetch costs too much GPU time.

## Chunks

Each chunk is a `patches/mesa` patch (or patches) with the trailers, a host test and a commit.
Nothing changes with the flag off. Phone gates run only from the main checkout.

- **G0: harness and baseline.**
  - Host: GPL cases in `build/mesa-host-test/kk-host-test.c`, mirroring DXVK's four libraries:
    - vertex input interface;
    - pre-rasterization (vertex shader);
    - fragment shader;
    - fragment output interface.

    Each case fast-links, LTO-links and records draws on the mock. The cases are expected to
    fail or be skipped until G1.
  - Phone (main checkout, later): a dev run of Hollow Knight and Portal 2 with
    `MESA_KK_DEBUG=compile` and the logging threshold lowered, for the
    library-against-pipeline split of small DXVK shaders.
- **G1: GPL exposed under the flag, correct but not yet faster.**
  - `EXT_graphics_pipeline_library` and `graphicsPipelineLibrary` when `MESA_KK_EXPERIMENTAL=gpl`.
  - NULL-safe hashing and lowering.
  - Separate mode keeps only the NIR.
  - The draw-time link cache does the fallback (monolithic) compile for every pair.
  - Host: G0's cases pass.
- **G2: separate vertex shader.** The runtime-layout vertex fetch, point size and topology at
  link time. The vertex Metal library is built at library time.
- **G3: separate fragment shader.** Fixed-function blend, write mask and alpha to coverage/one;
  outputs independent of formats; the sample mask from the root; the fallback list above. The
  fragment Metal library is built at library time, so a link builds the pipeline only.
  Done (`patches/mesa` 0098). A sample mask other than all ones falls back instead of coming
  from the root (evidence, G3).
- **G4: cache and accounting.**
  - Serialize and deserialize separate shaders (MSL, the NIR blob, the flag); deserializing
    rebuilds the library.
  - `[kk-compile] link` logging and `MESA_KK_DEBUG=memory` counts for libraries and links.
- **G5: phone (main checkout).**
  - Hollow Knight first frame+10 with the flag on (dev Graphics options,
    [0137](../decisions/0137-graphics-options-set-any-variable.md)).
  - DXVK's log shows GPL in use. A D3D12 title shows vkd3d-proton accepts GPL (it needs
    independent interpolation).
  - RDR2 is not a G5 title: it does not use GPL (PLA-425).
  - Portal 2 chapter-load hitches with the flag off against on, the method of
    [2026-10-05](../evidence/2026-10-05-portal2-hitches-requests.md).
  - GPU time with the flag on against off: the runtime fetch, the fixed-function blend.
- **G6: default.** A decision record either turns the flag on by default or keeps it off, from
  G5's evidence.

## Risks and open questions

- **Metal varyings across separate compiles.** Separately compiled stages match by
  `[[user(vary_N)]]` name. Metal fails a pipeline whose fragment input no vertex output writes;
  DXVK's `canCreatePipelineLibrary` checks for that and patches its shaders otherwise. Whether
  type differences fail too is still to check on Metal, through G0's host case and
  `msl-compile.sh`.
- **More compiling in total.** DXVK still builds every optimized pipeline in the background, so
  each shader is compiled more than once. That adds pressure on `MTLCompilerService` against its
  150 MB limit (PLA-364, decision 0139) and on memory. G5 watches for interrupted builds.
- **Not conformance-tested.** No Vulkan CTS runs here. The host mock checks recording and MSL,
  and the phone checks the rendering.

# What RDR2's Vulkan renderer asks of the driver, against KosmicKrisp

**Date:** 2026-10-17. **Linear:** [PLA-386](https://linear.app/playportdev/issue/PLA-386)
(under PLA-254). **Kind:** workstation measurement, no phone, no IPA.
Answers the open question in the [RDR2 plan](../plans/2026-10-12-rdr2.md): which Vulkan
features and extensions RDR2's renderer requires, against KosmicKrisp's.

## Setup

- Red Dead Redemption 2 (Steam 1174180), game build 1.0.1491.50, the owner's desktop copy,
  Story mode not entered. Started as Steam starts it (`PlayRDR2.exe` → Rockstar Games
  Launcher → `RDR2.exe`), under Proton Experimental (`experimental-11.0-20261014`), in a
  reflinked copy of the owner's prefix under `$PLAYPORT_BUILD/agent-notes/rdr2-vk/`, on the
  agent's sway display. The launcher signed in from the copy's saved session; the game's
  `system.xml` already selects `kSettingAPI_Vulkan`. No input was sent.
- Driver: RADV on an RX 9070 (Mesa 26.2.4), Vulkan 1.4.
- **A capture layer** (a Linux implicit layer under winevulkan) logged every
  `vkCreateInstance`/`vkCreateDevice` (extensions, 1.0 features, feature chain), every
  image, view, sampler, descriptor set layout, pipeline layout, query pool, render pass,
  graphics and compute pipeline, memory allocation and some command counts, and saved each
  shader module's SPIR-V. Steam's Fossilize layer recorded the pipelines in a second run.
- **The KosmicKrisp profile.** The same layer, given the KosmicKrisp device report from the
  host mock (`build/mesa-host-test`, mock Apple10 bridge, `mesa` b39d173 + `patches/mesa`
  0001–0036), made RADV look like KosmicKrisp to the game: only extensions both drivers have,
  1.0 features ANDed, format features ANDed, at most 4 samples (storage images 1), line width
  1, one queue family with one queue (graphics, compute, transfer), one memory type
  (`DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT | HOST_CACHED`) on one 5 GiB heap, and
  KosmicKrisp's vendor, name and integrated device type.
- Runs: `play1` (RADV as it is, 300 s), `prof2` (KosmicKrisp profile, Fossilize on, 480 s).
  The logs, SPIR-V, the Fossilize database and the screenshots stay in the build area
  (`agent-notes/rdr2-vk/runs/`); the game's shaders and artwork are not ours to publish.

## What the renderer creates

RDR2's own renderer is a separate Vulkan instance: application "Red Dead Redemption 2",
engine "SGA", **API 1.1**. The same process also makes a vkd3d-proton device and DXVK
devices (the game's D3D12 probe and Social Club's overlay); those are not counted here.

**Device extensions** it enabled on RADV: `VK_AMD_memory_overallocation_behavior`,
`VK_EXT_buffer_device_address`, `VK_EXT_hdr_metadata`, `VK_EXT_inline_uniform_block`,
`VK_EXT_scalar_block_layout`, `VK_KHR_bind_memory2`, `VK_KHR_get_memory_requirements2`,
`VK_KHR_maintenance2`, `VK_KHR_push_descriptor`, `VK_KHR_swapchain`,
`VK_KHR_timeline_semaphore`, `VK_KHR_uniform_buffer_standard_layout`. The executable also
names `VK_EXT_full_screen_exclusive`, `VK_NVX_binary_import`, `VK_NVX_image_view_handle`,
`VK_AMD_display_native_hdr` and `VK_EXT_validation_cache`, which RADV does not offer.
KosmicKrisp has every enabled one except the AMD one, which the game then left out.

**Features:** it enables every 1.0 feature the device reports (on RADV all but ETC2, ASTC
and the multisample sparse bits), plus `uniformBufferStandardLayout` and
`scalarBlockLayout`. So the enabled set says nothing about use. Under the KosmicKrisp profile
it enabled the intersection and went on.

**What it uses** (`play1`, landing page reached):

| | |
|---|---|
| Queues | family 0 ×1 and RADV's compute family ×4; with one family and one queue it uses that |
| Shader modules | 13,233 distinct: 9,306 fragment, 3,075 vertex, 783 compute, 43 tessellation evaluation, 25 tessellation control, 1 geometry |
| SPIR-V capabilities | Shader 13,164, SampledBuffer 12,588, ClipDistance 5,012, ImageQuery 1,520, ImageGatherExtended 1,323, ImageBuffer 695, StorageImageExtendedFormats 626, SampleRateShading 581, ImageMSArray 451, Sampled1D 208, Tessellation 68, DerivativeControl 25, Geometry 3, CullDistance 2. **No** Int64, Float64, Int16, Float16, subgroup, sparse, StorageImageMultisample, ReadWithoutFormat or any SPIR-V extension; only `GLSL.std.450` |
| Graphics pipelines | 2,149: topology triangle list 1,796, strip 297, patch list 46 (3 or 4 control points), fan 2; depth clamp 580; depth bias 606; **depth bounds test 131**; cull none/front/back; `rasterizationSamples` 8 on 96; alpha to coverage 15; **dual-source blending** (SRC1 colour/alpha factors); dynamic viewport, scissor, depth bias, blend constants, stencil reference; no logic op, no wide lines, no sample shading flag, no polygon modes |
| Compute pipelines | 919 |
| Descriptors | sets of samplers (separate), sampled images, storage images, uniform/storage texel buffers, uniform and storage buffers, one input attachment; no inline uniform blocks, no push descriptors, no update-after-bind; 2 sets per layout; pools of 4,096 sets |
| Images | 2D 19,464, 3D 1,488 (all `2D_ARRAY_COMPATIBLE`), 1D 26; `MUTABLE_FORMAT` 375; 8 samples on 51; BC1–BC7 and BC6H sampled; storage on B10G11R11, RGBA16F, RGBA32F, R8, RG8, RGBA8, RG16F, R16F, RG32UI, RG32F, R32F/UI, RGBA32UI, R8UI, R16UI, RG16UI; depth D32S8, D32, D16 |
| Queries | occlusion (6 pools), timestamps (5 pools of 8,192), **one pipeline-statistics pool with all 11 counters** |
| Commands (first 20,000 render passes) | `vkCmdSetDepthBounds` 7,425, `vkCmdCopyQueryPoolResults` 7,444, `vkCmdClearAttachments` 80,444; no indirect draws, no push descriptors, no resolves or blits |
| Memory | 75 allocations, 2,224 MiB by the landing page |

## Against KosmicKrisp

Every format/usage pair the game creates has the matching optimal-tiling features in the
KosmicKrisp report. Every SPIR-V capability it uses is one KosmicKrisp reports. Dual-source
blending, depth bounds (Apple10), depth clamp, clip and cull distances, image cube arrays,
geometry and tessellation (through `poly`) are all reported.

**Under the KosmicKrisp profile the game reached its landing page** ("Story mode", "Online",
settings), rendered at 1280×720 after a 1920×1080 swapchain, with 2,150 graphics and 919
compute pipelines and 1,038 MiB allocated by then. Two things differed from plain RADV:

1. **A message box before the first frame:** "Your computer does not meet the minimum
   requirements for video memory; if you run the game anyway it may not run optimally"
   (shown in Polish), OK/Cancel. A helper pressed OK and the game continued. The device
   was a 5 GiB unified-memory integrated GPU; a discrete one with 16 GiB showed none.
   (inference: the game reads dedicated video memory, which a unified-memory adapter
   reports small.) On the phone this box would come too; PLA-269 (per-title reported
   VRAM) is where the answer belongs.
2. MSAA images were created with 4 samples instead of 8, but **96 pipelines still asked for
   8 samples**, which KosmicKrisp does not report.

It also **still created the pipeline-statistics query pool** with `pipelineStatisticsQuery`
not enabled.

## The pipelines through KosmicKrisp on the host

Steam's `fossilize_replay` replayed the KosmicKrisp-profile run's database (the SGA device)
on the host mock of KosmicKrisp (debug build; NIR to MSL; the mock cannot compile MSL):

- graphics 1,452 compiled, 335 skipped; compute 731 compiled, 57 skipped (Fossilize skips
  pipelines that use a module it marked faulty after a crash);
- **153 graphics pipelines aborted, all at one assertion**:
  `kk_nir_lower_descriptors.c:534: lower_tex: Assertion '!sampler' failed`.
  In the one examined (fragment shader of pipeline 87), a `txb` and its `lod_bias` query sit
  in a block under `if false`; the texture is `texture_heap_offset 0x0` and the sampler a
  `deref_var`. The runtime's `vk_nir_lower_descriptor_heaps` builds a heap offset for a
  texture deref that is not a set/binding variable even when the pipeline has no heap
  mapping (`build_deref_heap_offset`'s cast path never checks `ctx->info`), and
  KosmicKrisp's `lower_tex` expects a texture deref whenever there is a sampler deref. In a
  release build the assertion is gone and the instruction reaches MSL unlowered
  (inference: a failed or crashing pipeline build on the phone).
- Fossilize parsed 14,380 graphics pipeline entries against the 2,150 the capture layer
  counted; the replay compiled 1,452. Not explained here.

`kk_query_pool.c`'s `kk_reports_per_query` handles occlusion, timestamp and
transform-feedback pools only; a pipeline-statistics pool reaches `UNREACHABLE`
(read from the source; not run).

## What this means

- RDR2 on Vulkan needs **none** of the FL12_2 plan's features. Its gaps on KosmicKrisp are
  three defects (the texture lowering, statistics query pools, 8-sample pipelines) and the
  VRAM message box. The [FL12_2 plan](../plans/2026-10-05-kosmickrisp-fl12_2.md) now carries
  them as chunks V0–V4 ahead of its own.
- What the host cannot show: MSL compilation by Apple's compiler, `poly`'s tessellation and
  geometry at run time, depth bounds on the A19, performance, memory. The phone is the
  judge once the launcher (PLA-295) and a native Vulkan title (PLA-300) work.
- Desktop limits: RADV underneath, winevulkan's own extension filtering, no gameplay
  (no input on the headless seat, and the landing page offers Online, which is out of scope),
  and the capture covers only what the landing page builds.

## Host fixes (2026-10-17, chunks V0–V4)

Same database, host mock (debug build, `mesa` b39d173 + `patches/mesa`), replayed by
`build/mesa-host-test/run-replay.sh` (V0, commit `1fc4605`), which replays each crashed
pipeline alone for its message. No game was run; not checked on the phone.

| | before (0001–0036) | after (0001–0037) |
|---|---|---|
| graphics built / skipped / of | 1,452 / 337 / 1,940 | 1,923 / 17 / 1,940 |
| compute built / skipped / of | 731 / 57 / 788 | 731 / 57 / 788 |
| crashed pipelines | 151, one group: `kk_nir_lower_descriptors.c:534: lower_tex: Assertion '!sampler' failed` | 0 |

- **The cause:** the shaders sample an `OpUndef` image with a defined sampler. Mesa 0037 gives
  such an instruction an undefined result before descriptor lowering (V1 in the plan); a
  hand-written SPIR-V shader in `kk-host-test` reproduces it. Mesa `main` (335d5698) has no fix.
- **The crash count moves** between replays (151 here, 153 in the first, 133 with one
  thread): Fossilize skips the pipelines that share a module with one that crashed. The
  14,380 graphics entries above were that parse counter summed over restarted replayers;
  without crashes it parses 1,940.
- **What is left:** Fossilize refuses 73 modules for `ImageMSArray`, which Vulkan gates on
  `shaderStorageImageMultisample`, which KosmicKrisp does not report (the capability table
  above counted it as reported), and calls the create infos of the 17 graphics and 57
  compute pipelines it skips invalid (inference: those that use the refused modules).
- **Pipeline-statistics pools (V2, mesa 0038):** creating the game's pool (8 queries, all 11
  counters, `pipelineStatisticsQuery` not enabled) aborted at `kk_reports_per_query`
  (`Unsupported query type`) in a `kk-host-test` case made from the capture; with 0038 the
  pool works with every counter 0 and the feature stays unreported. The replay builds no
  query pool, so its numbers do not move (graphics 1,923 / 17, compute 731 / 57, 0 crashes).
- **8-sample pipelines (V3, mesa 0039):** KosmicKrisp passed the game's
  `rasterizationSamples = 8` to Metal unchanged. With the mock made to abort on a raster
  sample count the device does not support, the replay crashed on 51 graphics pipelines
  (one group, `render pipeline raster sample count 8`; graphics 1,795 built of 5,420 parsed
  across restarted replayers). 0039 clamps the count to 4 (the highest supported): 0
  crashes, graphics 1,923 / 17, compute 731 / 57.
- **`ImageMSArray` (V4, no patch):** of the 73 modules Fossilize refuses, 11 have a
  multisample array image, and every multisample image in them is sampled (fetches with a
  sample index, size queries), never storage; spirv_to_nir implements the capability and
  only warns. With a scratch layer that reported `shaderStorageImageMultisample` to
  Fossilize and stripped it at device creation, the replay built every pipeline (graphics
  1,940 / 1,940, compute 788 / 788, modules failing validation 87 → 0), 0 crashes, no
  untranslated MSL; 14 MSL libraries read a `texture2d_ms_array`. A hand-written module in
  `kk-host-test` covers it. Not checked on the phone (Apple's compiler, the A19's
  multisample array textures).

## In Story mode (2026-10-17, H1)

Two more runs of the same setup with the KosmicKrisp profile and Steam's Fossilize layer, this
time into Story mode with the owner's save (owner-approved). Steam was started on the agent's
sway display (`steam -silent`), because the launcher stops at "Steam failed to initialize"
without it, and shut down after each run. Input came from a Win32 program run in the same
prefix that sends `SendInput` keyboard and relative mouse input to the game's window; the
game took both. The program, the run script and the screenshots stay in the build area
(`agent-notes/rdr2-vk/`).

- `ing1`: landing page after about 90 s, Enter (Story mode), the latest save loaded in about
  3 minutes; then about 6 minutes of play: walking and turning the camera around Colter in
  snow, wading a river, the map, the pause menu, the weapon wheel and the satchel. Quit to the
  desktop from the pause menu ("unsaved progress will be lost").
- `ing2`: the same, with a scratch build of the layer (below). The game loaded the autosave
  `ing1` had written: a cabin interior, then outdoors again, about 2 minutes.

**Pipelines.** The game creates almost all of them before Story mode:

| SGA device (Fossilize) | landing (`prof2`) | `ing1` | `ing2` |
|---|---|---|---|
| shader modules | 13,251 | 13,251 (the same) | 13,251 (the same) |
| graphics pipelines | 1,940 | 1,943 (8 new, 5 of the landing's not made) | 1,948 (`ing1`'s and 5 more) |
| compute pipelines | 788 | 788 (the same) | 788 (the same) |
| graphics pipelines created (capture layer, duplicates included) | 2,150 | 2,157 | 2,162 |

The new ones repeat states the landing page already had (no new topology, sample count,
blend, depth or dynamic state); only their shaders differ. (inference: the game builds at
startup what its own pipeline list in `Settings/sga_vulkan_final_init.*` names, which this
prefix had from earlier play; `ing2`'s 5 extra are what `ing1` added to it.) All 1,953
graphics pipelines across the three databases are in `ing2`'s database and the landing
corpus.

**Replay on the host mock** (`run-replay.sh`, `mesa` b39d173 + `patches/mesa` 0001–0039, debug):

| | `ing1` | `ing2` | `ing2`, ImageMSArray gate bypassed (V4's scratch layer) |
|---|---|---|---|
| graphics built / of | 1,926 / 1,943 | 1,931 / 1,948 | 1,948 / 1,948 |
| compute built / of | 731 / 788 | 731 / 788 | 788 / 788 |
| modules failing validation | 87 | 87 | 0 |
| crashed pipelines | 0 | 0 | 0 |

An in-process replay of `ing2` with the bypass translated 3,915 MSL libraries, none with an
untranslated intrinsic. **No new crash group, so no new patch.** The skipped pipelines are V4's
(`ImageMSArray`), as on the landing page.

**What changes in the game** (`ing1` against `prof2`, both under the profile): the instance
and device create infos, the query pools (5 timestamp, 6 occlusion, the one
pipeline-statistics pool), descriptor set layouts, pipeline layouts, descriptor pools,
samplers and render passes are the same; no new distinct one. Sample counts are the same
(images at most 4, 96 pipelines asking for 8). What grows:

- images 5,940 → 27,471 (2D 26,812, 3D 633, 1D 26) and views 7,601 → 30,781: more BC1, BC3,
  BC4 and BC6H arrays, cube-compatible BC3 and R16_UNORM images; new cube views (BC3,
  R16_UNORM, B10G11R11) and cube-array views (BC4, BC6H, RGBA8 sRGB, and D32_SFLOAT_S8_UINT
  with depth and with stencil aspect);
- memory 41 allocations, 1,038 MiB → 103, 2,787 MiB (the profile's one 5 GiB heap);
- commands: 10,404,713 indirect draws (all with `drawCount` 1) and 1,703,131 indirect
  dispatches over 3.02 million render passes, where the landing page had none; 971,229
  `vkCmdSetDepthBounds`, 52,698 `vkCmdCopyQueryPoolResults`. The replay builds pipelines only,
  so none of this is tested by it.

**Linear-tiled images KosmicKrisp does not support.** Every optimal-tiling image the game
creates has the matching features in the KosmicKrisp report (above), but its linear-tiled
ones do not, and the landing page had them too. `ing2`'s scratch layer gave the game
KosmicKrisp's linear-tiling answers from `kk_image.c` (3D or attachment usage: not supported;
otherwise at most 1 layer and 1 mip level) and logged every image format query: the SGA
renderer made **no** `vkGetPhysicalDeviceImageFormatProperties` call, and created the same
images. Of the 11,519 linear images created after its device:

| | count | KosmicKrisp |
|---|---|---|
| 2D, 1 layer, 1 mip, no attachment usage | 10,633 | supported |
| 2D with `COLOR_ATTACHMENT` usage (R8_UNORM, R8_UINT, R16_UINT, R16G16_UINT, R32_SFLOAT, R32G32_SFLOAT, R32G32_UINT, R32G32B32A32_SFLOAT, R8G8B8A8_SRGB) | 435 | no `COLOR_ATTACHMENT` linear feature; `VK_ERROR_FORMAT_NOT_SUPPORTED` |
| 2D arrays, RGBA16F 16×28, 2–8 layers, transfer and sampled (Story mode only) | 386 | `maxArrayLayers` 1 |
| 3D, RGBA16F 64×64×16 and R32_UINT, storage, `2D_ARRAY_COMPATIBLE` | 56 | `VK_ERROR_FORMAT_NOT_SUPPORTED` |
| 2D R32_SFLOAT with 7 mip levels | 9 | `maxMipLevels` 1 |

KosmicKrisp's `vkCreateImage` does not refuse them: a linear image becomes a Metal texture
made from its memory's buffer (`newTextureWithDescriptor:offset:bytesPerRow:`). What Metal
does with such a descriptor for a 3D, array or mipmapped texture is not known here: the host
mock does not model it. Not fixed (a choice of what KosmicKrisp should make of them);
follow-up under PLA-386.

**Owner state.** The game wrote one autosave in `ing1` (the autosave slot, `SRDR30015`) and
the launcher uploaded files to Rockstar's cloud saves at that run's start and end
(`PostFile`); the manual save `SRDR30000` was not changed. `ing2` wrote no save and uploaded
nothing. Steam counted both runs as RDR2 play time; its content log shows no download.

Not checked on the phone; desktop RADV under a profile, not KosmicKrisp itself.

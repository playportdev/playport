# DIRT 5 (Xbox): the minidump API set, then FP64 in a compute shader

**Date:** 2026-11-03. **Title:** DIRT 5, Xbox store copy `xbox-9PJGM0T0827V` (PC Game Pass,
GDK build `game_release.exe`). **Phone:** the test iPhone, dev app, Vulkan (Direct3D 12
through vkd3d-proton).

## Before: the process ends before its entry point

Dev IPA as installed on the branch `dev/pla-485-xbox-store` (1c59a59a plus local changes),
run `.work/ui-runs/20261103T073901`: the title ends with `c0000135` (STATUS_DLL_NOT_FOUND)
218 ms after it starts, before any window.

```
Library api-ms-win-core-debug-minidump-l1-1-0.dll (which is needed by L"C:\\Games\\DIRT 5\\game_release.exe") not found
Importing dlls for L"C:\\Games\\DIRT 5\\game_release.exe" failed, status c0000135
```

Wine's loader tries every import before failing (`fixup_imports`), and this is the only one
missing. Neither WineHQ (master, 2026-10-16) nor Valve's bleeding-edge has ever had the
contract. Windows hosts it in `dbgcore.dll`; its two functions, `MiniDumpWriteDump` and
`MiniDumpReadDumpStream`, are in Wine's `dbghelp.dll`.

## The change

`patches/wine-pe` 0065 adds `apiset api-ms-win-core-debug-minidump-l1-1-0 = dbghelp.dll` to
`dlls/apisetschema/apisetschema.spec`.

## After: the game starts and stops at a D3D12 pipeline

Dev IPA `3357fbb79df4b3fadb6e809650ac6446e341de71c0b812bf2f7b6b0d972fb224`, run
`.work/ui-runs/20261103T075259`: game started at +5.06 s, first window at +5.92 s, no first
frame. The game draws its splash art, then its crash handler (`crashhandler\crashhandler.exe`)
and an Error box show the same text (`screen-0060s.png`):

> 'tryCreatingPipelineStateFromCache(pipelineStateDesc, nullCachedPso, pInOutPipelineState)'
> failed with 'HR = 0x80070057, Reason = E_INVALIDARG …'

With `VKD3D_DEBUG=warn VKD3D_SHADER_DEBUG=warn` (the game's Graphics options, run
`.work/ui-runs/20261103T080151`), vkd3d-proton says why:

```
warn:vkd3d-proton:d3d12_device_validate_shader_meta: Attempting to use FP64 operations in shader 415379b2b0dec4e1, but this is not supported.
warn:vkd3d-proton:d3d12_pipeline_state_init_compute: Failed to create Vulkan compute pipeline, hr 0x80070057.
```

KosmicKrisp has no `shaderFloat64` (as for OpenGL's 3.3 ceiling, decision 0087), so
vkd3d-proton refuses any shader that declares FP64 operations. That is the next blocker; the
API set change is not the cause.

## With soft FP64: the game boots, the race renders black

`patches/mesa` 0144 adds `MESA_KK_EXPERIMENTAL=soft_fp64` (KosmicKrisp reports FP64 and lowers
it to integer code with Mesa's soft-fp64 library, as Intel's ANV does for this game), and the
title's compatibility entry sets it.

- **Host test** (`build/stages/mesa.sh .work/run/mesa hosttest`): `fp64.comp` (DIRT 5's loop
  plus double multiply, divide, fma, min/max, compares and conversions) builds only with the
  flag; its MSL (8,655 lines) names no `double`, and the other 187 libraries keep their MSL.
  Apple's Metal compiler (Metal Developer Tools for Windows, `msl-compile.sh`) compiles it to
  AIR; a one-line `double` kernel fails with "not supported in Metal".
- **Phone**, dev IPA `3f61cde05649fb4b7daa4c20738bb610282f79163e5561c753f5b71320039a07`, run
  `.work/ui-runs/20261103T100828`: no FP64 refusal and no error box; the game compiles its
  pipelines for about 150 s and its first frame is at +155.5 s. A race starts (HUD, minimap,
  standings, lap timer, 17 to 32 FPS), but the 3D scene is black: only out-of-focus particles
  and a bloom smear show (`screen-0300s.png`; the owner's play the same).

## A null image overwrote the world's transform buffers

A race-frame GPU capture (`MESA_KK_DEBUG=no_compression`, `patches/mesa` 0145, so heap
snapshots hold plain texels) showed the G-buffer pass's depth and normal targets holding
only their clear values. Its first draw's vertex shader reads the objects' transforms
through the raw-buffer descriptor set, slot `push[5] + 21` (2,933), and that slot and its
four neighbours below were zero for the whole frame, although vkd3d-proton's offset buffer
had the view. The `MESA_KK_WATCH_DESC` trace (0146) showed the buffer descriptor written,
then nothing through the buffer path: vkd3d-proton writes a null of the game's type (a
64-byte sampled image) into every set of a heap slot, and KosmicKrisp copied it whole into
the buffer-only mutable binding's 16-byte elements, over the next three.

`patches/mesa` 0147 cuts a descriptor write to its element. The host test writes a storage
buffer into element 1 of such a binding, then a null sampled image into element 0: without
the fix a copy of element 1 reads zeros, with it the buffer.

Phone, dev IPA `083152d5641f98f3f2cb9d95593452fc341e2e4056875040292d2674ae8c891a`, capture
`.work/gpu-runs/20261103T125747`: slot 2,933 holds a 13 MB buffer; the G-buffer pass now has
depth on 72% of pixels and 133,944 distinct normal values. The race is still black: the
deferred lighting compute writes NaN (`0xfc3f07e0`, RG11B10F's NaN in all three channels) into
92% of the HDR target, which held 2.6% NaN before it, and the tonemap turns that black. The
lighting constant buffer's fields are finite.

## The NaN is the scene's history

Same capture. The lighting kernel's inputs, by descriptor (texture views resolved to the trace's
textures by creation order; `gpudebug` on the Mac lists them):

- a 64-byte sun buffer, written by pass 49, is NaN in the RGB of all three vec4s from the frame's
  start to its end (w finite);
- the fog volumes (three 48x24x96 and two 32x16x24 RGBA16F) are NaN in RGB, 58% and 100%, with
  alpha finite; the 32x16x24 ones are rewritten this frame (command buffer 74) from the last
  frame's;
- 1024x1024 tables are 78.5% NaN (RG11B10F) and hold +Inf (RGBA16F); this frame does not write
  them.

All are canonical NaN (`0x7e00`, `0xfc3f07e0`), so a GPU computed them. The sun buffer's writer is
an 8x8 reduction with a barrier between its steps, reading the sky tables; the sky and fog read
the sun buffer: once one NaN enters, the loop keeps it. The front end's 3D background is black
at first frame +60 s too.

Ruled out on the way: `MESA_KK_SAFE_MATH=1` (Metal's safe math and precise functions) leaves the
race black (`.work/ui-runs/20261103T132619`); Metal's `saturate`, `clamp` and
`precise::fmin(fmax)` return 0 for NaN under each of KosmicKrisp's library math options (a Metal
probe on an M1 Pro, not the phone's GPU). The FP64 shader soft-FP64 lowers writes
`clamp(sum, 0, 1)` into a 128x128 image, not these tables.

## 2026-11-10: the tables hold Inf and NaN, and D3D12's store writes 0

The same race capture's 1024x1024 RGBA16F table holds +Inf and the RG11B10F one
`0xfc3f07e0`, the NaN a Metal store writes for a NaN. The game's shaders produce
those values; the deferred lighting reads the +Inf through a multiply by 0, which is
NaN, and the tonemap draws the race black.

Metal keeps them. Probes on the Mac (M1 Pro, `.work/scratch/rg11/`): an RGBA16F and
an RG11B10F render target store `Inf` as `0x7c00`/`0xf83e07c0` and NaN as
`0x7e00`/`0xfc3f07e0`, and a finite overflow clamps to the format's max; a compute
store of Inf to RGBA16F clamps to the max finite. D3D12's render target conversion
writes 0 for those Inf and NaN values: clamping them to the format maximum (65504) left
the garage and the race white, but 0 gave the garage its colors and the race its track.

`patches/mesa` 0150 adds `MESA_KK_EXPERIMENTAL=clamp_float_output`: in the
format-aware fragment output pass that already converts the output type, a float color
output that is Inf or NaN becomes 0. DIRT 5's compatibility entry sets
`soft_fp64,clamp_float_output`.

Phone, dev IPA `e4afe761d12b95594a031b58586ec53a37720f3df5335b35be89c76a793d43fb`,
plays `.work/ui-runs/20261110T202401` (first frame at +68.13 s, the new shaders'
compile) and the manual route's screenshots
`.work/ui-runs/dirt5-fix/zero-race6.png` (the race's car, track, bridge, puddles and
HUD; 14 FPS at thermal Serious, not a measurement) and `zero-hub.png` (the garage
with its colors, under Video Options). The black scene is gone. The race was not
driven: the car stands at the start line.

## 2026-11-10, after the clamp: the sprites that go black are the flush's zero

The scene now renders, and two things in it are still wrong: the event's confetti,
spray and dust sprites draw as dark shapes at the race start and in the event
intro, and the sky of that event ("afternoon, cloudy") is a flat over-bright
white. Both look the same at Image Quality Ultra Low, Medium and High (the preset
was raised and lowered on the phone during the test), so neither is the low-quality
path.

**The sprites' colour is exactly what the clamp writes.** In the intro at Medium
(`.work/scratch/pla815a/q6.png`) the water behind a sprite is `(196,175,169)` and
the sprite is `(56,47,50)`: every channel is the background times `(1 - 0.71)`,
so the sprite's own colour is 0 with alpha 0.71, not a dark texture. A
premultiplied or straight alpha blend of a zero source over that water gives those
three numbers, so the sprite's *colour output* is the 0 the flush writes for NaN or
Inf, while its *alpha* survives (the flush is per component). On the race's start
line (`.work/scratch/pla815a/s16.png`, Ultra Low) the same sprites cover the road
as a black mass. What produces the NaN in the colour and not in the alpha is still
unknown: the particle pass reads its per-instance data and its lighting from
compute-written buffers, and those are not flushed.

**Keeping Inf and NaN in the IEEE targets is not the answer.** `patches/mesa` 0150
now takes the flush's value and scope from the title's Graphics options
(`MESA_KK_CLAMP_FLOAT_OUTPUT=zero|max|none` and
`MESA_KK_CLAMP_FLOAT_OUTPUT_KEEP_IEEE=1`, a diagnostic default that keeps the
current behaviour). Phone, dev IPA
`91566575f996f8db39aa378d1613d2f29d7ad0abaf31cf4877937dd9106a7f8d`, one route to
the same start line with `MESA_KK_CLAMP_FLOAT_OUTPUT_KEEP_IEEE=1` (only
R11G11B10F and R9G9B9E5 convert, RGBA16F keeps whatever the shader wrote):
`.work/scratch/pla815a/keepieee3.png` shows the race with large black regions on
its right half — the `Inf * 0` NaN that started this is back, so the game *is*
written for a store conversion that turns Inf and NaN into 0 in RGBA16F too, and
the default stands. `MESA_KK_DEBUG=os26_workarounds` (every iOS 27 workaround back
on) changes neither the sprites nor the sky (`os26-race2.png`,
`os26-intro.png`, 6 FPS: the workarounds cost that much).

**The frames.** Two captures of the current build, read with `pp gpu read`:
`.work/gpu-runs/20261110T212655` (race, frame 5600: 54 command buffers, 116
passes, 3018 draws) and `.work/gpu-runs/20261110T220133` (event intro, frame
4200, `MESA_KK_DEBUG=no_compression`: 102 command buffers, 161 passes, 3337
draws). The renderer's shape is a depth prepass, an `RGBA16F 1564x720` colour
pass, four `640x320 RG11B10F` passes with depth, a full-resolution
`RG11B10F` pass with depth (the decals), the HUD and a fullscreen tonemap.

**Where this stops.** The colour targets cannot be read out of these traces from
the workstation: `tools/gputrace.py` and `.work/scratch/rtdump.py` see every
`MTLHeap-231150-*` alias for the `RGBA16F` target's heap resolve to one 9.4 MB
zeroed file, and the `RG11B10F` target decodes as stripes at every row pitch they
try, so the iOS 27.2 / Metal 4 bundle's snapshot naming and pitch need fixing
first. Apple's own reader cannot stand in yet either: the MacBook (macOS 27.2,
Xcode 27.2, `gpudebug` 1.0) replays an A19 Pro trace only on the phone, the M1 Pro
reports "GPU address range, argument buffer internal format" as incompatible, and
`gpucapture --list-devices` needs Xcode's GPU tools agent, which starts only with
the phone cabled and trusted by that Mac (`xcrun devicectl` sees it over the
network only). A RenderDoc reference of the same event on a Direct3D 12 renderer
needs the Xodus Nexus workstation setup from 2026-10-30, which is no longer on
disk (only its licence notices are).


### A typed image store is not where the Inf lives

The default flush runs on a fragment shader's colour output. The 1024x1024
RGBA16F table a frame carries holds Inf (the intro capture's copy,
`.work/gpu-runs/20261110T220133`: `(1, inf, inf, 0)` at one sampled texel,
152,649 texels with Inf), and no fragment pass of the captured frame writes it,
so 0150 was extended to flush a typed image store too, in every stage but
fragment (`kk_lower_nir`). Phone, dev IPA
`00b05fbe202fa904c2e8d8a997e39aba4203ed59fdf2339e41c518a92460e5d3` (98 IPA
checks): the race's start line draws the same black sprites and the same white
sky (`.work/scratch/pla815a/imagestore3.png`, 1.95 s into the race, the
confetti burst). The extension is reverted rather than shipped: it costs an
Inf/NaN test on every float image store and nothing visible came of it.

Neither table dump is trustworthy yet either. Both the RGBA16F and the RG11B10F
1024x1024 tables decode as stripes at every row pitch the readers try
(`.work/gpu-runs/20261110T220133/tab*/`), so the "15 % Inf" above and the
"78.5 % NaN" of 2026-11-03 may be artefacts of the layout guess, not the
tables' contents.

Last, the MacBook (cabled phone, 172 GB free, Xcode 27.2, gpudebug 1.0) went off
the network at 23:45 while Xcode's GPU tools agent was still not up: `open -a
Xcode`, a hidden launch, a GUI-session `launchctl asuser` launch and waiting
minutes each left `gpucapture --list-devices` at "Remote device browsing
requires Xcode to be running", so it is a person's step: open Xcode and Window ›
Devices and Simulators once with the phone shown.

## 2026-11-11: the MacBook answers; D3D's conversion; the black glass is an empty reflection probe

**The Mac.** Over SSH, macOS 27.2 and Xcode 27.2: `gpucapture --list-devices`
lists the MacBook and the cabled iPhone. After a restart the GPU tools agent
came up only once Xcode was opened again; `gpudebug -d 1` then replayed the
3.2 GB race trace (`kk-frame5600-1794342742`) and the 5.2 GB intro trace
(`kk-frame4200-1794344778`) on the phone in about a minute. A trace larger than
the phone's free space leaves GTReplayService in "failed to load trace: File
transfer failed" until Xcode is restarted; the Dirt 5 runs below had 88 GB free.

**D3D's conversion is not what the clamp does.** The D3D11.3 functional spec
(3.2.2) keeps NaN where the format encodes one, and Inf where it can, and gives
0/max only where it cannot. `MESA_KK_CLAMP_FLOAT_OUTPUT=d3d` and `inf_max`
(`patches/mesa` 0152, 0153, since dropped) were built and played with
`zero_init`: both turn the garage and the race **white**
(`.work/scratch/pla815a/d3d-garage.png`, `infmax-garage.png`,
`race-now.png`). The original `zero` is the only mode that keeps the scene
visible, so DIRT 5's data has an Inf in an RGBA16F target where the game wants
0; either the game relies on a store conversion beyond the spec or the Inf is
ours. `zero` stays the title's setting.

**Zero initialisation.** `MESA_KK_EXPERIMENTAL=zero_init` (`patches/mesa` 0151)
zeroes each `VkDeviceMemory` allocation before it is returned, the value D3D12
promises and the driver does not. With `zero,zero_init` the garage showed a blue
cloudy sky where it had been flat white (`.work/scratch/pla815a/garage-zero2.png`),
but a later view (`.work/scratch/pla815a/nulldesc-garage.png`) was white again,
and the car windows and the garage's glass stayed black at every image quality.
It is kept as the D3D12 fix and a diagnostic; it is not the whole cause.

**The black glass is an empty reflection probe.** The garage scene's 41-draw
pass (`commands/cb93/re0`, capture pass 103) is a G-buffer/mask pass: its
pipelines write `color0 = 0` and a mask or alpha to `color1` (for example
draw29, lib189, and draw30, lib221); the final colour is computed later. The
reflection source is a 128x128 RG11B10F `2DArray`, 30 slices, 6 mips
(`@tex569`, usage ShaderRead/Write/RenderTarget); `fetch @tex569` is entirely
0. The only captured pass with a 128x128 RG11B10F target is a clear with no
draws, and no captured compute dispatch binds `@tex569` directly. The probe is
cleared and not written in the captured frame. The 1024x1024 RG11B10F sky
table does hold a cloudy sky (`.work/scratch/pla815a/rt/rg11b10.png`), so the
direct sky source is not the probe. The car and garage windows sample the black
probe and are black; the fragment clamp cannot help a texture that is 0.

**Still open.** The probe's writer is not in the captured frame: a startup pass
the capture missed, a compute the argument buffer hides, or a pass the title
skips on KosmicKrisp. That is the next question; the Mac tools now replay both
traces on the phone.

**The probe's catalog entry.** In the garage trace's device resources it is
created by `MTLHeap_newTextureWithDescriptor_offset` (object `0x713c7d5400`):
a 128x128 RG11B10F `2DArray`, 30 slices, 6 mips, usage 23. In the frame it is
not an attachment and no explicit call names it; it is sampled only through an
argument buffer by the compute shader `lib69` (the lighting kernel, which reads
`texturecube_array` at a reflection vector and slice). A 128x128 RG11B10F pass
with no draws is the only pass with that target. The garage-menu frames
(1200 and 3000) have no such pass at all; the first-frame trace's 140 startup
dispatches are vkd3d's `vkCmdFillMemoryKHR` zero fills, not the probe. The
writer therefore runs at the garage load or is skipped, and the probe stays 0.

**The video budget is not the black surfaces.** The 12 GB tier's plan gives 3072 MiB
video (Dirt 5's `memory plan` line); a play with `runtime:
vram-mb=4096 env.PLAYPORT_VK_BUDGET_MB=4096 env.PLAYPORT_VK_HEAP_MB=4096`
logs `[kk-memory] heap 0: size 8192 MiB, budget capped at 4096 MiB`. The
garage's front windshield then showed blue
(`.work/scratch/pla815a/vram4g-intro.png`), but the car's rear window and the
event's large black flag/banner polygons stayed black, and the sky stayed flat
white (`.work/scratch/pla815a/vram4g-intro2.png`). The budget is not what makes
the transparent materials black; they are the forward/transparent shading
path, separate from the empty reflection probe.

**The black particles/flags are a mask pass.** In the event intro's 269-draw main
pass (`commands/cb30/re1`) the last instanced draws are 456x3, 519x6 and 84x5
(the same counts as the garage's draw235-237). Their pipeline's fragment shader
(`lib165`) writes `color_0 = 0` and reads no varyings: a depth/stencil mask, not
a coloured sprite. The colour is composited later (the 24-dispatch compute after
the 41-draw particle pass), so the fragment clamp never sees the black. The
intro trace's main-pass colour fetch hangs in the 5 GB replayer; the 3.4 GB
garage trace fetches normally and shows the same mask draws.

The 24 dispatches after the particle pass are a **bloom/mip chain** (1568x720,
1x1, 688x352, 256x90, 128x195...), not the particle colour. The mask's colour
source is therefore elsewhere: the deferred lighting/forward composite that
reads the R8 mask, or the particle material buffer. That is still open.

The mask pipelines' colour0 `writeMask` is **RGBA** in the Metal pipeline, and
KosmicKrisp translates the Vulkan colour write mask (bridge/mtl_compiler.m), so
the `color_0 = 0` writes to the G-buffer are the title's own state, not a
ignored write mask. The black windows/flags in the G-buffer are expected; the
lit colour comes from the deferred/lighting pass and the reflection probe. That
rules out the colour write mask as the cause.

**A new event trace, and its limit.** The event intro capture at frame 4200 with a
600 s play succeeded (5.34 GB; the earlier 420 s attempt ended before the frame).
In it the main pass's last draw is **indirect**: pipeline `rps30`, index buffer
`@buf11` offset 12058624 with a 24-byte index buffer, indirect buffer `@buf155`
offset 16449876. Its instance count would say whether the particle colour draw is
empty, but fetching the 16 MiB indirect buffer (like the colour target) hangs/
times out on the 5.3 GB trace; the 3.4 GB garage trace still fetches. The next
trace should shrink the resource set (shadows low/medium) so the event's particle
draw is fetchable.

**Shadow Quality Medium.** The event pause menu (RESUME/RESTART/PHOTOMODE/
SETTINGS → VIDEO OPTIONS) was driven to **Shadow Quality**; High → **Medium**.
A further LEFT raised the title's **Low Video Memory (VRAM)** alert (the 3 GB
budget), so Medium is what the save now holds; the next event capture uses it
with a 4 GB budget to avoid the alert and shrink the 8192 shadow maps.

That capture (frame 4200, 4 GB, Medium) produced a **5.12 GB** trace: the shadow
maps are 4096x4096 instead of 8192, but the file is still too large to fetch.
Its 266-draw main pass is a **different moment** (last draws 2, 2x2, 24x2, no
456x3 masks), so it does not show the black flags. The next capture targets the
garage/profile load at frame 2800, where the reflection probe is created or
updated.

That frame-2800 capture is the **event intro**, not the garage: 4096 shadow maps,
no 128x128 pass, 4.91 GB. The save resumes the event, so the intro route no
longer reaches the profile/garage; the probe writer must be captured from the
garage hub's load. The 3.4 GB garage frame 5600 remains the only fetchable garage
trace (and the only one that shows the empty probe).

**The particle colour draw is empty.** The frame-2800 event trace (4.6 GB on the
Mac, fetchable) has the same 269-draw main pass. Its last draw is indirect
(pipeline `rps30`, a 6-index quad); fetching `@buf155` at offset 16449876 gives
`[6, 0, 0, 0, 0]`: indexCount 6, **instanceCount 0**. The writer wrote 6 and 0,
so the particle colour pass draws nothing; the preceding mask draws (3/6/5
instances) blacken the silhouettes. A run **without** `zero_init` still shows the
black flags, so zero_init is not the cause: the colour culling/simulation writes
0 and is the next target.

`@buf155` is a 16 MiB **Shared** buffer (gpuAddress 0x1003e148000). At 0xFB0000
(it is 0xFB0000 + n*20) sits a table of **20-byte `[6,0,0,0,0]` entries** — the
particle colour draw's ExecuteIndirect arguments. The index count 6 is set, the
instance count is 0; the buffer is Shared, so the game's CPU wrote this table.
The visible mask draws (3/6/5) still draw; the colour args are culled to zero.
The next target is the particle count/readback that fills these args (the GPU
particle simulation or the CPU culling), not the args buffer itself.

**No shader/pipeline error in the event/profile path.** A garage-profile run with
`VKD3D_DEBUG=warn VKD3D_SHADER_DEBUG=warn` logged **no `err:vkd3d`**; its warnings
are the startup feature notices, split `ResourceBarrier` flags and normal DXBC
checksum/unknown-dword skips. The 64-bit buffer atomics notice is startup-only.
The zero particle args are therefore not a shader compile failure. An arg-table
scan (128 KiB buffers for a pointer into `@buf155`) was attempted; the per-buffer
fetches stalled on the 4.6 GB trace and were stopped.

**The particle append shader.** `lib68` is the GPU particle queue append: it
builds a 64-bit counter/list pointer from a `packed_uint4` descriptor and an
incrementing 32-bit device atomic, writing a particle index into the list. Its
first spawn condition is 0, so the queue stays empty and the colour args read 0;
the dispatch itself is present and does not fault. The game's GPU particle
emission/spawn is the missing input.

**A required extension is missing.** vkd3d's startup warning says
`VK_EXT_dynamic_rendering_unused_attachments not supported. The functionality in
this EXT is required for correct operation.` KosmicKrisp exposes KHR dynamic
rendering and local read but not this EXT. The mask/deferred PSOs with unused
attachments are exactly what the extension covers; adding it to KosmicKrisp is
the next driver experiment.

**The extension test.** The 0152 patch exposes the extension and its feature;
the build (IPA `3fdc9685`, sha256
`3fdc96853ec9fc71551f35a18536b5a42487380973cec34769c602d5828342f2`) compiles and
installs, and vkd3d's startup **warning is gone** (0 occurrences in the log). The
visuals are unchanged: the event's black flags and white sky
(`.work/scratch/pla815a/ext-event2.png`) and the garage's black glass
(`.work/scratch/pla815a/ext-profile2.png`). The extension is spec-correct but is
not the visual fix; the particle emission and the reflection probe remain.

**The barrier-visibility flag does not fix it.** A garage run with
`MESA_KK_EXPERIMENTAL=...,barrier_device_vis` (IPA `3fdc9685`) still shows the
black car windows (`.work/scratch/pla815a/bardev-profile2.png`); the flag is
neutral for the probe/particles. The GPU-driven particle colour and the empty
reflection cube array remain the targets.

**The profile/garage route.** The player-card NUMBER screen is the garage
livery; its background is the garage itself, and a GARAGE tile is not on the
podcast/profile path (wait-text for GARAGE pressed A through the clips to the
profile). The profile appears before the event (the frame-2800 event trace), so
a frame-2600 capture with the intro route should be the garage/profile load and
the probe writer.

That frame-2600 capture is the **event**, not the profile: 5.37 GB, 160 passes,
3837 draws, no 128x128 pass. The profile comes later on this route; the next
attempt is frame 3000-3500.


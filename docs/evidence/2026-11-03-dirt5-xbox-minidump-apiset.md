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

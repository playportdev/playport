# Plan: KosmicKrisp by default for Direct3D 8–12

**Linear:** [PLA-77](https://linear.app/playportdev/issue/PLA-77).
**Review:** open/partial. Detailed performance work is PLA-72; its unmerged
`vulkan-performance` handoff supersedes the old measurement protocol. Reconcile
routing claims below against current code. DXMT and the incomplete i386 backend
set remain; Valheim still needs DXMT (PLA-65), so retirement is not complete.

**Date:** 2026-10-06. **Kind:** plan, not started. **Pins read:** `pins.lock` on
`madeira-freeze` (working tree, 2026-10-06): `madeira` 8c050d0 (frozen, decision
0054), `mesa` b39d173 + `patches/mesa` (16), `dxvk` e5ffd0f (unmodified),
`vkd3d-proton` 31d1f89 + `patches/vkd3d-proton` (4), `dxmt` 68af85e +
`patches/dxmt-port` (45) + `patches/dxmt` (9), `llvm-project` 15.0.7 (held for
airconv). Valve reference: Proton bleeding-edge `b3749405` (DXVK `d30be2b`,
vkd3d-proton `31d1f89`).

## Goal and the owner's direction

The owner's direction (2026-10-06):

- The end goal is Direct3D 8–12 with as little divergence from Proton as possible.
- DXMT is not that. Valve supports DXVK (d3d8/9/10/11) and vkd3d-proton (d3d12).
  Playport should maintain only the glue between Vulkan and Metal: KosmicKrisp in
  Mesa, plus winevulkan. Everything else stays as close to Proton as possible.
- Madeira is frozen at 8c050d0 (decision 0054). Playport owns that layer, and DXMT
  is to be dropped eventually.
- Nothing is offered upstream (0049, 0053). "Close to upstream" here means only that
  `patches/mesa` should differ from Mesa `main` as little as possible.

The end state is that every title, x86-64 and i386, defaults to DXVK or
vkd3d-proton on KosmicKrisp, as Proton does on Linux, and DXMT, winemetal,
airconv and LLVM 15 are no longer built.

## Measurements (2026-10-06)

Everything below was read from the repository, `.work`, or public upstream pages.
Lines marked *Inference* are not measured.

### 1. Where DXMT is used today, and what Vulkan has shown

**Selection rule** (`app/PlayportKit/Sources/PlayportKit/LaunchSettings.swift`
`resolve`): `game?.graphics ?? global.graphics ?? (dx12 || i386 ? .vulkan : .default)`,
with `GraphicsBackend.default = .dxmt`.

- Detected Direct3D 12 goes to Vulkan (0044). The evidence is imports or the
  `-dx12`/`-d3d12`/`-force-d3d12` flags, and the last API flag wins
  (`Direct3D12.swift`).
- 0046 widens the detection (reachable DLLs, interposers, dynamic references) but
  keeps that routing.
- i386 executables go to Vulkan (0047).
- Everything else goes to DXMT. That means every x86-64 Direct3D 8, 9, 10 and 11
  title, and every title the detector marks *Unknown*.

**Titles on DXMT:**

- Hollow Knight (x86-64, D3D11; cohort, 0005). Every gate runs it on DXMT: the
  deps-latest final run logs `title: graphics: dxmt`
  (`$PLAYPORT_BUILD/perf-runs/dl-final-hk/this-launch.log`).
- The Witcher 3 1.32 (D3D11).
- En Garde! (D3D11 by default; `evidence/2026-09-30-en-garde.md`).
- Kingdom Come: Deliverance (`evidence/2026-10-01-kcd-*`).

On Vulkan: Portal 2 (i386, D3D9, by 0047's default) and MultiVersus (D3D12, set
per game).

**What DXMT cannot do:**

- It has only Direct3D 10/11 and no i386 build (0047).
- The x86-64 `Runtime/arm64ec-windows/d3d9.dll` is Wine's wined3d build (`app/artifacts.tsv`
  line 57, `P2`), and wined3d needs a GL that iOS lacks (0047). *Inference:* an x86-64
  Direct3D 9 title on today's default DXMT route therefore cannot create a device.
  0047 says none has been tried.
- The i386 Vulkan set is DXVK `d3d9.dll` only (`build/stages/vulkan-pe.sh` `dxvk32`:
  `-Denable_d3d8=false -Denable_d3d10=false -Denable_d3d11=false -Denable_dxgi=false`).
  i386 `d3d8.dll` is Wine's (`artifacts.tsv` line 367). *Inference:* an i386 D3D8,
  D3D10 or D3D11 title has no working backend today.

**Hollow Knight on Vulkan, everything measured.** There has never been a `pp perf`
A/B against DXMT.

| Date, source | Backend | What | Result |
|---|---|---|---|
| 2026-09-26, `evidence/2026-09-26-vulkan-d3d11-d3d12.md` | DXVK `52fe923` | menu; Dirtmouth walk | menu 120 fps, HUD `Direct`, GPU 6.8 ms; walk 57 fps (earlier IPA) |
| same | vkd3d-proton `472989a` (`-force-d3d12`) | menu; Dirtmouth bench | 120 fps, GPU 6.4 ms; 58 fps |
| 2026-09-28, `evidence/2026-09-28-wine-proton-rebase.md` §8.1 | DXMT / DXVK, same IPA | menu, HUD | DXMT 101 FPS, GPU 6.01 ms; Vulkan 99 FPS, GPU 5.64 ms, first frame +9.99 s |
| 2026-09-28, `evidence/2026-09-28-fex-band.md` §5, decision 0024 | DXVK, 6 compiler threads | 53 threads, 3,484 MB of the FEX band | menu at 120 FPS. **Four Vulkan plays froze**: in the menu's fade-in or after Start Game, with every thread in `os_sync_wait_on_address`. DXMT plays of the same IPAs did not freeze. Open: no later record closes it |
| 2026-09-30, `evidence/2026-09-30-d3d12-feature-level-12.md` | vkd3d-proton, `-force-d3d12` | starts | 3 of 5 starts reach the first frame (SIGBUS / bad pointer in UnityPlayer, "not investigated") |
| 2026-10-02, `evidence/2026-10-02-dx12-default.md` | vkd3d-proton by 0044 | 3 starts | 1 `0xc0000005` at 6 s, 2 passed |

**Hollow Knight on DXMT, the baseline to beat** (`dl-final-hk`,
`evidence/2026-10-05-deps-latest.md`, window t = 60–100 s, scripted walk at 60 FPS):

- 59.1 FPS in the window (p10 54.2 over the whole run);
- 72.1 Mi/f all threads, 23.0 Mi/f main thread;
- CPU 118 % (P 86 / E 32), CPU power 630 mW;
- hitches ≥25/50/100 ms in play: 151 / 3 / 2;
- GPU 5.9–6.8 ms (`summary.txt`, the `gpu` column).

Per thread at t = 75 s (`threads.txt`): `dxmt-encode-thr` 4.1 Mi/f (6 % of a core)
and `UnityGfxDeviceWorker` 9.7 Mi/f. The worker mixes Unity's guest code with DXMT's
ARM64EC `d3d11` and is not separated.

**Portal 2 on DXVK, the d3d share of frame CPU**
(`evidence/2026-10-05-portal2-cpu-spin.md`, `p2y-base`, 74.7 Mi/f):

- `dxvk-cs` takes 16 % of a core, 9.5 Mi/f (about 13 % of all instructions);
- in `--cpu-prof` samples, `dxvk-cs` is 11–14 % and `wow64win.dll` 4 %;
- here `d3d9.dll` is i686 code under FEX, not native.

### 2. KosmicKrisp's features at the pin, against DXVK and vkd3d-proton

**Source.** `$PLAYPORT_BUILD/run/mesa/mesa/src/kosmickrisp/vulkan/kk_physical_device.c` at
b39d173 + `patches/mesa`.

- It reports Vulkan 1.4 (`kk_get_vk_version`) and `conformanceVersion` 1.4.6.2.
- On family-10 GPUs it adds `depthBounds` and `EXT_sampler_filter_minmax`. The A19
  Pro is family 10 (0014).

**DXVK's hard requirements** (`$PLAYPORT_BUILD/run/vulkan-pe/dxvk/src/dxvk/dxvk_device_info.cpp`
lines 846–1116, `ENABLE_FEATURE(..., true)`):

- Vulkan 1.3 (`DxvkVulkanApiVersion`);
- core features: `depthBiasClamp`, `depthClamp`, `dualSrcBlend`, `fillModeNonSolid`,
  `fragmentStoresAndAtomics`, `fullDrawIndexUint32`, `geometryShader`,
  `imageCubeArray`, `independentBlend`, `multiDrawIndirect`, `multiViewport`,
  `occlusionQueryPrecise`, `robustBufferAccess`, `sampleRateShading`,
  `samplerAnisotropy`, `shaderClip/CullDistance`, `shaderImageGatherExtended`,
  `shaderInt16`, `shaderInt64`, `shaderSampledImageArrayDynamicIndexing`,
  `textureCompressionBC`;
- 1.1–1.3 features: `bufferDeviceAddress`, `descriptorIndexing`, `timelineSemaphore`,
  `vulkanMemoryModel`, `dynamicRendering`, `synchronization2`, `maintenance4`, and
  the rest marked `true`;
- extensions: `EXT_depth_clip_enable`, `robustBufferAccess2` and `nullDescriptor`
  (robustness2), `maintenance5`/`6`, `KHR_load_store_op_none`, `KHR_swapchain`.

**KosmicKrisp sets every one of them.** `geometryShader` and `fillModeNonSolid`
come only from `patches/mesa` 0005, and upstream `main` still lacks them (see 6).

**DXVK's D3D11 feature level** (`src/d3d11/d3d11_features.cpp`
`GetMaxFeatureLevel`):

- 11_0 needs `drawIndirectFirstInstance`, `fragmentStoresAndAtomics`,
  `multiDrawIndirect` and `tessellationShader`. KK has all four.
- 11_1 needs logic op and `vertexPipelineStoresAndAtomics`. KK has both.
- 12_0 needs tiled resources tier 2, which needs sparse binding.
- So **D3D11 reaches FL 11_1 and D3D10 is covered.**
- D3D9 asks for nothing beyond the core set (only optional uses of `depthBiasControl`,
  attachment feedback loops, `depthBounds` and `vertexPipelineStoresAndAtomics` in
  `src/d3d9`).
- D3D8 sits on DXVK's d3d9.

**vkd3d-proton** (`$PLAYPORT_BUILD/run/vulkan-pe/vkd3d-proton/README.md`; `libs/vkd3d/device.c`
around 2498–2670 and 9650–9690):

- It requires Vulkan 1.3, all of descriptor indexing with 10⁶ update-after-bind
  descriptors (KK: `KK_MAX_DESCRIPTORS = 1 << 20`), `samplerMirrorClampToEdge`,
  `shaderDrawParameters`, robustness2 with `nullDescriptor`, `KHR_push_descriptor`,
  maintenance5/6, transform feedback, vertex attribute divisor and texel buffer
  alignment. KK has all of them.
- With `patches/vkd3d-proton` 0001/0002 (decision 0032) it reports FL 12_0 and SM 6.6
  on KosmicKrisp.
- 12_1 needs ROVs and conservative rasterization, which KK lacks.
- 12_2 needs mesh shaders, ray tracing, VRS, sampler feedback and tiled tier 3, which
  KK also lacks.

**Gaps, by name** (KK at the pin; "DXVK opt."/"vkd3d opt." means the layer treats it
as optional):

| Feature | KK at pin | Who wants it | Effect today |
|---|---|---|---|
| geometry shaders, `fillModeNonSolid` | `patches/mesa` 0005 (poly) | DXVK hard | Without 0005 DXVK refuses the device |
| transform feedback + geometry streams | `patches/mesa` 0006 (poly) | DXVK opt. (D3D10/11 stream output); vkd3d hard ("Lacking support for transform feedback") | — |
| tessellation | yes (upstream, poly) | DXVK FL11_0 | — |
| `pipelineStatisticsQuery` | absent | DXVK opt. | D3D11 statistics queries return zeros (0014) |
| `shaderFloat64` | absent | DXVK opt.; D3D12 doubles | Shaders using doubles fail. *Inference:* rare in games |
| `KHR_shader_atomic_int64`, `EXT_shader_image_atomic_int64` | `false` / absent | vkd3d SM 6.6 | Exposed anyway by vkd3d 0002, so a shader that uses them fails (0032: Nanite) |
| float controls (independence NONE), compute derivatives | partial / absent | vkd3d SM 6.6 | Same, by 0002 |
| sparse binding / residency | absent | DXVK opt.; vkd3d tiled resources | No tiled resources, so D3D11 caps at FL 11_1. D3D12 gets 12_0 only through vkd3d 0001 |
| `EXT_graphics_pipeline_library` | absent (properties only) | DXVK opt.; vkd3d opt. | DXVK builds whole pipelines at draw time. Portal 2's first Metal pipeline builds hitch 0.2–0.4 s (`evidence/2026-10-05-portal2-hitches-requests.md`) |
| `EXT_shader_module_identifier`, `EXT_descriptor_buffer`, mutable descriptors | absent, absent, **yes** | vkd3d recommended | Mutable descriptors present. *Inference:* the other two cost some CPU |
| `EXT_fragment_shader_interlock` (ROV), `EXT_conservative_rasterization` | absent | D3D11 FL12_1, D3D12 FL12_1 | Caps D3D12 at 12_0 |
| `EXT_extended_dynamic_state3` | partial (depth clamp/clip, line mode, provoking vertex, sample locations, tess origin) | DXVK opt. (alpha-to-coverage, rasterization samples, sample mask) | *Inference:* more pipeline variants |
| `EXT_vertex_input_dynamic_state`, `EXT_depth_bias_control`, `EXT_memory_priority`, `EXT_pageable_device_local_memory`, `EXT_non_seamless_cube_map` | absent | DXVK opt. | Minor |
| `EXT_custom_border_color`, `EXT_image_view_min_lod` | behind `MESA_KK_EXPERIMENTAL` | DXVK opt.; vkd3d "should" (min_lod) | Off unless set |
| `wideLines`, `variableMultisampleRate`, `shaderStorageImageMultisample` | absent | DXVK opt. | Minor |
| depth clip, robustness2, `EXT_extended_dynamic_state`/`2`, timeline semaphore, BDA, descriptor indexing, int64 (non-atomic), 16-bit and 8-bit storage | yes | DXVK/vkd3d hard | — |
| mesh shaders, ray tracing, VRS | absent | D3D12 Ultimate (12_2) | Out of reach |

### 3. x86-64 or ARM64EC

- **Playport already builds DXVK and vkd3d-proton as ARM64EC for x86-64 titles.**
  `build/stages/vulkan-pe.sh`: `ARCH=arm64ec`, llvm-mingw `arm64ec-w64-mingw32-clang`.
  It stages `Runtime/vulkan/arm64ec-windows/{d3d8,d3d9,d3d10core,d3d11,dxgi,d3d12,d3d12core}.dll`
  (`artifacts.tsv` 923–929) and marks them builtin with `winebuild --builtin`.
- i386 gets only `d3d9.dll`, built for i686 and run under FEX's `xtajit.dll`
  (`artifacts.tsv` 930). DXMT is ARM64EC too (`P5-dxmt-pe`), so for x86-64 titles
  both backends run native translation code.
- **Proton ARM64 at `b3749405`** (`Makefile.in` lines 700–716 and 836–856):
  - DXVK and vkd3d-proton are built for `i386`, `x86_64` and `arm64ec`;
  - the arm64ec build adds `DXVK_arm64ec_CFLAGS = -marm64x` (and the same for
    vkd3d-proton) and installs into `lib/wine/{dxvk,vkd3d-proton}/aarch64-windows`;
  - the `proton` script sets `host_pe_arch = "aarch64-windows"` on ARM64 (line 577),
    so an x86-64 game gets the ARM64X DLLs and an i386 game gets the i386 ones
    (`arch_pe_dir`, lines 1195–1208).
- **Differences from Proton:**
  1. Playport builds plain ARM64EC, not ARM64X. *Inference:* there is no effect for
     x86-64 guests, which use the EC view. ARM64X only adds a native-arm64 view.
     Table C of the alignment plan records "`-marm64x` … not applicable: all guests are
     x86".
  2. Playport builds no i386 DXVK `d3d8/d3d10core/d3d11/dxgi` and no i386
     vkd3d-proton.
- **CPU effect.**
  - x86-64 titles: none to gain from the build architecture, since they are already
    native.
  - i386 titles: DXVK stays emulated, as on Proton. Neither Wine nor llvm-mingw builds
    hybrid i386 PE. *Inference:* the CHPE-for-x86 that Windows once had is not
    available.
  - The emulated d3d cost is measured on Portal 2: `dxvk-cs` 9.5 Mi/f of 74.7 (about
    13 %), plus `wow64win` 4 % of samples.
  - The x86-64 DXVK-against-DXMT CPU comparison has never been measured. That is
    step 1.

### 4. winevulkan

**64-bit path:**

1. `Runtime/arm64ec-windows/winevulkan.dll` and `vulkan-1.dll` (Wine PE, `P2`).
2. winevulkan's unix side (`vulkan.c`, `vulkan_thunks.c`) is compiled into
   `libntdll_unix.a` as `winevulkan_unix_call_funcs` (`patches/madeira-unix` 0029, a
   5-file, +100 patch).
3. win32u's Vulkan dlopens `@rpath/KosmicKrisp.framework/KosmicKrisp` directly. There
   is no ICD loader: `vkGetInstanceProcAddr` goes straight to the driver's
   `vk_icdGetInstanceProcAddr`.
4. The iOS user driver's `VulkanInit` makes a `VK_EXT_metal_surface` on the
   `CAMetalLayer` that `IOSDisplayShim` (Madeira, `P5-dxshim`) gives the window. It
   finds the layer with `dlsym`, as DXMT does.

**i386 path:**

- i386 `winevulkan.dll` / `vulkan-1.dll` run under FEX, through winevulkan's WoW64
  thunks (`thunk32_*`).
- `patches/wine-unix` 0011 converts `UlongToPtr`/`PtrToUlong` through the guest
  window (about 2,100 uses), and maps device memory with `VK_EXT_map_memory_placed`
  inside the window, rounded to 64 KiB (`evidence/2026-10-04-portal2-d3d9-vulkan.md`).

**Other Playport patches:**

- `wine-unix` 0004: the layered-API properties `pNext` chain;
- `mesa` 0008: KK's exported `vkGetDeviceProcAddr` answers as `kk_GetDeviceProcAddr`,
  so secondary command buffers record.

**Valve's Wine at bleeding-edge**
(`evidence/2026-10-05-deps-latest/valve-bleeding-edge-commits.tsv`):

- Every `winevulkan: Update to VK spec …` commit is already in wine-11.19.
- Left out as "proton": `3a3248354b0` (vk.xml/video.xml 1.4.357), `aabe7042e7f`
  "win32u: Hook semaphore access functions" and `66ee546cbea` "win32u: Support d3d12
  fence timelines".
- *Inference:* the last two serve vkd3d-proton's shared or timeline fences.
  vkd3d-proton logs "Shared fences not supported by Vulkan host" (`device.c` 7150)
  without them.
- Proton also uses the Linux Vulkan loader and its layers. Playport has neither.

### 5. What dropping DXMT removes, and what stays

| Item | Size or count | Source |
|---|---|---|
| `patches/dxmt-port` (Madeira's DXMT port) | 45 patches, +9,334 −865 lines | `patches/dxmt-port/*.patch` diffstats |
| `patches/dxmt` (Playport's) | 9 patches, +757 −52 | same |
| `libdxmt_combined.a` (winemetal unix, airconv, LLVM 15.0.7 iOS libs) | 115.5 MB link input; 51.8 MB of text in 1,540 members | `artifacts.tsv` 957; `llvm-size` |
| `llvm::` code in the app executable | 19.4 MB of the 56.0 MB `__text` of `S1Probe` (102 MB file) in IPA `d8350d4b` | `llvm-nm -n` address gaps. *Inference:* KK is built `-Dllvm=disabled`, so this LLVM is airconv's |
| DXMT PE DLLs (`d3d11`, `dxgi`, `winemetal`, `d3d10core` in arm64ec and aarch64) | 7 files, 14.2 MB | `artifacts.tsv` `P5-dxmt-pe` |
| winemetal unix slots | 150 slots (upstream 0–145, Madeira 146–149); `pp slots` (`tools/slots.py`); `gen_remote_guard.py`, `gen_api_names.py` | `artifacts.tsv` header, AGENTS.md "Pins" |
| remote-metal | Madeira `research/remote-metal/protocol.h`, `build/dxmt-ios`, `build/madeira_cfg.h`, taken by `dxmt-base.sh`/`dxmt-patched.sh` | `build/stages/dxmt-*.sh` |
| airconv's LLVM 15 hold | the `llvm-project` 15.0.7 row, held because airconv targets LLVM 15 | `deps-latest` row table |
| build | stage `dxmt` (`dxmt-base.sh`, `dxmt-patched.sh`, `dxmt-combined.sh`, `build/air-helpers/` with 3 `.ll` files); caches `llvm-ios-15.0.7`, `llvm-host-15.0.7`, `llvm-project-15.0.7`, `air-helpers-15.0.7`, `dxmt.git` | `build/pipeline` 304–313, 439–440 |
| app and tooling | `GraphicsBackend.dxmt`, the overlay switch (`PLAYPORT_DLL_OVERLAY`, `wine_host.c` 510–515), `DXMT_SHADER_CACHE_PATH`, `d3d12_converter_absent.c`, `DXMT_LOG_LEVEL`. In `tools/perf.py`: DXMT `Present` lines and pass-prof (`tools/passprof.py`, dxmt 0008). 29 DXMT references in `build/verify-ipa.py`, 16 in `stage-artifacts.py` | grep counts |
| notices | DXMT (LGPL-2.1+ / Madeira GPL-3.0), DXBCParser (MIT), LLVM 15 | `docs/LICENSING.md` 102–103 |

**Madeira-owned code that stops mattering:** the 45-patch DXMT port, remote-metal,
`build/dxmt-ios`, and Madeira's DXMT D3D9 frontend (carried unbuilt, 0052). Since
0054, a frozen Madeira gives no reason to carry them.

**What stays:**

- Madeira's ntdll/win32u/wineserver layer (`build/*-unix`, the `*_ios.c`
  replacements);
- Winios and `IOSDisplayShim`. The Vulkan surface takes its layer from the shim
  (madeira-unix 0029), so the shim stays even without DXMT;
- FEX's iOS port (`fex-port`, 63 patches) and rpmalloc;
- the JIT pool;
- GStreamer;
- winevulkan, KosmicKrisp, DXVK and vkd3d-proton.

**Build time.** In an incremental build the `dxmt` stage took 52 s
(`out/20261006-063953-d8350d4b/logs/build.log`, 12:28:16–12:29:08) with the LLVM 15
caches warm. A cold LLVM 15 iOS build is not measured.

### 6. Upstream KosmicKrisp

- **Status.**
  - `docs/drivers/kosmickrisp.rst` at the pin: "a Vulkan conformant implementation
    for macOS on Apple Silicon … No iOS support is present as of now". The driver
    reports conformance 1.4.6.2, from upstream `27b5db37` (2026-09-28).
  - LunarG (lunarg.com, "KosmicKrisp Achieves Vulkan 1.4 Conformance on Apple
    Silicon") says it is a Vulkan 1.4-conformant ICD in the Vulkan SDK.
- **In flight upstream** (gitlab.freedesktop.org/mesa/mesa API, 2026-10-06):
  - **!44786 "kk: Add geometry shader support"**, opened 2026-09-28, "by wiring up
    poly's existing emulation used by Honeykrisp". That is the same approach as
    `patches/mesa` 0005.
  - **!44928 "Draft: kk: Implement VK_EXT_transform_feedback"**, opened 2026-10-05.
    It depends on !44786 and works "on top of poly's geometry shader emulation, the
    same way hk does". That is the same approach as 0006.
  - **!39186 "kk: fix build for iOS"**, open since 2026-01-07.
  - Issue #14251, the "kk: wish list", has open items for sparse memory,
    `VK_EXT_graphics_pipeline_library`, shader object, mesh shaders, ray tracing,
    descriptor buffer/heap, DGC, transform feedback, and "a NIR to AIR compiler that
    skips MSL".
  - Issue #15957 "kk: Feature request to support DXVK" (2026-07-28) lists depth clip,
    `fillModeNonSolid`, `geometryShader` and memory mapping.
- **What `patches/mesa` carries** (16 patches, +4,633 −302):
  - **feature** (3): 0005 GS and fill (+940), 0006 XFB (+3,208), 0007 texel buffer
    views at any texel (+121). These are 92 % of the added lines. Upstream is now
    writing 0005 and 0006 itself.
  - **ios-port** (13, +364): displaySync, CoreGraphics, `vm_*` placed maps, the
    process memory limit, exported proc addresses, WSI residency, present-wait,
    scaled and opaque swap chains, the 4096-entry timestamp heap split, the shader
    cache key, the device and disk cache, and `MESA_KK_DEBUG=compile`.
  - *Inference:* 0001–0004 overlap !39186 in purpose. The rest are not upstream.

## Steps

Each step is its own change on a branch in this checkout (0028), with its build
records and an evidence record carrying the IPA sha256, and is committed when its
checks pass. "Gate" means `./pp test`, then, in one locked session,
`pp install --no-build` and `pp ui --play app-367520 --until first-frame+10 --shot`
and `pp ui --play app-620 --until first-frame+10 --shot` (as in the alignment plan).
"Perf pair" means the alignment plan's routes, started at thermal `nominal`:

```sh
./pp perf --secs 100 --pad first-frame+25:hk-new-game --pad first-frame+45:hk-walk
./pp perf --title app-620 --secs 140 --pad first-frame+30:p2-cold-boot --pad first-frame+88:p2-walk
```

Record FPS, Mi/f (main and all threads), CPU P/E and power, GPU ms, and hitches of
25/50/100 ms or more.

**D3D12 candidates:**

- MultiVersus (1818750): UE 5.1, FL 12_0, SM 6.6. Measured at 26–31 fps in Training
  (`evidence/2026-09-30-d3d12-feature-level-12.md`). 18 GB, offline.
- En Garde! (1654660) with `-dx12`: UE 5.1, splash only. D3D11 plays on DXMT.
- Rise of the Tomb Raider or Shadow of the Tomb Raider: D3D12 at FL 11_0 and also
  D3D11, so one title gives a DX11-against-DX12 A/B. Owned per the 2026-09-30 record;
  whether it fits is not checked.
- Civilization VI: D3D12 FL 11_0.
- Not usable: The Witcher 3 4.x (`x64_dx12`) faults on AVX under FEX
  (`evidence/2026-10-02-witcher3-executable.md`).

### Step 1. Measurement gate: Hollow Knight on DXVK/KosmicKrisp against DXMT

- **What is done:**
  - No product change.
  - On one IPA, run ABBA perf pairs of Hollow Knight with
    `--settings 'app-367520:{"graphics":"vulkan"}'` against `{}` (DXMT), four runs at
    60 FPS and two uncapped.
  - Add one `--cpu-prof` run of each, to split `dxvk-cs`, `dxvk-submit`, KK's encode
    and `UnityGfxDeviceWorker` against `dxmt-encode-thr`.
  - Reproduce 0024's freeze first: 10 plays to `first-frame+60` through Start Game
    (`--pad first-frame+25:hk-new-game`) and one 10-minute human play on Vulkan.
  - Also record the footprint and the FEX band (`band:`).
- **On the phone:** Hollow Knight as above. Portal 2's perf pair, since it is
  already on Vulkan, as the reference for KK cost.
- **Done when** an evidence record has:
  - the table of both backends;
  - the freeze's status (reproduced with a cause, or not in 10 + 1 plays);
  - a go or no-go against the thresholds the owner sets (question 1).

### Step 2. Close the KosmicKrisp gaps that matter, staying close to upstream

- **What is done:**
  1. Whatever step 1 finds: the freeze cause, or a frame-time or GPU regression,
     traced to KK, DXVK or winevulkan.
  2. **Converge 0005/0006 on upstream.**
     - Diff `patches/mesa` 0005/0006 against !44786/!44928 now.
     - At each Mesa move after they merge, drop Playport's patch and take upstream's.
     - Until they merge, keep ours (question 3).
  3. **Metal binary archive** for KK pipelines, for the 0.2–0.4 s first pipeline
     builds. Read on 2026-10-06: KosmicKrisp's Metal bridge compiles through
     `MTL4Compiler` and passes `compilerTaskOptions:nil`, and the SDK has
     `MTL4PipelineDataSetSerializer`, `newArchiveWithURL` and `lookupArchives`,
     so the archive can be written on one run and looked up on the next (the
     analysis is in the unmerged `madeira-main` branch's
     `docs/evidence/2026-10-06-proton-alignment-second-half.md`).
  4. Measure, without changing them yet: `pipelineStatisticsQuery` (zeros in D3D11)
     and `EXT_graphics_pipeline_library`, which is an upstream wish-list item and
     large. Both wait for a title that shows a need.
  5. Not attempted: sparse, ROV, conservative raster, mesh shaders and ray tracing.
     Metal 4 on A19 offers no direct path. *Inference:* these are a separate project.
- **On the phone:**
  - the gate;
  - Hollow Knight's Vulkan perf pair against step 1;
  - Portal 2's fresh-install human play for the archive (before and after);
  - MultiVersus to the title screen, to check D3D12 still runs.
- **Done when:**
  - Hollow Knight on Vulkan meets step 1's thresholds and does not freeze;
  - every `patches/mesa` patch has an evidence line saying "upstream equivalent:
    none / !NNNN / merged as …".

### Step 3. DXVK and vkd3d-proton builds: the Proton set

- **What is done:**
  - The x86-64 builds are already ARM64EC, so nothing changes there unless question 4
    takes ARM64X.
  - Extend `vulkan-pe.sh` `dxvk32` to Proton's i386 set: `d3d8`, `d3d9`, `d3d10core`,
    `d3d11` and `dxgi`.
  - Add an i386 vkd3d-proton (`d3d12`, `d3d12core`).
  - Stage them under `Runtime/vulkan/i386-windows/`, with the builtin marking, and add
    `pp verify` checks that each is a PE32 builtin.
  - Take the log defaults Proton uses in the release variant (alignment item B5:
    `DXVK_LOG_LEVEL`, `VKD3D_DEBUG` and `VKD3D_SHADER_DEBUG` set to `none`; done
    on the unmerged `madeira-main` branch as `1ddb644`, to be ported to `main`).
- **On the phone:**
  - the gate (Portal 2 must still load DXVK's i386 `d3d9` through the `syswow64`
    overlay);
  - one i386 D3D11 title if the library has one (owner to name).
- **Done when** the IPA carries the set, `pp verify` passes, and the gate passes.

### Step 4. Switch the default to Vulkan for x86-64 titles

- **What is done:**
  - `GraphicsBackend.default = .vulkan`. `resolve` then needs no DX12 or i386 branch,
    and 0046's detection stays as information on the game's page.
  - Update the Game options and Settings labels, and PlayportKit tests for precedence:
    the game's choice, then the global choice, then Vulkan.
  - Explicit DXMT choices stay. Existing choices are not migrated, as in 0044.
  - Decision record (below).
- **On the phone:**
  - the gate, with Hollow Knight now on Vulkan by default (log
    `title: graphics: vulkan`);
  - Hollow Knight's perf pair against step 1's DXMT runs;
  - The Witcher 3 1.32 (its display-mode failure, 0015, is recorded as known or fixed);
  - En Garde! (D3D11), KCD's load route, and MultiVersus;
  - one release-variant play of Hollow Knight.
- **Done when** both cohort titles pass the gate on the default, and the evidence
  record lists every installed title's result on Vulkan.

### Step 5. Keep DXMT as an option for a while

- **What is done:**
  - DXMT stays in the IPA as an explicit choice, labelled as the older backend.
  - Every step-1 style perf pair keeps one DXMT run as a control.
  - DXMT's pin keeps moving only if it builds (0049). A DXMT break is no longer a hold
    on other moves.
- **On the phone:** the gate per dependency move, plus a DXMT control play of Hollow
  Knight.
- **Done when** the exit criteria of question 6 hold: no installed title needs DXMT,
  and two consecutive Mesa/DXVK moves have passed on Vulkan.

### Step 6. A Direct3D 12 title in the cohort

- **What is done:**
  - Pin MultiVersus (or the owner's pick, question 7) by 0005's scorecard;
  - write a `tools/pad/` route (`multiversus-training` exists);
  - add a perf route.
  - If a Tomb Raider fits, add it too for the DX11/DX12 A/B on one title.
- **On the phone:** a perf run on its route, and 10 starts (to measure the start
  failures recorded for HK `-force-d3d12`).
- **Done when** the title passes `first-frame+10` in 10 of 10 starts and has a perf
  baseline, and the gate includes it.

### Step 7. Direct3D 8

- **What is done:**
  - Proton's default `d3d8` is Wine's wined3d build. DXVK's `d3d8` is opt-in there
    (`PROTON_DXVK_D3D8`, `proton` lines 1029 and 1182–1185).
  - On iOS wined3d has no GL, so take DXVK's `d3d8` by default (arm64ec, already built,
    and i386 from step 3).
  - Record the divergence (question 5).
- **On the phone:**
  - an i386 D3D8 title from the owner's library. *Inference:* most D3D8 games are
    i386. Candidates if owned: Max Payne (12140), Mafia (2002), GTA III or Vice City;
  - plus the gate.
- **Done when** a D3D8 title reaches its menu and plays, with a perf run recorded.

### Step 8. Remove DXMT

- **What is done**, one commit with its decision record:
  - Delete the `dxmt` stage and its scripts, `build/air-helpers`, the `dxmt`,
    `dxmt-port` and `llvm-project` rows, `patches/dxmt` and `patches/dxmt-port`,
    `pp slots`, the LLVM 15 caches from `pp setup`'s needs, `GraphicsBackend.dxmt`
    and the overlay.
  - Stage DXVK and vkd3d-proton in the main `Runtime/<arch>-windows` sets, as
    Proton's prefix has them in `system32`/`syswow64`.
  - Remove the DXMT parts of `wine_host.c`, `verify-ipa.py`, `stage-artifacts.py` and
    `tools/perf.py` (keeping HUD-based frame counting).
  - Update the notices and LICENSING.md, AGENTS.md ("After a DXMT rebase …"),
    ARCHITECTURE.md and BUILDING.md.
  - Give the KK path a GPU-capture route through Settings' Diagnostics
    (`MESA_KK_GPU_CAPTURE`, 0012: through the UI).
- **On the phone:** the gate, the perf pair on both titles and the D3D12 title, and a
  release-variant play.
- **Done when:**
  - the IPA has no DXMT artifact and `pp test`/`pp verify` pass;
  - the IPA and executable size change is recorded. Expected: about 14 MB of DLLs and
    up to about 19 MB of executable text. *Inference* until measured;
  - the gate passes.

## Decision records needed

- **Vulkan is the default Direct3D backend** (step 4). It supersedes:
  - 0044, whose DX12 rule is subsumed;
  - 0047's default-backend part (0047's cohort part stays);
  - 0046's routing role (detection becomes informational);
  - 0015's "DXMT stays the default";
  - 0003's "DXMT translating Direct3D 10/11".

  It extends 0005's cohort to Direct3D 8–12 titles.
- **i386 Direct3D set and build flavour** (step 3): Proton's i386 DXVK and
  vkd3d-proton set, and ARM64EC rather than ARM64X (or ARM64X if question 4 says so).
  It amends 0015 and confirms table C of the alignment plan.
- **Direct3D 8 on DXVK by default** (step 7): a recorded divergence from Proton's
  wined3d default.
- **`patches/mesa` tracks upstream** (step 2): a Playport patch is dropped when an
  upstream equivalent lands at a Mesa move. It amends 0014/0015.
- **DXMT removed** (step 8). It supersedes:
  - 0007 (DXMT on its upstream);
  - the DXMT rows of 0054 (the `dxmt-port` provenance row);
  - the `llvm-project` hold;
  - the `pp slots` rule.

  It leaves 0032 and 0024 standing.

## Risks

- **Hollow Knight's Vulkan freeze (0024) was never closed.** If it still reproduces,
  step 1 is a no-go until it is found. Portal 2's 23-minute DXVK play does not clear
  it: that is i386, D3D9 and another thread mix.
- **KosmicKrisp on iOS is unsupported upstream.** Its workarounds target M1–M5 on
  macOS (0014), and 13 ios-port patches carry the difference. Mesa `main` moves
  quickly: 369 commits between pins, 82d4f86 to b39d173.
- **Geometry and XFB through poly** cost a compute pass. *Inference:* their GPU cost
  on A19 is unmeasured. Upstream's versions may differ in behaviour from ours when we
  switch.
- **Shader stutter without GPL.** DXVK compiles pipelines at draw time. KK's disk
  cache helps only warm runs, and Metal's first build costs 0.2–0.4 s.
- **The D3D12 over-claim (0032).** SM 6.6 without 64-bit atomics or derivatives fails
  at shader compile rather than at start.
- **Memory.** MultiVersus ran at 6.8–7.2 GB of the 8 GB limit. DXVK, vkd3d-proton and
  KK footprints on Hollow Knight are not compared with DXMT's.
- **Losing the fallback.** After step 8 a title DXMT ran and Vulkan does not has no
  backend. The Witcher 3 1.32's display-mode failure on DXVK (0015) is one such title
  today.
- **Tooling.** `pp perf`'s fallback frame counting and the pass profiler are DXMT's
  (`tools/perf.py`, `tools/passprof.py`). Without replacements, GPU analysis on the
  phone gets coarser.
- **Thermal and CPU.** Unknown until step 1. *Inference:* DXVK's extra threads
  (`dxvk-cs`, submit, six shader workers) may cost more E/P time than DXMT's encoder.

## Open questions for the owner

1. **Go thresholds for step 1?** Recommended, at the 60 FPS cap:
   - FPS within 1 of DXMT;
   - all-thread Mi/f and CPU power at most 10 % above DXMT;
   - GPU ms at most 15 % above;
   - play-segment hitches ≥50 ms within DXMT's run-to-run spread;
   - no freeze in 10 plays plus one 10-minute human play.
2. **If Hollow Knight on Vulkan misses a threshold, switch anyway?** Recommended: no
   for D3D10/11. Switch x86-64 D3D9 and *Unknown*-with-D3D9-evidence titles at once,
   since DXMT cannot draw D3D9 and Wine's wined3d `d3d9` has no GL on iOS.
3. **GS and XFB: keep 0005/0006 or take the upstream MRs before they merge?**
   Recommended: keep ours until !44786 and !44928 merge, then replace them at the next
   Mesa move. Diff them now so the switch is planned.
4. **ARM64X (`-marm64x`) like Proton, or ARM64EC?** Recommended: ARM64EC. No guest
   calls the native view, the size grows, and table C already records the reason.
   Revisit if native ARM64 Windows games come into scope.
5. **Direct3D 8: DXVK by default (Proton's opt-in) or wined3d (Proton's default)?**
   Recommended: DXVK. wined3d needs GL here, and its Vulkan renderer is not what
   Proton ships either. Record the divergence.
6. **How long does DXMT stay as an option?** Recommended: until two consecutive Mesa
   or DXVK moves pass on Vulkan by default, and every installed D3D10/11 title has
   either run on Vulkan or been recorded as failing on both backends. Then remove it
   (step 8).
7. **Which D3D12 title joins the cohort?** Recommended: MultiVersus. It is already
   measured, it is FL 12_0/SM 6.6, it plays offline and it has a pad route. Add Rise of
   the Tomb Raider as the DX11/DX12 A/B if it fits on the phone.
8. **Keep the per-game DXMT picker after step 8?** Recommended: no. One backend, as
   on Proton, with per-game DXVK and vkd3d-proton configuration instead.
9. **Does a KK GPU-capture route in Diagnostics need to exist before step 8?**
   Recommended: yes, minimal: `MESA_KK_GPU_CAPTURE` behind Settings' Diagnostics in
   dev builds. It replaces DXMT's capture for `pp perf --gpu-capture`.

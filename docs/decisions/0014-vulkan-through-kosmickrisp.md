# 0014: Vulkan on iOS through KosmicKrisp

**Status:** proposed, 2026-09-26. It adds a component and changes nothing that
[0003](0003-runtime-backend.md) ships: until a later record accepts a Vulkan
path for titles, the IPA carries neither Vulkan nor DXVK, and DXMT stays the
only Direct3D layer.

**Accepted by [0015](0015-vulkan-backend-accepted.md)**, which ships the backend in every IPA.

## Decision

- Playport builds [KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html),
  Mesa's Vulkan 1.4 driver on Metal 4, for iOS: `libvulkan_kosmickrisp.dylib`
  for `arm64-apple-ios26.0`. Upstream builds it only for macOS 26 and later.
- `pins.lock`'s `mesa` row is a commit of Mesa `main`, and Playport's port is
  `patches/mesa`, class `ios-port`. `build/stages/mesa.sh` fetches the pin,
  applies the series, builds the Linux shader tools the driver's build runs
  (`mesa_clc`, `vtn_bindgen2`, `kk_clc`) and then the iOS dylib.
- `build/check-macho-imports.py` checks the dylib on the workstation. The
  driver links with `-undefined dynamic_lookup`, so it builds even when a
  symbol is missing, and dyld would refuse it only on the phone. The check
  resolves every non-weak import against the iPhoneOS SDK's stubs.
- The stage is not in `pp build` yet, and no IPA includes the dylib. Nothing in
  Wine calls Vulkan on iOS today, so the dylib would only add 14 MB, and the
  host would need LLVM, libclc and SPIRV-LLVM-Translator for every build.

## Why

- DXMT is the only Direct3D layer that runs here, and it covers D3D 10/11 only
  ([research](../research/2026-09-26-d3d-backends.md)). A conformant Vulkan
  driver would make DXVK (D3D 8–11) and vkd3d-proton (D3D 12) candidates. It
  would also allow the first A/B comparison against DXMT on the phone.
- MoltenVK, the other Vulkan layer on Metal, has no geometry shaders, and DXVK
  refuses a device without them. KosmicKrisp is built to be conformant, uses
  Metal 4, and already runs geometry work through Mesa's `poly` library.
- The port is small, which makes it cheap to carry. On Mesa `82d4f86`, iOS
  needed four patches (displaySyncEnabled, the mach_vm calls, CoreGraphics,
  the process memory limit). The same tree still builds for macOS.

## What it does not yet give

- **DXVK's two missing features are implemented in `patches/mesa`, not
  stubbed.** DXVK `52fe923` requires `geometryShader` and `fillModeNonSolid`,
  and upstream KosmicKrisp at the pin advertises neither. Patch 0005 adds
  geometry shaders the way honeykrisp does them on Apple GPUs, with Mesa's
  `poly` library, which KosmicKrisp already uses for tessellation. It adds
  line fill through Metal's triangle fill mode, and point fill through a
  geometry shader built into the pipeline. With both, KosmicKrisp sets every
  feature DXVK requires. This is checked on the workstation only
  ([record](../evidence/2026-09-26-kosmickrisp-gs-fill-host.md)): the driver
  builds for Linux on a mock Metal bridge and compiles and records such
  pipelines, but no GPU has drawn with them.
- **Transform feedback, which D3D11 stream output needs, is also in
  `patches/mesa`.** Patch 0006 adds `VK_EXT_transform_feedback` with
  geometry streams, stream queries and `vkCmdDrawIndirectByteCountEXT`, on
  poly again ([record](../evidence/2026-09-26-kosmickrisp-xfb-host.md)). It
  has the same limit as 0005: it has been checked on the workstation only.
- **Still missing** from what D3D11 on DXVK uses: pipeline statistics queries.
  DXVK treats them as optional, and D3D11 statistics queries then return
  zeros.
- **Nothing on the phone has run it.** Features, limits and workarounds are
  keyed on the Metal GPU family and the OS version. KosmicKrisp's workaround
  list is written for M1–M5 on macOS 26–27. The A19 Pro is Apple GPU family
  10, like the M5, and iOS 27 shares macOS 27's Metal compiler, but this is
  unverified.

## The switch

Settings and each game's page have a **Direct3D** picker: DXMT (the default)
or Vulkan. It is a launch setting like resolution: a game's own choice wins
over the global one (PlayportKit `LaunchSettings.graphics`).

- **How it works.** Vulkan's builtins live in `vulkan/<arch>-windows` under
  the runtime. The launch names that directory in `PLAYPORT_DLL_OVERLAY`, and
  `wine_host_init` puts it before the runtime in `WINEDLLPATH` and links its
  DLLs over the runtime's in the prefix's `system32`, so its `d3d11`, `dxgi`,
  `d3d12` and the other DLLs load instead of DXMT's. A later DXMT launch
  relinks `system32` to the runtime's set alone.
- **Builtin marking.** Madeira's loader ignores a DLL found through
  `WINEDLLPATH` that is not marked builtin, so the DXVK and vkd3d-proton DLLs
  must be staged with `winebuild --builtin`.
- **Builds without it.** A build without the directory shows Vulkan as "not
  in this build" and refuses such a launch before any JIT is spent.
- **Today** the `vulkan` build stage puts the backend in every IPA
  ([the device run](../evidence/2026-09-26-vulkan-d3d11-d3d12.md)).

## Order

Each step is its own change, and each ends in a device run once the phone is
allowed:

1. **Driver** (this record): the iOS dylib builds, and its imports resolve.
   The features DXVK requires are implemented, and a host test drives them
   (`build/stages/mesa.sh` stage `hosttest`).
2. **Wine**: `win32u`'s Vulkan with no loader (a `vkGetInstanceProcAddr`
   forwarding to `vk_icdGetInstanceProcAddr` in the bundled driver); the iOS
   user driver's `VulkanInit`, which today is Madeira's `nulldrv_VulkanInit`,
   creating a `VK_EXT_metal_surface` from the window's `CAMetalLayer`; and the
   `winevulkan` unix side.
3. **DXVK** built for ARM64EC with llvm-mingw, as `patches/dxvk` if it
   needs changes.
4. **Device gate**: first a Vulkan probe in the dev app's UI (decision 0012),
   then a D3D11 title through DXVK against the same title through DXMT.

## What it costs

- A fourth large upstream to rebase. Mesa `main` moves every day, and a pin
  move is a manual rebase of `patches/mesa`.
- Host build dependencies for the stage: LLVM with clang, libclc and
  SPIRV-LLVM-Translator. A first build takes a few minutes.
- KosmicKrisp and the Mesa code it links are MIT-style (their SPDX headers; Mesa's `docs/license.rst`), compatible with Playport's
  GPL-3.0-or-later. When an IPA carries it, its notices go into NOTICES.md.

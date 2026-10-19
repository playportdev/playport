# 0131: The Khronos Vulkan loader for a game whose own Vulkan layer must load

**Status:** accepted, 2026-10-19. The owner chose the loader (PLA-420: "build the Khronos
Vulkan-Loader from source for ARM64EC with llvm-mingw, as a new pinned component, for RDR2 only;
Wine's builtin stays for every other title"). The supervisor approved the design: the overlay list,
the manifest in the loader's set, the seed key and the pins.
[PLA-420](https://linear.app/playportdev/issue/PLA-420), [PLA-364](https://linear.app/playportdev/issue/PLA-364).
Stands beside [0014](0014-vulkan-through-kosmickrisp.md) and
[0015](0015-vulkan-backend-accepted.md), which ship Wine's `vulkan-1`/`winevulkan` as the Vulkan
path. Adds one registration to [0080](0080-prefix-wineboot-parity.md)'s seed.

## Context

- **The SDK stops without its layer.** RDR2's Social Club SDK needs its explicit Vulkan layer
  `VK_LAYER_ROCKSTAR_GAMES_social_club` (`SocialClubVulkanLayer.dll`, x86-64). The game asks for it
  at its `vkCreateInstance`.
  - The Social Club install registers it under HKLM `Software\Khronos\Vulkan\ExplicitLayers` and
    the `Wow6432Node` twin.
  - The phone's RDR2 prefix has both values.
  - Without the layer, the SDK logs `SocialClubVulkanLayer.dll not loaded.`, never starts its UI
    state machine, and so never signs in. The game shows "Social Club failed to initialize
    graphics device. Error code: 18". This was seen on the phone (run `20261019T201131`,
    [evidence](../evidence/2026-10-19-rdr2-warm-cache-error-18.md)) and on desktop Proton with
    the registry value removed.
- **Wine's builtin cannot load it.** Wine's `vulkan-1.dll` forwards to winevulkan, which
  enumerates no layers and refuses a layer name.
- **Proton gives RDR2 the Khronos loader.** The game's VulkanRT installer puts it in system32.
  On the phone that copy cannot last, because the session relinks system32 at every start.
- winevulkan is a Windows ICD:
  - it exports `vk_icdGetInstanceProcAddr`, `vk_icdGetPhysicalDeviceProcAddr` and
    `vk_icdNegotiateLoaderICDInterfaceVersion`;
  - its `DllRegisterServer`, which wineboot runs, registers it with that loader.

## Decision

- **A new pinned component, the Khronos Vulkan-Loader (Apache-2.0).**
  - It is unmodified and built at the tag of the wine pin's Vulkan headers. That is v1.4.363 now
    (`VK_HEADER_VERSION` 363), with Vulkan-Headers at the same tag. Both pins move with the wine
    pin's headers.
  - `build/stages/vulkan-pe.sh loader` builds it for arm64ec with llvm-mingw, with no assembler.
    The loader's trampolines for functions it does not know are aarch64 code, not ARM64EC. It is
    built with winevulkan's own headers, so it knows every function winevulkan has.
  - The build marks it a Wine builtin, as the backend's DLLs are.
  - It is staged with Wine's own `dlls/winevulkan/winevulkan.json`, the ICD manifest
    `DllRegisterServer` writes, as `Runtime/vulkan-loader/arm64ec-windows/{vulkan-1.dll,winevulkan.json}`.
  - It ships in both variants.
- **A per-game launch setting, `khronosVulkanLoader`.** Nil is off: Wine's loader.
  - The compatibility table turns it on for Red Dead Redemption 2 (`app-1174180`).
  - A dev build shows it as Game options › Developer › Vulkan loader (Khronos or Wine's).
  - A person's saved value and the driver's `settings:` change it in a dev build, as with
    `windowsServices` (0107).
  - A release build shows no row, so the table decides.
- **`PLAYPORT_DLL_OVERLAY` is now a list.** It names comma-separated runtime directories, linked
  over the runtime's sets in order, so a later one's file wins (`dll_overlay.h`).
  - The order is the backend's set (`vulkan`), then the loader's (`vulkan-loader`).
  - In system32 each overlay must link a file.
  - In the WoW64 farms an overlay with no set for that architecture is skipped.
  - WINEDLLPATH lists the last overlay first.
  - Each relink first removes every link into a runtime set. So the next play without the setting
    gets Wine's `vulkan-1.dll` back, and no `winevulkan.json`.
  - The session logs which `vulkan-1.dll` system32 links to: `system32: vulkan-1.dll -> <runtime
    path> sha256 <16 hex>`, the digest that file's row in `app/artifacts.tsv` has.
- **winevulkan's registration is in the seed.** This is wineboot parity (0080), in every prefix.
  - The seed has HKLM `Software\Khronos\Vulkan\Drivers`
    `"C:\windows\system32\winevulkan.json"=dword:0`, marked for top-up.
  - `app/tools/prefix-registry.py` writes it and stops when winevulkan's `DllRegisterServer`
    changes.
  - Wine's builtin `vulkan-1` reads neither the key nor the manifest. Other titles are therefore
    unaffected, and the manifest exists only where the loader's set is linked.

## Consequences

- RDR2's `vkCreateInstance` goes through the Khronos loader. The loader can then load
  `SocialClubVulkanLayer.dll`, x86-64 code under FEX, in front of winevulkan.
- The loader calls the layer through clang's ARM64EC indirect-call check (`__os_arm64x_check_icall`
  with exit thunks). The layer calls back through the loader's entry thunks.
- DXVK loads `winevulkan.dll` directly, so DXVK bypasses the loader.
- Every process in RDR2's session sees the Khronos loader in system32, the launcher's included, as
  on Proton.
- The loader's `DllMain` loads system32's `dxgi.dll`, which is DXVK's in the Vulkan backend. Its
  driver discovery creates a DXGI factory and calls `D3DKMTEnumAdapters2`.
- Not shown by this decision:
  - whether the layer's swapchain and present hooks, and the way its overlay gets its frames, work
    on winevulkan and KosmicKrisp;
  - the cost of its x86-64 code on the render thread.

  The phone run records these.
- The pins add the vulkan stage's inputs. The loader's and the Vulkan-Headers' notices are in the
  app's Licenses, and their sources are in the source bundle.

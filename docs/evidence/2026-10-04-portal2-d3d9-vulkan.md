# Portal 2 milestone 2: Direct3D 9 on DXVK and Vulkan

## Result

[Milestone 2](../PORTAL2-PLAN.md#milestone-2-portal-2s-menu) has started. Portal 2's i386
child now creates its Direct3D 9 device and a 1564x720 Vulkan swap chain through
DXVK's i386 `d3d9.dll` and winevulkan's WoW64 thunks, on KosmicKrisp. It loads its
shader DLLs and compiles shaders on DXVK's six threads. About 22 s after launch, the
engine faults in the emulated `steam_api.dll` and exits with code 100. This happens
before any frame of the game's own reaches the screen. The menu has not been reached,
so there is no frame-time measurement and no go/no-go answer yet. Hollow Knight passes
`first-frame+10` on the same IPA.

IPA: `.work/out/20261004-080340-39af2094/Playport-26.5-39af2094.ipa` (dev, 665,292,621
bytes). SHA256: `39af209467f72945b6d668d486cf4880e2c646050ec16d9d68b970a8bbb0616d`.
`pp build` (79 IPA checks) and `pp test` pass. The new runtime resource is DXVK's
i386 `d3d9.dll`, 7,467,008 bytes uncompressed.

## Why the shader API's factory was null

The [step 4 run](2026-10-04-portal2-inline-translation.md) ended at EIP 0, where
`materialsystem.dll` calls the `ShaderDeviceMgr001` factory. Its `s1-host.log`
(`.work/ui-runs/p2s4-2`) gives the cause:

```text
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\opengl32.dll at 78260000
[unixlib] module 0x70b0270000 (opengl32.dll) WoW64 -> 0x14091e1d8 (stub table)
002c:err:opengl:DllMain Failed to load unixlib, status 0xc00000bb
... "\??\C:\windows\system32\shaderapidx9.dll" failed c0000034 ...
```

i386 `opengl32` has no WoW64 unix table, so its `DllMain` fails. That failure spreads
up the import chain: `wined3d`, then `d3d9`, then `shaderapidx9.dll`. The engine
retries `shaderapidx9.dll` on its search path and finds nothing, so it keeps a null
factory and calls it. The cause is that Wine's Direct3D 9 cannot load. It is not an
emulation fault.

## Route

The route is the plan's: DXVK's `d3d9.dll`, built for i686 from the `dxvk` pin, over
Wine's i386 `vulkan-1`/`winevulkan`, whose WoW64 thunks reach win32u's Vulkan and
KosmicKrisp in the same process. Nothing cheaper is already in the tree. wined3d
would need a GL that iOS does not have, and DXMT has no Direct3D 9 and no i386 build.

- `build/stages/vulkan-pe.sh` has a `dxvk32` stage that builds only DXVK's `d3d9`
  for i686. It is staged as `Runtime/vulkan/i386-windows/d3d9.dll`, and `pp verify`
  checks that it is a PE32 builtin.
- `wine_host.c` links the launch's backend overlay over the `syswow64` farm, the same
  way it does for `system32`. A Vulkan launch therefore gets DXVK's `d3d9.dll`, and a
  later DXMT launch gets Wine's back. Portal 2's default backend is still DXMT. These
  runs set it per game with `--settings 'app-620:{"graphics":"vulkan"}'`.
- **wine-unix 0011**:
  - In winevulkan's unix side, `UlongToPtr` and `PtrToUlong` (about 2,100 uses in
    the generated thunks) convert through the window. The base B comes from the
    calling thread's TEB32. Handles (`HANDLE`, `HWND`, `HINSTANCE`) are converted
    as values.
  - win32u's Vulkan gives a child thread the 32-bit `zero_bits`, so device memory is
    mapped with `VK_EXT_map_memory_placed` inside the window. The mapping is rounded
    to 64 KiB because KosmicKrisp remaps its whole heap-aligned buffer.
  - A mapping fits the guest when it lies in the window. Below 4 GiB is not the test.
  - Host test: `build/wow64/vulkan_ptr_test.c`.
- **wine-pe 0022**: audits the next win32u thunks:
  - `NtUserUnregisterClass`, the first one Portal 2 met. It keeps the guest's
    instance and gives the menu-name block back as a guest pointer.
    `NtUserGetClassInfoEx` was fixed the same way.
  - the hooks, which keep the guest's procedure.
  - raw input.
  - `NtUserChangeDisplaySettings`.
  - the D3DKMT adapter, device and escape thunks, whose nested buffers now convert.
- **wine-pe 0023** (diagnostics): logs the first 16 guest faults with the i386
  registers and the top of the stack.
- **madeira-unix 0071**: data section views (file or pagefile backed; read-only,
  read-write or write-copy) map into the window and unmap back into a window gap.
  DXVK's 32-bit `MemoryFilePool` keeps shader bytecode in such sections. Before this,
  the first `CreatePixelShader` copied its bytecode to NULL (`D3D9Shader`'s
  constructor, from `memcpy` in ucrtbase).
- **madeira-unix 0072**: an i386 caller of `MemoryWineLoadUnixLibByNameWow64` gets
  no audio driver. The null driver's table takes 64-bit parameter blocks, and the
  32-bit ones it was given handed mmdevapi a garbage device string.
- **fex 0020**: the WoW64 module consults the invalidation tracker only for write
  faults. A read of uncommitted memory inside an RWX interval had been claimed as
  self-modifying code and retried until the host ended the whole app.
- **Build fix**: `wine-pe.sh` runs `make depend` in a kept tree. The tree's header
  dependencies dated from configure time, so a patch to `window_audited.h` alone left
  `syswow64`'s `syscall.o` stale. The first wine-pe 0022 IPA (`866cea38`) still
  stopped at the "audited" call.

## Phone runs

Battery 100%. Each run was `pp install --no-build`, then
`pp ui --settings 'app-620:{"graphics":"vulkan"}' --play app-620 --until done --wait 180..240 --shot`.

| Run | IPA | End |
| --- | --- | --- |
| `p2m2-1` | `379d0a8f` (DXVK, wine-unix 0011) | DXVK finds "Apple A19 Pro GPU (KosmicKrisp 26.2.99)"; stops at unaudited `NtUserUnregisterClass` (`c00000bb`) |
| `p2m2-3` | `8227ea77` (+0022, `make depend`) | `D3D9DeviceEx::ResetSwapChain` 1564x720 windowed; guest AV in ucrtbase `memcpy` (exit 100) |
| `p2m2-4` | `4dbe2bb0` (+0023) | the fault is `D3D9Shader::D3D9Shader` (d3d9+0x30e9e), destination NULL: `NtMapViewOfSection` `c00000bb` on a pagefile section |
| `p2m2-5` | `f56170c7` (+0071) | placed maps in the window (`i386 map of 0x400000 bytes: result 0 at 0x704c8c0000`); audio thread loops on a "self-modifying code" read fault, and the host ends the app |
| `p2m2-6` | `39af2094` (+0072, fex 0020) | `Presenter: Actual swapchain properties` B8G8R8A8, FIFO, 3 images; guest AV in `steam_api.dll`+0x25892 reading `0xe94bfe4c`; exit 100 after 22.1 s; 7,997 serviced low faults |

From `p2m2-6`:

```text
002c:err:vulkan:init_physical_device Playport: i386 Vulkan memory maps: placed alignment 16384, host-pointer alignment 0
002c:err:vulkan:win32u_vkMapMemory2KHR Playport: i386 map of 0x1000000 bytes: result 0 at 0x704f570000 (placed 0x704f570000, window 0x7038010000)
info:  Presenter: Actual swapchain properties:
002c:err:wow:call_user_exception_dispatcher Playport: i386 exception c0000005 at eip 7a1f5892 (00000000 e94bfe4c): eax e94bfe40 ...
002c:err:wow:Wow64SystemServiceEx Playport: i386 NtTerminateProcess( ffffffff, 00000064 )
[wow64-window] release peb=0x12763c000 base=0x7038010000 serviced_low_faults=7997
```

The faulting instruction is `mov ebx, [eax+0xc]` in the emulated Steam API (gbe,
`P8-steamapi`). Its object pointer `[esp+0xc]` is garbage. The run's `+5.60 s first
frame` mark is the engine's GDI startup window, not a Direct3D frame. No screenshot
was taken while the game ran, so nothing on screen is claimed.

**Hollow Knight** (`.work/ui-runs/p2m2-6-hk`, same IPA, after the Portal 2 runs):
exit 0 at `first-frame+10`, first frame at 9.35 s, main menu in the screenshot.

## Open

- **The `steam_api.dll` fault**: why gbe's object is garbage. It could be a guest
  pointer that a native conversion damaged, or the 95 refused or 7,997 serviced
  low-address accesses. Those are native writes of NULs to guest addresses
  (`ml1000: subfloor wrote NUL at guest 0x6c2d294`, `strb w9, [x10]`), and their
  caller is not yet known.
- Portal 2's default backend is DXMT, which cannot run an i386 Direct3D 9 title.
  Making Vulkan the default for i386 titles is a product decision that has not been
  taken.
- An i386 child has no audio until the null driver has a WoW64 table.
- The winevulkan debug callbacks hand the guest host pointers truncated to 32 bits.
  DXVK registers none by default.
- `CREATESTRUCT`'s window name reaches wow64win as `0xFFFFFFFF` and is refused (the
  guest gets 0). Its source is not known.
- Data section views cannot be executable or reprotected.

# Portal 2 milestone 2: Direct3D 9 on DXVK and Vulkan

## Result

[Milestone 2](../PORTAL2-PLAN.md#milestone-2-portal-2s-menu) is reached. Portal 2 plays
its intro videos and reaches its main menu about 30 s after Play. In a measured run,
the menu runs at the display's rate:

- capped at 60 FPS: 60.0 FPS, 16.68 ms per frame, 3.55 ms of GPU time;
- with no frame limit: 119.3 FPS (the 120 Hz panel, FIFO), 8.39 ms per frame, 3.49 ms
  of GPU time.

The run serviced 8 low-address faults; the previous build serviced about 307,000 in
156 s. This is the plan's go/no-go point, and the measurement says go: the menu is at
interactive speed on emulated i386 code, DXVK and KosmicKrisp. The cost of gameplay
has not been measured. Hollow Knight passes `first-frame+10` on the same IPA.

Direct3D 9 runs on DXVK's i386 `d3d9.dll` and winevulkan's WoW64 thunks. The last
blocker was an ABI bug in the emulated Steam API: its MinGW build called the game's
callback objects through the wrong vtable slot.

IPA: `.work/out/20261004-084225-db9f2d48/Playport-26.5-db9f2d48.ipa` (dev, 665,362,397
bytes). SHA256: `db9f2d48a792bbf0d84a3b0e28054043ca52ea4e7bb0b3f00c874f76650a6656`.
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
- **gbe 0004**: `CCallbackBase`'s `Run` overloads are declared in MSVC's vtable order
  in a MinGW build. MSVC places overloaded virtuals in reverse order, so the
  emulator's `Run(pvParam)` reached the game's three-argument `Run`. That is an i386
  `__thiscall` that pops 16 bytes where 4 were pushed, and it overwrote the frame of
  `SteamCallResults::runCallResults` (found with a linker map of the same DLL). On
  x86-64 the two overloads had been swapped silently.
- **wine-unix 0011, amended**: a command pool's handle is the guest's client
  pointer, and it now takes the window. `thunk32_vkResetCommandPool` read it through
  the low-fault handler every frame.
- **wine-unix 0012**: in a WoW64 call, the AFD socket ioctls take an i386 child's
  buffer, address and control pointers through the window. At the menu, the Steam
  API's socket polling ran `virtual_check_buffer_for_write` and `sock_ioctl_recv`
  through the low-fault handler about 2,000 times a second, and the kernel's copy to
  the low address failed.
- **wine-pe 0023** also logs the return addresses along the guest's frame-pointer
  chain.

## Phone runs

Battery 100%. Each run was `pp install --no-build`, then
`pp ui --settings 'app-620:{"graphics":"vulkan"}' --play app-620 --until done --wait 180..240 --shot`.

| Run | IPA | End |
| --- | --- | --- |
| `p2m2-1` | `379d0a8f` (DXVK, wine-unix 0011) | DXVK finds "Apple A19 Pro GPU (KosmicKrisp 26.2.99)"; stops at unaudited `NtUserUnregisterClass` (`c00000bb`) |
| `p2m2-3` | `8227ea77` (+0022, `make depend`) | `D3D9DeviceEx::ResetSwapChain` 1564x720 windowed; guest AV in ucrtbase `memcpy` (exit 100) |
| `p2m2-4` | `4dbe2bb0` (+0023) | the fault is `D3D9Shader::D3D9Shader` (d3d9+0x30e9e), destination NULL: `NtMapViewOfSection` `c00000bb` on a pagefile section |
| `p2m2-5` | `f56170c7` (+0071) | placed maps in the window (`i386 map of 0x400000 bytes: result 0 at 0x704c8c0000`); audio thread loops on a "self-modifying code" read fault, and the host ends the app |
| `p2m2-6` | `39af2094` (+0072, fex 0020; first commit) | `Presenter: Actual swapchain properties` B8G8R8A8, FIFO, 3 images; guest AV in `steam_api.dll`+0x25892 reading `0xe94bfe4c`; exit 100 after 22.1 s; 7,997 serviced low faults |

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
frame` mark is the engine's GDI startup window, not a Direct3D frame. This run took
no screenshot while the game was running.

- `p2m2-7` (`dd825df4`, callers in 0023): the same function again
  (`SteamCallResults::runCallResults`, called from `Steam_Client::RunCallbacks`), now
  in `memcpy` from a garbage vector. The screenshots show the Valve intro video at
  14 s and "powered by Source" at 19 s: DXVK's frames are on screen.
- `p2m2-8` (`8dff8b5c`, gbe 0004): no fault in 240 s. The screenshots at 30, 60 and
  120 s show Portal 2's main menu (PLAY SINGLE PLAYER to QUIT over the rendered
  background scene).

**Measured** (`pp perf --title app-620 --settings '{"graphics":"vulkan"…}'`, IPA
`db9f2d48`, battery 94%, thermal nominal throughout):

| Run | Limit | FPS mean (min) | Frame ms | GPU ms | Hitches >25/>50/>100 ms | Serviced low faults |
| --- | --- | --- | --- | --- | --- | --- |
| `.work/perf-runs/p2m2-menu-2`, 120 s | 60 | 60.0 (59.6) | 16.68 | 3.55 | 351/3/1 | 8 |
| `.work/perf-runs/p2m2-menu-nolimit`, 90 s | none | 119.3 (117.0) | 8.39 | 3.49 | — | — |

The windows include the intro videos; the >100 ms hitch is at 15 s, while the menu
loads. The Metal HUD in the screenshots shows the game's 1564x720 layer at 59.98 FPS
with 3.50 ms of GPU time (capped), and 114 FPS with 3.32 ms (uncapped). `pp perf`'s
`cpu%` column reads about 70, mostly on the E cluster. The earlier build (`8dff8b5c`,
`.work/perf-runs/p2m2-menu`) also held 60 FPS, but serviced about 307,000 low faults
in 156 s (socket polling and `vkResetCommandPool`); wine-unix 0011's amendment and
0012 removed them. The 8 that remain are the known native reads of the i386 ntdll
image.

**Hollow Knight** passes `first-frame+10` after the Portal 2 runs on both committed
IPAs: `39af2094` (`.work/ui-runs/p2m2-6-hk`, first frame 9.35 s) and `db9f2d48`
(`.work/ui-runs/p2m2-9-hk`, first frame 8.97 s). Both screenshots show the main menu.

## Hardening after the milestone-1 review

An independent review of milestone 1 found five defects. They are fixed, with no new
Portal 2 feature, in IPA `.work/out/20261004-092839-138cb8c3/Playport-26.5-138cb8c3.ipa`
(SHA256 `138cb8c319dc22e3fa116a2a70e27fe6c0f66cdd4ca0b26e94cbdfce7e4ddbe0`).

- **Window lifetime** (madeira-unix 0073). The owner's release unmapped the window
  while secondary threads still ran on their TEBs and 32-bit stacks in it, and the
  Mach handler's lock-free lookup could use a base after its window was gone or its
  slot reused. Release now only retires the window while a secondary thread is left;
  a thread is reclaimed only after another thread has joined it, and the retired
  window's last reclaimed thread tears it down. The Mach handler counts itself in
  before it reads a window's owner and out after its access, and teardown clears the
  owner and waits for that count to drain before the views go or the slot is reused.
  Teardown also clears the dead threads' TEBs from the thread registry, and
  `NtTerminateThread`'s registry scan reads TEBs with `mach_vm_read`.
- **Exited threads' guest space** (0073). A joined thread's 32-bit stack is freed
  through its window and its TEB pair kept as a spare for the owner's next thread.
- **Pointer messages** (wine-pe 0024). The same-thread `SendMessage` fast path
  returned host (or native temporary) parameters truncated to 32 bits for user32 to
  dispatch; it now returns the guest's own.
- **Class menu names** (wine-pe 0025). Registration and `GCLP_MENUNAME`'s set and get
  convert the client menu name as an integer resource or window pointer, as
  `GetClassInfoEx` and `UnregisterClass` (0022) already did.
- **Native reads of the guest stack.** fex 0019's low-jump log no longer reads
  `[esp]`; wine-pe 0023's fault log reads only inside the thread's committed 32-bit
  stack (`StackLimit` to `StackBase`).
- **Steam API vtables** (gbe 0005). Every interface with overloaded virtuals or a
  virtual destructor (ISteamUserStats' `GetStat`/`SetStat` and four more groups,
  ISteamUGC, ISteamInventory, ISteamGameServerStats, ISteamGameServerItems,
  ISteamHTMLSurface's destructor, two old interfaces) is declared in MSVC's order for
  a MinGW build. `build/steamapi-vtables.py` compares all 259 interface classes'
  MinGW layouts with clang's MSVC layouts for x86-64 and i386 before each steamapi
  build; on the unpatched SDK it lists ISteamUserStats012, the version Portal 2 asks
  for, among the mismatches.

Host tests (`build/wow64/test.py`, compiled from the patches): `threads_test`
(48 real threads exiting while the owner releases, the window torn down once and only
after the last join, no join cycle, spare pairs reused), `fault_test` (lookups racing
teardown, unmap and reuse of the slot by another owner at another base),
`message_params_test`, `class_menu_test` and `stack_span_test`. Without the drain
loop `fault_test` faults; with release tearing down at once, or a thread joining
itself, `threads_test` fails.

On the phone (battery 88%), `.work/ui-runs/p2h-1`
(`pp ui --settings 'app-620:{"graphics":"vulkan"}' --play app-620 --until done --wait 50`):
the 35 s screenshot shows the main menu; no guest exception was logged; the child
created 29 secondary threads, 4 of them reclaimed, and the next 4 took their spare
pairs. The run ended at its `--wait`, so a release with live threads was not
exercised on the phone (the scripted pad does not reach an i386 title, so QUIT could
not be chosen). Hollow Knight passes `first-frame+10` on the same IPA
(`.work/ui-runs/p2h-hk`, first frame 9.67 s, main menu).

## Open

- Portal 2's default backend is DXMT, which cannot run an i386 Direct3D 9 title;
  these runs set Vulkan per game. Making Vulkan the default for i386 titles is a
  product decision that has not been taken.
- An i386 child has no audio until the null driver has a WoW64 table.
- A window whose owner exits from a secondary thread, or whose thread never runs
  `pthread_exit_wrapper`, is kept until the app ends. The last thread of a retired
  window is joined by the next reaper (any exiting thread, thread creation or window
  reservation), so a retired window can outlive its process until then.
- The scripted pad does not reach an i386 title.
- The rest of ws2_32's WoW64 unix calls (`getaddrinfo`, `gethostbyname`) still take
  raw guest pointers.
- The winevulkan debug callbacks hand the guest host pointers truncated to 32 bits.
  DXVK registers none by default.
- Native code reads guest `0x370` (a NULL structure) and is refused (`[subfloor] ...
  REFUSED read ... pc` in `virtual_*`). The caller is not known.
- `CREATESTRUCT`'s window name reaches wow64win as `0xFFFFFFFF` and is refused (the
  guest gets 0). Its source is not known.
- Data section views cannot be executable or reprotected.
- No gameplay, input or save has been tried (milestone 3).

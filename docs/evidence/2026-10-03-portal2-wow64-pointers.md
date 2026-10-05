# Portal 2 milestone 1, step 2: wow64's pointer conversions

## Result

**Milestone 1's markers are all reached.** wow64.dll and wow64win.dll
convert the guest's pointers through the window base. With the follow-ups
below (DC attributes, the apiset map, KUSER_SHARED_DATA, i386 unix
libraries, secondary threads, `NtUserMessageCall`), Portal 2's launcher
loads `bin\engine.dll` at guest `0x79640000`, and the engine's
initialization loads its own modules: `inputsystem`, `vphysics`,
`materialsystem`, `datacache`, `studiorender`, `vscript`, `vgui2`,
`shaderapidx9` with Wine's i386 `d3d9`, `wined3d` and `opengl32`, and
`localize` (64 i386 images). The main thread then calls a null pointer
in FEX's generated code (`blr x4`, `x4=0`) and the child hangs until the
UI run ends the app.

Milestone markers (`.work/ui-runs/p2th-4` and, on the final IPA, `p2th-5`):

- `portal2.exe` at guest `0x400000`;
- the i386 `kernel32` (`0x7bed0000`) and `ntdll` (`0x7bf40000`) loaded;
- the entry point executed (`bin\launcher.dll` is loaded by its code);
- `bin\engine.dll` loaded at `0x79640000`, and its modules after it;
- serviced low faults logged: 18,780,160 by the null call.

The latest IPA and runs are under "Thread and message follow-up runs". The earlier IPAs of
this step, whose child stopped at a DC attribute read (`c0000005`):

IPA: `.work/out/20261003-220140-70d803f5/Playport-26.5-70d803f5.ipa` (dev).
SHA256: `70d803f5024f42a8fd7a1b33456de32374d7256ba37f174e53338d9d3dbce2df`.
Source: the first commit of this step (`d54b41a`, the wow64.dll part below)
plus the wow64win/GDI follow-up. `pp build` passed (78 IPA checks), and so
did `pp test`. The commit's own build
(`.work/out/20261003-221200-cf03bbdd/`) differs only in the patches' commit
messages. Its `artifacts.tsv` is identical to the tested IPA's.

The first commit stopped at the first win32u call
(`NtUserInitializeClientPfnArrays`). Its IPA is
`.work/out/20261003-210213-1da4bde0/Playport-26.5-1da4bde0.ipa`, SHA256
`1da4bde0e5b898df266895559154527311f167ad28cc2475d058cbccb8c1d637`. Hollow Knight
passed `first-frame+10` on it (8.37 s, menu).

## Changes

- **wine-pe 0016** (it replaces 0014, whose stop it removes):
  - `dlls/wow64/wow64_window.h` holds the arithmetic and includes no Wine
    header.
    - Guest to host keeps NULL as NULL. A nonzero low address lands in the
      window's guard.
    - Host to guest accepts only NULL, or a pointer above the base and inside
      the window. Anything else is rejected without truncation.
    - Base 0 means no window: the identity below 4 GiB, as in Wine elsewhere.
  - `process_init` takes the base from the paired TEB32 and PEB32 (host
    address minus guest address, which must agree), the way FEX's module
    does. A pair that names no valid window ends the process.
  - `wow64_to_host` and `wow64_to_guest` (in `wow64_private.h`) carry every
    pointer conversion. A rejected host pointer is logged with its caller,
    and the guest gets 0.
  - Values that the native side keeps for the guest stay raw guest values:
    - thread start and parameter;
    - APC function and context;
    - I/O completion keys and ALPC contexts;
    - exception and code addresses;
    - the CPU module's bridge addresses (FEX returns guest ones);
    - `NtContinueEx`'s small "alertable" flag.
  - A guest win32u call ended the process; 0018 replaces that stop with
    wow64win's audit. The log also shows failed guest calls (the first 256),
    the guest's `NtTerminateProcess`, and each image the guest maps, by the
    name its loader puts in TEB32.
- **wine-pe 0017**: the i386 locale setup skips the PEB64 copy when TEB64's
  `Peb` is above 4 GiB, which it is here. Without this it would truncate the
  pointer and write there.
- **madeira-unix 0063**:
  - `get_wow_user_space_limit` used the 64-bit session's
    `user_space_wow_limit` (0) for an i386 child, which reported
    `HighestUserAddress` `0xffffffffffffffff`. wow64's range check then
    overflowed and refused the first allocation (`c0000018`). The child now
    gets its window's limit: 2 GiB, or 4 GiB if the image is large-address
    aware.
  - The NLS sections take the same guest constraint.
  - The window maps a read-only view of an ordinary file section: placed
    like anonymous VM, the file mapped over a claimed view, and the server
    registration, rolled back to a gap on failure.
  - Image views may be mapped `ViewShare`, which is how the guest loader maps
    DLLs.
- **`wine_host.c`**: links `drive_c/windows/syswow64` to the bundle's i386
  set, beside `sysarm64`. wow64 redirects the guest's `system32` there.
- **Host test**: `build/wow64/guest_ptr_test.c` (in `build/wow64/test.py`,
  part of `pp test`) applies `wow64_window.h` from patch 0016 and compiles it
  with UBSan. It checks:
  - round trips at the window edges and 200,000 random addresses;
  - rejection of NULL+1, below the base, the base itself, the end of the
    window and beyond, and another window's pointers, with the output left
    untouched;
  - base 0 (no window);
  - the TEB32/PEB32 base pair, including mismatched, low and misaligned
    pairs.

- **wine-pe 0018** (wow64win.dll):
  - It takes the same base from the TEB32/PEB32 pair and has the same
    helpers. Two more cover names and parameters that are either a pointer
    or a small integer: `wow64_intres_to_host` and `wow64_intres_to_guest`
    (atoms, resource ids, `SystemParametersInfo` values).
  - Converted: `get_ptr`, `put_addr` and the string, object-attribute and
    security helpers, where a string buffer may be an atom.
  - Converted, the `NtUserCall*` codes that take pointers:
    - `CallOneParam`: primary monitor rect, keyboard state, D3DKMT name,
      desk pattern;
    - `CallTwoParam`: menu and monitor info, IME rect, monitor from rect,
      virtual screen, adjust window rect;
    - `CallHwndParam`: client/screen point, child rect, window info, window
      thread, present rect.
  - Converted: class registration and lookup names, cursor and icon data
    and names, `bmBits` and the packed names in callbacks.
  - Left as raw guest values: procedures, instances, `lpCreateParams`,
    resource handles and the DIB brush's client pointer. Two handles that
    were read with `get_ptr` now use `get_handle`.
  - Only audited thunks run in a windowed process
    (`dlls/wow64win/window_audited.h`, 398 of the win32u calls). Those are
    every thunk whose arguments are handles, integers or plain-data pointers
    (found by script, then read), plus the ones converted above. The rest,
    such as `NtUserMessageCall`, the message loop and D3DKMT, stop the
    process and name the call. Callbacks are all converted.
  - The guest's last 32 system calls and callbacks are logged at its
    `NtTerminateProcess`.
- **wine-pe 0017** (extended): i386 gdi32 takes the GDI shared handle table
  from its own PEB32 when the native PEB is above 4 GiB.
- **madeira-unix 0064**: win32u's GDI shared handle table is allocated once
  per Mach process, and a child's PEB copies the session's. At window
  reservation, the table is aliased read-only into the window, at guest
  `0x7fc80000` (`vm_remap`, `0x180000` bytes). PEB32 gets that guest
  address.

### DC attributes, apisets and unix libraries (follow-up)

- **madeira-unix 0065, wine-unix 0009, wine-pe 0019**: one DC_ATTR arena.
  win32u keeps DC attributes in process-global buckets, and its DC cache
  (`dce.c`) hands a cached DC to whichever process asks next. Buckets per
  child would give a child a session DC it cannot reach, and leave the
  session a dead child's freed attributes. So ntdll makes one 1 MiB arena
  for the life of the Mach process (by the first window or the first bucket),
  with its host base and size in its first 64 KiB. win32u takes every
  bucket from the rest (15 buckets of about 300 DC_ATTRs; Hollow Knight and
  Portal 2 each use one), then falls back to ordinary buckets and logs once
  that i386 children cannot use them. Each window aliases the arena
  read-write at guest `0x7fa00000`, claimed at reservation like the other
  bootstrap views, and PEB32's `GdiDCAttributeList` names it. UserPointer
  stays the host pointer, so the session's path changes only in where its
  buckets live. i386 gdi32 maps a UserPointer above 4 GiB into the alias
  through the arena header; one outside the arena gives NULL (an invalid
  handle for the guest, not a truncated address). Teardown removes the
  alias only. The host low half of the address (the first plan) needed a
  host address with chosen low 32 bits, which the 16 GiB furniture band
  cannot promise.
- **madeira-unix 0066**: PEB32's `ApiSetMap` was 0, so the i386 loader
  probed every directory for `api-ms-win-crt-*` as files and failed the
  imports. The session's apiset map is aliased read-only into the window
  (one helper with the GDI table now). KUSER_SHARED_DATA is aliased
  read-only at its guest address `0x7ffe0000` first; a top-down alias had
  landed there.
- **fex 0017**: FEX left guest `0x7ffe0000` and up untranslated, so those
  accesses faulted low and met Wine's x86-64 KUSER_SHARED_DATA redirect,
  which rewrites every host register holding `0x7ffexxxx`. The guest's
  `user_shared_data` register became the session page's address truncated
  to `0x38000000`, and `RtlGetEnabledExtendedFeatures` faulted. The whole
  window now translates inline.
- **madeira-unix 0068**: the window query router refused
  `MemoryWineLoadUnixLibWow64`, so ws2_32's DllMain failed and with it
  `bin\launcher.dll` ("DLL initialization failed"). The query now takes
  NtQueryVirtualMemory's own path, which names the module from its export
  directory (read as PE32), and returns the library's WoW64 table (ws2_32,
  secur32, crypt32, dwrite, winevulkan) or the stub table (dnsapi here),
  never the 64-bit one.
- **madeira-unix 0067, wine-unix 0010** (diagnostics): the guest's debug
  output was lost twice over. PEB32 had no debug channel table (default
  flags 0), and `wow64_wine_dbg_write` wrote from the guest address. The
  owner's table is copied to PEB32 + 0x1000, and the write adds the
  window base. i386 `err`/`fixme` lines now reach `s1-host.log`; that is
  how the launcher's message box text below was found.
- **wine-pe 0020** (diagnostics): a failed guest file open or attribute
  query logs the file name; a failed `NtUserCreateWindowEx` logs its class,
  name, styles and last error.
- **Host test**: `build/wow64/dc_attr_test.c` (in `build/wow64/test.py`)
  compiles the arena creation, win32u's entry and the window alias from
  0065, and gdi32's mapping from 0019, with real 4 GiB windows and a mock
  view tree (vm_remap stands in as Linux `mremap` of a shared mapping). It
  checks one arena for every caller, the guest range below the TEB pair,
  header and data coherence between the arena and two windows, gdi32's
  bounds, the claimed range refusing a second claim, a failed remap rolled
  back to a protected gap, and a child's teardown leaving the arena and the
  other window intact.

### Threads, messages and the engine (second follow-up)

- **madeira-unix 0069**: `virtual_alloc_teb` refused every thread a
  windowed owner created, and the launcher waited forever for its first
  worker. A new thread's TEB pair now goes in the owner's window, top-down
  below KUSER_SHARED_DATA, with the initial pair's layout; its 32-bit
  stack already came from the window. Thread data is freed later by
  another thread, so the window keeps a table of these threads: freeing
  one frees only its native stack while the window holds its TEB, and the
  window's teardown, which frees the pairs and 32-bit stacks, unlinks
  them from `teb_list` so nothing reads their TEBs again.
- **wine-pe 0021**: `NtUserMessageCall` (first reached as DefWindowProc's
  `WM_GETMINMAXINFO`) converts a pointer message's lparam, by win32u's own
  `message_pointer_flags`, and the wparam of `EM_GETSEL`, `CB_GETEDITSEL`
  and `SBM_GETRANGE`, for the calls where win32u reads them (the window
  procedures, DefWindowProc, the send variants). Calls that hand the
  parameters back to the guest keep them. `WM_NCCALCSIZE`, `WM_MDICREATE`
  and `WM_COPYDATA` convert their nested pointers. The message loop's
  `GetMessage`, `PeekMessage`, `TranslateMessage`, `DispatchMessage`,
  `PostMessage` and `EndPaint` are audited as they are (guest values,
  handles and plain data only); 405 thunks are audited now.
- **madeira-unix 0070**: engine.dll's initialization faulted on
  `ld1 {v16.d}[0], [x20]`, a lane load FEX emits for i386 x87/SSE stack
  slots, which the low-fault emulator did not know. It now emulates the
  LD1/ST1 single-structure lanes (B/H/S/D, other lanes kept).
  `build/wow64/simd_lane_test.c` checks the decoder from the patch against
  encodings from `llvm-mc`.
- Build note: wine-pe's Makefile does not see `window_audited.h` as a
  dependency of `syscall.c`, so the first build of 0021 kept the old audit
  table; `syscall.c` was touched to rebuild it. A clean build is not
  affected.

### Conversion list (wine-pe 0016)

Grep on the patched tree: `rg -n 'get_ptr|ULongToPtr|UlongToPtr|PtrToUlong|wow64_to_(host|guest)' dlls/wow64`.

| File | Converted | Left as raw guest or native values, audited |
| --- | --- | --- |
| `wow64_private.h` | `get_ptr`; `addr_32to64`; `put_addr`; the string, object-attribute, security-descriptor, ALPC QoS/view and token helpers | APC parameter packing; ALPC port and message contexts |
| `syscall.c` | exception record chain; the exception, APC and callback stack frames; initial thread context; `KiRaiseUserExceptionDispatcher`'s address; `NtContinueEx`'s argument | exception and code addresses; bridge addresses from the CPU module |
| `virtual.c` | allocate/free/protect/map/query addresses and results (queries check the guest address against the limit); range lists; address requirements; write-watch results; the image name pointer | `NtWow64*64` native addresses |
| `process.c` | process parameters; attribute values (image name, handle list, affinity, client id, image info, TEB); PEB32 for the current process (TEB32's); TEB32 of a thread; image-name, thread-name and stack-base results | thread start and parameter; APC values; another process's `PebBaseAddress` |
| `sync.c` | strings written into the guest's buffers; image entry and section base (`wow64_image_addr_to_guest`: header values below 4 GiB pass, host mappings convert) | completion keys; debug events of other processes |
| `security.c` | SID, ACL and object-type pointers both ways | none |
| `system.c` | process-name buffers | other processes' thread addresses; kernel object pointers; user limits |
| `file.c`, `registry.c` | through `get_ptr` and the helpers only | APC values |

The ARM32 guest paths in `syscall.c` are converted the same way but never
run here. Not converted:

- `wow64win.dll` beyond its audited thunks (0018);
- the unix side's wow64 unix calls (`wow64_wine_dbg_write` and others, so
  the i386 guest's own debug output is lost);
- operations on another process's memory, which use this process's window.

## Phone runs

### First commit (wow64.dll only)

All in one lock session (75% battery):

```sh
./pp install --no-build
./pp ui --play app-620 --until done --wait 90 --shot --out .work/ui-runs/p2ptr-4
./pp ui --play app-367520 --until first-frame+10 --shot --out .work/ui-runs/p2ptr-4-hk
```

**Portal 2** (`.work/ui-runs/p2ptr-4`, `pull/s1-host.log`):

```text
err:wow:init_window_base Playport: guest window base 0x7038010000 (teb32 00000070B7E12000 guest 7fe02000, peb32 00000070B7F10000 guest 7ff00000)
[wow64-section] host=0x7038060000 guest=0x50000 bytes=0xc3000 file=1 offset=0 read_only=1
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\kernel32.dll at 7bed0000
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\kernelbase.dll at 7bc20000
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\USER32.dll at 7ba60000
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\win32u.dll at 7b760000
err:wow:Wow64SystemServiceEx Playport: i386 win32u system call 147a (args 0000007038C6FA24: 7bfba4e4 7bfba56c 7bfba5f4 7ba60000); wow64win does not convert through the guest window, stopping
[wow64-window] release peb=0x1293dc000 base=0x7038010000 serviced_low_faults=259688
```

- `portal2.exe` is at guest `0x400000` and the i386 ntdll at `0x7bf40000`
  (step 2's earlier mapping). Nine more i386 DLLs map in the window: the
  four above, plus `gdi32` `0x7b9d0000`, `advapi32` `0x7b980000`, `sechost`
  `0x7b950000`, `ucrtbase` `0x7b860000` and `msvcrt` `0x7b7b0000`.
  An unnamed image also maps at `0x10000000`, twice.
- The NLS views (`locale.nls`, case map, code pages 1252, 437 and 20127, and
  the normalization tables) map read-only at guest addresses
  `0x10000`–`0x1f0000`.
- Of the 25 failed guest calls:
  - 22 are expected `c0000034` misses (registry values, `C:\Games\Portal 2\kernel32.dll`, `\KnownDlls32`);
  - `NtQuerySystemInformation` class `0xf00d` returns `c0000003`;
  - `NtQueryVolumeInformationFile` on handle 0 (a missing standard handle)
    returns `c0000008`, twice.
- 259,688 low accesses are serviced (1,072 before). That is FEX's
  untranslated stack and string accesses, now over the whole loader run.
  One `KUSER_SHARED_DATA` read (`LDAPUR`, guest `0x7ffe0320`) is logged as
  an unhandled encoding by the sub-floor emulator. The run continues past
  it.
- The child ends with `c00000bb` 3 s after the game starts. The window is
  released and the app keeps running. There is no crash report.

**Hollow Knight** (`.work/ui-runs/p2ptr-4-hk`): exit 0 at `first-frame+10`.
The first frame came at 8.37 s, and the screenshot shows the main menu.

### wow64win follow-up run

Same lock rules (62% battery). `.work/ui-runs/p2win-10` is Portal 2 and
`.work/ui-runs/p2win-10-hk` is Hollow Knight, after `pp install`:

```text
[wow64-window] GDI shared table 0x7021200000 aliased read-only at guest 0x7fc80000 (0x180000 bytes)
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\Games\Portal 2\bin\launcher.dll at 7b6e0000
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\Games\Portal 2\bin\steam_api.dll at 7a1d0000
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\Games\Portal 2\bin\tier0.dll at 79e60000
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\Games\Portal 2\bin\vstdlib.dll at 79e10000
[mach_exc] UNHANDLED #1 pc=0x124def150 addr=0x70593900c4 ...
err:wow:Wow64SystemServiceEx Playport: i386 NtTerminateProcess( ffffffff, c0000005 )
err:wow:log_recent_calls Playport: recent i386 call 13eb -> 0301003a      (NtUserGetDC)
err:wow:log_recent_calls Playport: recent i386 call 15cb -> 00000001      (NtUserSystemParametersInfo)
err:wow:log_recent_calls Playport: recent i386 call 1233 -> 040a0043      (NtGdiHfontCreate)
[wow64-window] release peb=0x1276d0000 base=0x7038010000 serviced_low_faults=742010
```

- 36 i386 images load. After the system DLLs, `imm32`, `bin\launcher.dll`,
  then `shell32`, `ole32`, `ws2_32` and others for the launcher.
  `bin\steam_api.dll` (gbe), `bin\tier0.dll`, `bin\vstdlib.dll` and
  `uxtheme` load too. `launcher.dll` is loaded by `portal2.exe`'s own code
  after its CRT startup, so the entry point ran.
- The faulting read is at guest `0x213800c4`. That is the low half of win32u's
  DC-attribute bucket `0x7021380000` (allocated by the session, right after
  the GDI table) plus a `DC_ATTR` offset. gdi32 reached it through the
  `UserPointer` of the HDC from `NtUserGetDC`. FEX delivers the access
  violation to the guest, its handler continues, the access faults again,
  and the guest ends.
- Failed guest calls, 232 in all:
  - 214 are DLL search probes (`NtOpenFile`, `c0000034` or `c000003a`);
  - registry misses;
  - the two standard-handle queries and the class `0xf00d` query from
    before;
  - one `NtFreeVirtualMemory` with `c000000d` (not investigated).
- No font is found (`select_font can't find a single appropriate font`).
  The Wine prefix has no fonts for i386 GDI yet.
- 742,010 serviced low faults by the end.

**Hollow Knight** (`.work/ui-runs/p2win-10-hk`): exit 0 at `first-frame+10`.
The first frame came at 9.15 s, and the screenshot shows the main menu.

### Follow-up runs

IPA: `.work/out/20261003-230508-8fad5988/Playport-26.5-8fad5988.ipa` (dev),
SHA256 `8fad5988747950f85bb8f805383c022dcfd7ce0f28fece271ce741400ad17a47`.
`pp build` passed (78 IPA checks), and so did `pp test`. Each run below
is `pp install` then `pp ui --play app-620 --until done --wait 120 --shot`
(62% to 54% battery); each fix was found from the run before it.

- `p2dc-1` (arena only): no `c0000005`. gdi32 uses the HDC, and the
  launcher's `NtUserCreateWindowEx` of a `#32770` dialog fails; the
  child exits 0.
- `p2dc-2` (0020): the failed calls name `api-ms-win-crt-*` probes in every
  search directory, and the dialog fails with error 6.
- `p2dc-5` (0066, 0067, 0010): no apiset probes. The guest's own log
  says `[msgbox] caption L"Launcher Error" text L"Failed to load the
  launcher DLL:\n\nDLL initialization failed."`, after ws2_32's unix
  library query failed `c00000bb`.
- `p2dc-7` (0068): the same box with "No access to memory location", from
  a fault at guest `0x380003dc` in `RtlGetEnabledExtendedFeatures`.
- `p2dc-8` (fex 0017), `.work/ui-runs/p2dc-8`:

```text
[wow64-window] KUSER_SHARED_DATA 0x7038000000 aliased read-only at guest 0x7ffe0000 (0x4000 bytes)
[wow64-window] DC_ATTR arena 0x7021380000 aliased at guest 0x7fa00000 (0x100000 bytes)
[wow64-window] GDI shared table 0x7021200000 aliased read-only at guest 0x7fc80000 (0x180000 bytes)
[wow64-window] apiset map 0x7020820000 aliased read-only at guest 0x7ffc0000 (0x20000 bytes)
[unixlib] module 0x70b2ae0000 (ws2_32.dll) WoW64 -> 0x1045dac28
[unixlib] module 0x70b2a70000 (dnsapi.dll) WoW64 -> 0x140b1c1d8 (stub table)
... i386 system call 003d ... failed c000003a [54] "\??\C:\Games\Portal 2\portal2_sixense\gameinfo.txt"
... i386 system call 0033 ... failed c0000034 [55] "\??\C:\Games\Portal 2\bin\GameOverlayRenderer.dll"
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\Games\Portal 2\bin\filesystem_stdio.dll at 79da0000
err:wow:wow64_guest_rejected host pointer 0000000000002000 (from 0000000105C7B314) is outside the guest window at 0x7038010000, giving the guest 0
err:wow:Wow64SystemServiceEx Playport: i386 system call 008b (args 00c5e42c 001fffff 00c5e40c ffffffff) failed c00000bb [60]
```

  The launcher no longer shows its error box. Call `008b` is
  `NtCreateThreadEx`: a second WoW64 thread is refused. The child then
  waits with no thread running until the UI run's 300 s limit ends the app
  (no window release line). By then 2,490,368 low accesses were serviced,
  most of them stack accesses by FEX's untranslated paths. One DC_ATTR
  bucket was used.

**Hollow Knight** (`.work/ui-runs/p2dc-8-hk`, same IPA, after fex 0017):
exit 0 at `first-frame+10`. The first frame came at 8.26 s, and the
screenshot shows the main menu. It used one DC_ATTR bucket from the arena.

### Thread and message follow-up runs

IPA: `.work/out/20261003-235904-41216826/Playport-26.5-41216826.ipa` (dev),
SHA256 `41216826d16c58b410a7253ee3c0dac10694807f5278947933d72f12f7794595`,
built from this commit's series. `pp build` passed (78 IPA checks), and so
did `pp test`. Battery 49% to 46%. The runs below up to `p2th-4` used the
same artifacts (identical `artifacts.tsv`) packaged as
`5c61a152ec9385cf4a9cbf657eb2c83749d8b13027106550a6acbd054a9229a2`; that
series still carried a stray hunk in madeira-unix 0068 (the run tree's
`wine` link) which no build output depends on, removed before this commit.

- `p2th-1` (0069): six secondary threads get TEB pairs; the child stops
  at the unaudited `NtUserMessageCall` (`14b5`, `WM_GETMINMAXINFO`). The
  window's release unlinks the six threads, and the app keeps running.
- `p2th-3` (0021): `bin\engine.dll` maps, and its initialization faults
  on the unhandled `ld1` lane encoding at the guest stack; the launcher
  retries twice, then the child exits with `c0000005`. 46 images.
- `p2th-4` (0070), `.work/ui-runs/p2th-4`:

```text
[wow64-pair] thread tid=0030 owner=0x12923c000 native=0x70b7fc0000 guest=0x7ffb0000 teb32_guest=0x7ffb2000 status=0
err:wow:wow64_NtMapViewOfSection Playport: i386 image c:\games\portal 2\bin\engine.dll at 79640000
err:wow:wow64_NtMapViewOfSection Playport: i386 image c:\games\portal 2\bin\materialsystem.dll at 792c0000
err:wow:wow64_NtMapViewOfSection Playport: i386 image c:\games\portal 2\bin\shaderapidx9.dll at 786d0000
err:wow:wow64_NtMapViewOfSection Playport: i386 image C:\windows\system32\wined3d.dll at 783a0000
[unixlib] module 0x70b0270000 (opengl32.dll) WoW64 -> 0x144ea61d8 (stub table)
err:wow:wow64_NtMapViewOfSection Playport: i386 image c:\games\portal 2\bin\localize.dll at 787b0000
[mach_exc] UNHANDLED #1 pc=0x0 addr=0x0 x18=0x70b7e10000 type=1 lr=0x127bd41e4 ...
[mach_exc] caller_insn @lr-4=0x0x127bd41e0: 0xd63f0080
```

  engine.dll loads once and its DllMain completes; the engine then loads
  its modules. The fault is a host-level null call (`blr x4`, `x4=0`)
  from code FEX generated, with guest `eip` 0 and `launcher.dll` frames on
  FEX's call-return stack; the guest gets no exception and the child hangs
  (no `NtTerminateProcess`), until the UI run's 300 s limit ends the app.
  i386 `opengl32` gets the stub table (no GL), so wined3d cannot work yet;
  that is milestone 2's D3D9 path.
- `p2th-5`, on the final IPA: the same (`engine.dll` at `0x79640000`, 64
  i386 images, the null call after `localize.dll`, 18,780,160 serviced low
  faults, no exit until the UI run's limit).

**Hollow Knight** on the final IPA: `.work/ui-runs/p2th-5-hk2`, exit 0 at
`first-frame+10`, first frame at 8.76 s, the screenshot shows the main
menu. (`p2th-5-hk`, run right after Portal 2 in the same lock session, also
passed, first frame at 10.11 s, with a black screenshot; `p2th-4-hk` on the
earlier package passed at 8.75 s with the menu.)

## Open

- **The null call after `localize.dll`** (next to diagnose): FEX's
  generated code calls a null helper pointer (`blr x4`) on the main
  thread, and the guest gets no exception. The child then hangs instead of
  exiting.
- **Serviced low faults**: 18.8 million by then. Step 4's inline
  translation must bring that down, and it removes the low-fault
  emulator's encoding gaps on the stack path with it.
- **wow64win.dll**: the thunks not audited yet stop the process (D3DKMT,
  raw input, hooks and others).
- **Threads**: a secondary thread's TEB pair and 32-bit stack stay in the
  window until the process exits, so heavy thread churn can fill the 2 GiB
  guest. An exit from a secondary thread keeps the window (only the
  initial thread restores its TEB), and a thread still running when the
  window is released would fault.
- The unix libraries' WoW64 thunks pass guest pointers inside their
  parameter blocks; a system call given one fails with `EFAULT`.
  Libraries without a WoW64 table (dnsapi, nsi, opengl32, audio,
  gstreamer) get the stub table.
- No fonts for i386 GDI (`select_font can't find a single appropriate font`).
- The guest's metafile DCs would write UserPointer into the read-only GDI
  table alias.
- File views in the window cannot be unmapped, protected or queried.
  Writable and anonymous sections are refused.
- Values that win32u returns from session memory (for example
  `GetClassInfoEx`'s menu name) are still truncated, as in Wine's own WoW64.

# Portal 2 milestone 1, step 2: wow64's pointer conversions

## Result

wow64.dll and the audited part of wow64win.dll now convert the guest's
pointers through the window base. On the phone, Portal 2's i386 child gets
through its i386 loader and user32's initialization and runs `portal2.exe`'s
entry point: the launcher loads `bin\launcher.dll`, which loads `steam_api`,
`tier0` and `vstdlib` among 36 i386 images. The child then ends with a guest
access violation (`c0000005`). The cause is gdi32 reading a DC's
attributes (`DC_ATTR`) through the handle table's `UserPointer`, which is a
truncated session address (`0x7021380000`). win32u keeps DC attributes in
native memory, outside the window. That is the next boundary.

Milestone markers:

- reached: `portal2.exe` at `0x400000`, the i386 `kernel32` and `ntdll`
  loaded, and the entry point executed;
- not reached: `bin/engine.dll`.

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

## Open

- **DC attributes** (next): win32u allocates `DC_ATTR` buckets once per
  Mach process and publishes them through `UserPointer`. A windowed child
  needs its own buckets in its window and the guest address in
  `UserPointer`, with the buckets dropped when the child exits.
- **wow64win.dll**: the thunks not audited yet stop the process. These
  include `NtUserMessageCall` (message parameters, by message), the message
  loop calls and D3DKMT.
- The unix side's wow64 unix calls (`ntdll`'s `wine_dbg_write`, server
  calls) convert nothing yet, so the i386 guest's own debug output is lost.
- File views in the window cannot be unmapped, protected or queried.
  Writable and anonymous sections are refused.
- Serviced low faults reach 742,010 by the launcher. Step 4's inline
  translation must bring that down.
- Values that win32u returns from session memory (for example
  `GetClassInfoEx`'s menu name) are still truncated, as they are in Wine's
  own WoW64.

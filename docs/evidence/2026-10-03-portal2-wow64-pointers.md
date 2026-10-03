# Portal 2 milestone 1, step 2: wow64's pointer conversions

## Result

wow64.dll now converts the guest's pointers through the window base, so the
i386 guest's system calls work. On the phone, Portal 2's i386 child gets past
its first system call. The i386 ntdll's loader then loads the i386 `kernel32`,
`kernelbase`, `user32`, `gdi32`, `advapi32`, `sechost`, `ucrtbase`, `msvcrt`
and `win32u`, and maps its NLS tables into the window. It stops at its first
win32u system call, `NtUserInitializeClientPfnArrays` (`0x147a`, user32's
init), because wow64win.dll does not convert pointers yet. That is the new
boundary (`c00000bb`).

Done, out of the milestone's markers: `portal2.exe` mapped at `0x400000`, and
the i386 `kernel32` and `ntdll` loaded. Not reached yet: the entry point and
`bin/engine.dll`.

IPA: `.work/out/20261003-210213-1da4bde0/Playport-26.5-1da4bde0.ipa` (dev).
SHA256: `1da4bde0e5b898df266895559154527311f167ad28cc2475d058cbccb8c1d637`.
Source: `2d23a35` plus the changes below. `pp build` passed (78 IPA checks),
and so did `pp test`.

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
  - A guest win32u call ends the process. The log also shows failed guest
    calls (the first 256), the guest's `NtTerminateProcess`, and each image
    the guest maps, by the name its loader puts in TEB32.
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

- `wow64win.dll` (the boundary);
- the unix side's wow64 unix calls (`wow64_wine_dbg_write` and others, so
  the i386 guest's own debug output is lost);
- operations on another process's memory, which use this process's window.

## Phone runs

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

## Open

- **wow64win.dll** is the next boundary:
  - about 365 `get_ptr` uses and about 190 direct conversions;
  - user32's callbacks (the `KiUserCallbackDispatcher` frames are already
    converted, but their parameters are not);
  - window procedures and message parameters.
- The unix side's wow64 unix calls (`ntdll`'s `wine_dbg_write`, server
  calls) convert nothing yet.
- File views in the window cannot be unmapped, protected or queried.
  Writable and anonymous sections are refused.
- Serviced low faults are 259,688 for the loader alone. Step 4's inline
  translation must bring that down.

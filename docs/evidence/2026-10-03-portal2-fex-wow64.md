# Portal 2 milestone 1, step 3: FEX's WoW64 module on iOS

## Result

[Step 3](../PORTAL2-PLAN.md#step-3-fexs-wow64-module-on-ios-patchesfex)'s check
passes on the phone: Portal 2's i386 child loads FEX's WoW64 module
(`xtajit.dll`), and FEX compiles and runs i386 code from the i386 ntdll's
`LdrInitializeThunk` (guest `0x7bf8f420`) through several blocks to the
guest's first system call, `NtAllocateVirtualMemory` (`0x0018`), where
wine-pe 0014 now stops the process (`c00000bb`). This answers the plan's
questions 1 and 2: WoW64 runs beside the ARM64EC session in the one Mach
process, and FEX's WoW64 module runs on iOS with the JIT pool. Nothing past
the first system call runs: wow64's thunks do not convert pointers yet.

IPA: `.work/out/20261003-202644-7a0e0263/Playport-26.5-7a0e0263.ipa` (dev).
SHA256: `7a0e0263bbeaa3e82ae653996c215207d8e6e428145d9d32e33bab6d9d3d90c6`.
Source: `8ca05d6` plus the patches below; `pp build` (78 IPA checks) and
`pp test` passed.

## Changes

- **fex 0015** (rewritten): the iOS CRT stub is for ARM64EC only; the WoW64
  module links FEX's own CRT as upstream does (`-nostdlib`), so it imports only
  `ntdll.dll` and `wow64.dll`. The earlier mingw CRT link imported the UCRT,
  which loaded the native `kernelbase.dll` before its NLS tables existed (the
  step-2 crash). `pp verify` now checks the import list.
- **fex 0016**: the WoW64 module builds with `FEX_IOS_HOST` (`fex.sh`):
  - the JIT pool's write offset from `WINE_IOS_JIT_RW/RX`, as the ARM64EC
    module reads it;
  - the ARM64EC placement: host structures in FEX's host band, code buffers
    allocated as `EC_CODE` (which Wine's iOS allocator puts in the pool), and
    FEX's `VirtualAlloc2` keeps a caller's own address requirements instead of
    adding the WoW64 default beside them;
  - the guest window: base `B` from the paired TEB32 (host address minus its
    guest self pointer), checked against PEB32. The decoder reads guest code
    from `B + EIP`. Every block translates memory operands below
    `KUSER_SHARED_DATA` inline, through fex-port 0060's sub-floor hooks;
  - guest or host at the module's edges: EIP, ESP, the FS base (guest TEB32)
    and the syscall bridge are guest; the syscall return address, its argument
    block and unix-call parameters are read through the window; tracker
    notifications and queries use host addresses, and the InvalidationTracker
    invalidates code by guest address;
  - the ARM64EC-only hooks FEXCore calls: no pool aliases for guest code, no
    Mono bridge (Wine publishes it to the x86-64 module only), FFS counters;
  - `_time64` in FEX's CRT;
  - no `thread_local`: the module has no TLS directory, and Wine runs the CPU
    before the loader sets up a thread's TLS block. The IR capture mark becomes
    a plain global there, and AllocWatch names a thread by its TEB.
- **rpmalloc 0003**: `os_mmap` maps through ntdll's `NtAllocateVirtualMemoryEx`
  when `kernelbase.dll` is not loaded (it had no fallback, by design, so every
  host mapping failed and the first heap was null).
- **madeira-unix 0062**: the Mach handler services a WoW64 process's low
  faults in its window. It finds the owner through the faulting thread's TEB
  and reads the owner's base without the windows lock (reservation publishes
  the base before the owner, release clears the owner first). Then it emulates
  the access against `B + g` with the sub-floor emulators. A fixed sub-floor
  image (`KUSER_SHARED_DATA`) still resolves first. The count is logged
  (`[wow64-fault]`, and `serviced_low_faults` in the window's release line).
  `build/wow64/fault_test.c` compiles the lookup from the patch and races
  publication against it.
- **wine-pe 0014** (rewritten): the stop moves from wow64.dll's `process_init`
  to `Wow64SystemServiceEx`, the guest's first system call.

## Phone runs

One lock session at about 79% battery:

```sh
./pp install --no-build
./pp ui --play app-620 --until done --wait 90 --shot --out .work/ui-runs/p2s3-commit
./pp ui --play app-367520 --until first-frame+10 --shot --out .work/ui-runs/p2s3-commit-hk
```

**Portal 2** (`.work/ui-runs/p2s3-commit`), from `pull/s1-host.log`:

```text
[wow64-fex] window base=0x7038010000 teb32 host=0x70b7e12000 guest=0x7fe02000 peb32 host=0x70b7f10000 guest=0x7ff00000 write_offset=0x6ef9ad0000
[wow64-fex] bridge host=0x7038030000 guest=0x20000
[wow64-fault] serviced 1 window access(es); latest guest 0xc5fd24 -> host 0x7038c6fd24 write 32 byte(s) insn=0xad3f85a0 pc=0x107896a84
[iOS-subfloor-decode] ml954 reading block bytes from backing: guest RIP=0x7bf8f420 -> 0x70b3f9f420
[iOS-subfloor-decode] ml954 reading block bytes from backing: guest RIP=0x7bf6b970 -> 0x70b3f7b970
err:wow:Wow64SystemServiceEx Playport: first i386 system call 0018 (args 0000007038C6FB58: ffffffff 00c5fb70 00000000 00c5fbd8); WoW64 pointer conversion is not wired, stopping
[wow64-window] release peb=0x126fd0000 base=0x7038010000 serviced_low_faults=1072
```

- The first serviced faults are wow64.dll's `thread_init` writing the initial
  i386 context to the guest stack through an unconverted pointer.
- FEX decodes eight blocks from the window, at `LdrInitializeThunk` and below
  `0x7bf6b970`. The system call's arguments are guest values: the current
  process, then pointers into the guest stack.
- The 1,072 serviced low faults are accesses nothing translated: wow64's
  context write, and the guest's push, pop, call and return, which are not
  translated inline yet. They were not broken down by site.
- The child ends with `c00000bb` after 67 ms. Its window and TEB pair are
  released, and the app keeps running. There is no crash report and no
  unhandled Mach fault.

**Hollow Knight** (`.work/ui-runs/p2s3-commit-hk`): exit 0 at `first-frame+10`.
First frame at 9.61 s, and the screenshot shows the main menu. The fex series
moved, and rpmalloc 0003 changed the ARM64EC module as well.

## Open

- wow64's thunks convert no pointers: `get_ptr`/`ULongToPtr` give low addresses,
  which work only through the fault service and slowly. `PtrToUlong` of host
  pointers that the native calls return is silently wrong. That conversion is
  the next boundary.
- Push, pop, call, return and the other direct memory sites fault into the
  service (step 4).
- `KUSER_SHARED_DATA` is not mapped in the window. Accesses to it stay
  untranslated and resolve through the session's sub-floor window.
- The fault service trusts the window to be released only by its owner's
  thread. The window's `base` is a plain store read relaxed, so the release
  ordering is a published-owner protocol, not a formal C11 one.

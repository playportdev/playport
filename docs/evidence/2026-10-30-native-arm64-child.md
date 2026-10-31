# A plain ARM64 program as a native ARM64 child of the x86-64 session (2026-10-30)

**Linear:** [PLA-512](https://linear.app/playportdev/issue/PLA-512) (spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516); decision
[0170](../decisions/0170-native-arm64-guests.md), proposed).

**Status: host side done; the phone gates have not run.** The runtime change, the test programs
and the dev IPA were built in the side copy `.work/worktrees/bnet-runtime` (decision 0117), which
may not reach the phone. The phone runs below are to be made from the main checkout after the
branch moves there; decision 0170 stays proposed until they pass.

## Change

- **`patches/madeira-unix` 0249** (`loader_ios.c`). Before it, a child whose executable is a plain
  ARM64 image fell into `wine_ios_child_main`'s S1 branch: a per-child copy of the session's
  ARM64EC ntdll, which loads ARM64EC and x86-64 images and whose `system32` is the ARM64EC set.
  `ios_load_child_ec_ntdll`, which maps the aarch64 ntdll build as a private image for a WoW64
  child (0061), now takes the kind of child: EC (X3c), WoW64, or native. Native is the aarch64
  build alone: no `LdrSystemDllInitBlock`, no i386 ntdll, no window, no EC code bitmap and no
  FEX. `wine_ios_child_main` takes it for `Machine == ARM64` in an ARM64EC session; a failed
  stack or ntdll ends the child with that status or `STATUS_DLL_INIT_FAILED`, as a WoW64 child's
  does. The log says `[arm64-child] native ARM64 child: private aarch64 ntdll, no window, no FEX`.
  An ARM64 child of an aarch64 session (upstream Madeira's case) keeps the S1 copy.
- **`patches/wine-pe` 0056** (`dlls/ntdll/loader.c`, aarch64 non-EC build only). 0015's sysarm64
  lookup required `WowTebOffset`, so a native child would have taken `kernel32.dll` and the rest
  from `system32` (ARM64EC images it cannot load). The lookup (`open_sysarm64_dll`) now applies to
  every process the aarch64 build runs; on iOS that is only the native side of a WoW64 process
  and a plain ARM64 child.
- **App:** no launch change. The session root starts any executable with `CreateProcessW`;
  `NtCreateUserProcess` asks wineserver for machine `0xAA64` (supported: wineserver's aarch64
  list starts with ARM64); nothing in `LaunchCoordinator`/`LaunchSettings` refuses or treats an
  ARM64 executable specially (`InstalledTitle.executableMachine` already reads `0xAA64`, the game
  page names it "ARM64"). `wine_host.c`'s comment on the `sysarm64` farm now names ARM64 titles.
- **Test programs:** `tools/compat/probes/arm64.c`, built by `tools/compat/probes/build.sh` with
  llvm-mingw's `aarch64-w64-mingw32-clang` into three folders (each one Local title):
  - `arm64/arm64.exe`: checks, then exit **42** (`0x2a`) when all pass, 1 when one fails. Checks:
    `IsWow64Process2` (not WoW64, native ARM64); no `wow64.dll`, `xtajit64.dll`,
    `libarm64ecfex.dll`; `kernel32.dll` from `sysarm64`; ntdll without the ARM64EC-only export
    `KiUserEmulationDispatcher`; `LoadLibrary("version.dll")` from `sysarm64` and a call; code
    written into `PAGE_EXECUTE_READWRITE` memory, flushed and called, rewritten in place, in a
    later page, and RW memory made `PAGE_EXECUTE_READ` (the anonymous executable path); a thread's
    exit code; the program itself as a child with `exit 7` (exit code 7). Log:
    `<dir>\arm64.log` and OutputDebugString. With `exit N` as its arguments it exits with N.
  - `arm64-fault/arm64-fault.exe`: the machine checks, then a write through a null pointer: the
    play must end as a failed one with `0xc0000005`.
  - `arm64-min/arm64-min.exe`: no C runtime, imports only `KERNEL32.dll`, `ExitProcess(42)`: a
    loader-only start that tells a loader failure from a CRT (`api-ms-win-crt-*` → `ucrtbase`)
    one.
  - `arm64-x86_64/arm64-x86_64.exe`: the same source for x86-64, only to check the program on the
    workstation.

## Review: every check of the session's machine in the forked loader files

The session is x86-64 (ARM64EC): `is_arm64ec()` and `main_image_info` are the session's.
`ios_cur_image_info()`, `ios_is_arm64ec_cur()` and `is_wow64()` are the calling pseudo-process's.
For a native ARM64 child `ios_cur_image_info()->Machine == 0xAA64`, so `ios_is_arm64ec_cur()` is
FALSE and `is_wow64()` is FALSE. Lines are the patched `build/ntdll-unix` files after 0249.

| File | Where | Check | Native ARM64 child |
| --- | --- | --- | --- |
| loader_ios.c | `ios_is_arm64ec_cur` 360 | owner's machine is AMD64 | FALSE: native paths everywhere below |
| loader_ios.c | `get_pe_dir` 563 | ARM64 → arm64ec only if owner is EC | `/aarch64-windows` for its builtins |
| loader_ios.c | `get_alternate_wineloader` 735 (called env_ios.c 2212) | `machine != get_alt_machine(current_machine)` | ARM64 is `current_machine`: NULL, no start.exe fallback |
| loader_ios.c | `load_main_exe` 1895 | ComPlus fallback | not reached (no machine mismatch) |
| loader_ios.c | `load_ntdll_functions` 2047, `load_ntdll` 2685/2697 | `is_arm64ec()` | session's own ntdll only; never on the child path |
| loader_ios.c | `ios_load_child_ec_ntdll` 2369 | kind → machine, i386 ntdll, EC bitmap | **0249**: native = ARM64 build, no init block, no i386 ntdll, no bitmap |
| loader_ios.c | `start_main_thread` 2985 | `load_wow64_ntdll(main_image_info.Machine)` | session only |
| loader_ios.c | `wine_ios_child_main` 3241 (log), 3399, 3419, 3436 | I386 branch; **new ARM64 && `is_arm64ec()` branch**; AMD64 && `!is_arm64ec()` | **0249**: the ARM64 branch; failure → `NtTerminateProcess` |
| env_ios.c | `init_peb` 2089 | owner I386 → WoW64 parameters | no |
| env_ios.c | 2205-2212 | DLL characteristic, alternate loader | as above |
| env_ios.c | 2542 | `is_wow64()` zero bits | owner-aware, FALSE |
| process_ios.c | `NtCreateUserProcess` 1300 | spawner EC && hybrid && ARM64 → spawner's machine | a plain ARM64 exe stays ARM64; an **ARM64X** exe from the EC session is promoted to AMD64 (to check for WoW's client, PLA-514) |
| process_ios.c | `NtQueryInformationProcess` | `is_wow64()` | owner-aware |
| signal_arm64_ios.c | `signal_set_full_context` 6684 | `ios_is_arm64ec_cur() && !is_ec_code(pc)` | FALSE: native context path |
| signal_arm64_ios.c | `get_wow_context` 6817 | `get_cpu_area(…, owner machine)` | none for ARM64 |
| signal_arm64_ios.c | `init_syscall_frame` 14056 | i386/ARM cpu area; `IOS_PFUNC` entry points | no cpu area; `LdrInitializeThunk`/`RtlUserThreadStart` from the child's ntdll (`ios_set_proc_ntdll`) |
| signal_arm64_ios.c | `ios_alert_wait_from_wow64` | `WowTebOffset` | 0 |
| signal_arm64_ios.c | exec-fault redirect 2310-2373 | none (image copy, pool RW→RX, anon alias table) | used by the child's images and anonymous code alike |
| thread_ios.c | `contexts_to_server` 1084, `contexts_from_server` 1112 | owner machine | native ARM64 contexts |
| thread_ios.c | `get_cpu_area` 1347 | 64-bit owner → NULL | NULL |
| thread_ios.c | `init_thread_stack` 1377 | CHPE cpu area only for an AMD64 owner | none |
| virtual_ios.c | `ios_x18_tramp_prealloc_scan` 9983 | image machine ARM64 or `.a64xrm` | scanned |
| virtual_ios.c | `ios_anon_plain_view` 10286 | `arm64ec_view` (session-global, set) | enabled: RW view, exec fault → pool RX (see below) |
| virtual_ios.c | pool copy x18 gate 11735-11751 | PE machine ARM64 or `.a64xrm` | the exe and every DLL are copied and x18-patched |
| virtual_ios.c | `is_emulated_code` 14613 | `ios_is_arm64ec_cur()` | FALSE: never emulated |
| virtual_ios.c | `map_image_into_view` 15119-15128 | ARM64X mapping when the owner is AMD64; EC ranges for AMD64 images | neither for a plain ARM64 image |
| virtual_ios.c | `virtual_map_main_module` 17264 | window only for I386 | normal map (`load_builtin` → `virtual_map_image`) |
| virtual_ios.c | `ios_wow64_*` window and TEB pairs | WoW64 | not reached |
| virtual_ios.c | `set_large_address_space` 17556 | session I386 | session only |
| virtual_ios.c | `virtual_alloc_first_teb` 17709 | `arm64ec_view` → `EcCodeBitMap` | session's first TEB only; the aarch64 ntdll never reads `EcCodeBitMap` (only `signal_arm64ec.c` does) |
| virtual_ios.c | `ios_view_owner_process_exit`, `ios_proc_end_sweep` | owner I386 | no |
| wow64_pair.h | `WowTebOffset` helpers | WoW64 | not reached |

The PE side (`dlls/ntdll/loader.c`, aarch64 build): `is_valid_binary` accepts `Machine ==
current_machine` (ARM64); `WowTebOffset` gates `init_wow64`, the TLS reservation and
`\KnownDlls32` — all off for a native child; 0056 removes the one gate a native child needs
lifted.

**Anonymous executable path.** In this ARM64EC session `ios_anon_plain_view()` is on: a guest
RWX range is backed by a pool slot whose guest view is the pool's RW side without EXEC; the first
native jump into it takes the exec fault, and the handler sends the pc to the pool's RX alias
(`ios_jit_anon_alias_lookup_rx`). Nothing there is FEX's: the same path serves a native child's
own generated code, one Mach exception per entry from outside the range (decision 0170's
unmeasured cost). `arm64.exe`'s rwx phase covers it; `MADEIRA_ANON_EXEC_POOL=1` would give the
RX view instead, should it fail.

**Image alignment.** Wine's builtins are linked with 16 KiB sections; a non-builtin ARM64 exe (the
test program, WoW's client) has 4 KiB sections. The pool copy is per image, and the run log's
`[jit-pool]`, `x18_images=… x18_sites=…` lines for `arm64.exe` are to be read on the phone run.

## Host results (side copy)

- **Probes built** (`tools/compat/probes/build.sh`, llvm-mingw 20260922): `arm64.exe` 76,800 B
  (Machine `0xAA64`; imports `KERNEL32.dll` and ten `api-ms-win-crt-*`), `arm64-fault.exe`
  76,800 B, `arm64-min.exe` 3,584 B (imports only `KERNEL32.dll`).
- **The program under desktop Wine** (x86-64 build, scratch prefix): every check `ok`, exit 42,
  the child's exit code 7, the rwx phase's four calls returned 1234, 4321, 777, 99. The
  `PROBE_FAULT` x86-64 build (built by hand, same flags) ended after its last log line with
  exit status 5, the low byte of `0xc0000005`. (The workstation cannot run the ARM64 build.)
- **`pp build` (dev)**, side copy, commit `842d223`: `verify-ipa: 95 checks passed, 0 failed`;
  IPA `Playport-26.5-f162ebde.ipa`, sha256
  `f162ebde2228d81b08cbb89ed46cb63b4c3338519b592b39c20efde37b00cf06` (side copy only: the phone
  runs need the main checkout's own build). `pp verify` of it after the records below were
  committed fails only `resources` (the bundled `artifacts.tsv` holds the copy's eight
  path-dependent rows), as 0117 expects.
- **Build records (0117).** Committed: `Runtime/aarch64-windows/ntdll.dll` (wine-pe 0056),
  `lib/libntdll_unix.a` (madeira-unix 0249), and both `winetest.exe` rows of
  `build/generated` (winetest embeds the wine tree's HEAD, which 0056 changes; the series'
  commits are made with fixed dates, so it is reproducible). Path independence: with 0249 left
  out of the series, the copy's unix stage gave main's recorded `libntdll_unix.a`
  (`fb50884c…`), and with it the same `29e9f5ca…` in two builds; every other aarch64 row of the
  pe stage, rebuilt in the copy's path, kept main's value. Kept at main's values: the six i386
  media DLLs (`colorcnv`, `iyuv_32`, `msvproc`, `quartz`, `resampledmo`, `vidreszr`),
  `lib/libdxmt_combined.a` and `lib/libidevice_ffi.a`, which differ in any copy's build.
  **Rebased onto `main` on 2026-10-31** (main had moved `ntdll.dll`, `libntdll_unix.a`,
  `libwin32u_unix.a` and both `winetest.exe` rows, and taken madeira-unix 0224–0248 and wine-pe
  0055): those rows conflicted and keep main's values, so the records commit fell away; the
  main checkout's build after the move regenerates them (0117). The branch's patches were
  renumbered then, madeira-unix 0224 → 0249 and wine-pe 0055 → 0056, and now apply after main's;
  the line numbers above are the pre-rebase tree's, and the commits named here are pre-rebase
  (`backup/pla-516-pre-rebase`).
- **The aarch64 Vulkan rows (PLA-513, 0117).** `Runtime/vulkan/aarch64-windows/` `d3d12.dll`
  (`f2ca5f41…`), `d3d12core.dll` (`b57db18f…`), `dxgi.dll` (`e9afd4b9…`) and
  `Runtime/vulkan-loader/aarch64-windows/` `vulkan-1.dll` (`1be90a18…`) and `winevulkan.json`
  (`0947fde3…`) are path-independent: `build/stages/vulkan-pe.sh` run again from scratch in a
  second root (`$PLAYPORT_BUILD/vkpe-alt`, stages `dxgi-aarch64 vkd3d loader`, the same
  sources) gave the same five files byte for byte, and none of the DLLs names the build's path
  (the only absolute paths in `d3d12core.dll` and `dxgi.dll` are llvm-mingw's own libc++abi and
  libunwind sources, which the committed arm64ec `dxgi.dll` carries too). The cross files link
  with `--no-insert-timestamp`.
- **`pp test` (full)**, side copy: all passed (names, secrets, patches with the 0249 and 0056
  trailers, `tools/tests`, every C host test, every Swift package). `pp slots` was not run: no
  DXMT tree changed (its stage reran only because it follows `pe`).

## Phone runs to make (main checkout)

Not run. Commands, in order, after the branch is in the main checkout and built there:

```sh
./pp build && ./pp install
bash tools/compat/probes/build.sh
P=$PLAYPORT_BUILD/compat/probes
./pp phone put $P/arm64/arm64.exe Documents/Import/arm64/arm64.exe
./pp phone put $P/arm64-fault/arm64-fault.exe Documents/Import/arm64-fault/arm64-fault.exe
./pp phone put $P/arm64-min/arm64-min.exe Documents/Import/arm64-min/arm64-min.exe
./pp ui --action import:Import/arm64-min
./pp ui --action import:Import/arm64
./pp ui --action import:Import/arm64-fault
./pp ui --play dir-arm64-min --wait 120 --shot      # expect title: done … exit=0x0000002a
./pp ui --play dir-arm64 --wait 180 --shot          # expect exit=0x0000002a; arm64.log: done ok
./pp ui --settings 'dir-arm64:{"arguments":"exit 9"}' --play dir-arm64 --wait 120   # expect exit=0x00000009
./pp ui --play dir-arm64-fault --wait 180 --shot    # expect exit=0xc0000005, the app back in the library
./pp ui --play app-367520 --until first-frame+10 --shot   # Hollow Knight on the same IPA
```

`pp ui` reports a play that ends with a nonzero code as not ok (`title_failed`): for `arm64`,
exit `0x2a` is the pass. Read `arm64.log` from the title's folder (`pp phone ls
Documents/prefix/drive_c/Games` names it, `arm64` unless an earlier import took the name; then
`pp phone pull Documents/prefix/drive_c/Games/arm64/arm64.log DIR`), and in
the run log: `[arm64-child] native ARM64 child`, `[ec-child-ntdll] loading …/aarch64-windows/ntdll.dll`,
`[ec-child-ntdll] no CHPE metadata` (expected), `[jit-pool]`/`x18_images=` lines for `arm64.exe`,
and the `[anon-view]` line. If `arm64-min` passes and `arm64` does not, the CRT path
(`api-ms-win-crt-*` → `sysarm64\ucrtbase.dll`) is the place to look; if neither starts, the
`[arm64-child]`/`[ec-child-ntdll]` lines.

Then record the run directories and the IPA sha256 here, and move decision 0170 to accepted (with
the 0082 and ARCHITECTURE.md "All guests are x86" amendments it names) or amend it with what
failed.

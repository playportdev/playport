# A plain ARM64 program as a native ARM64 child of the x86-64 session (2026-10-30)

**Linear:** [PLA-512](https://linear.app/playportdev/issue/PLA-512) (spec
[PLA-516](https://linear.app/playportdev/issue/PLA-516); decision
[0170](../decisions/0170-native-arm64-guests.md), accepted on these runs).

**Status: done.** The runtime change, the test programs and a first dev IPA were built in the side
copy `.work/worktrees/bnet-runtime` (decision 0117); the branch then moved to the main checkout,
where it was built again and the phone runs [below](#phone-runs-2026-10-31-main-checkout) passed on
2026-10-31.

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
test program, WoW's client) has 4 KiB sections. The pool copy is per image: the phone run's log
has a `[jit-pool] image … → pool …` line for each, and `[child-ntdll] x18-patched 787
instructions` for the child's private ntdll.

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

## Phone runs, 2026-10-31 (main checkout)

IPA sha256 `2f36ea66dea1feed4c45907ea6306be5a7adbe75a7355d547911d6bada63e5d8` (the `installed`
event of every run below; branch `dev/pla-516-battlenet` at `31780685`). The probes were imported
as Local titles (`import:Import/arm64-min`, `arm64`, `arm64-fault`). Run directories are under
`.work/ui-runs/`. `pp ui` reports a play that ends with a nonzero code as `title_failed`, so the
probes' passes read `ok: false` there; the code is the result.

| Run | What | Result |
| --- | --- | --- |
| `20261031T204826` | `--play dir-arm64-min --wait 120 --shot` | exit `0x2a`: the loader-only program started and ended |
| `20261031T204905` | `--play dir-arm64 --wait 180 --shot` | exit `0x2a`; `arm64.log` (pulled into the run's `arm64-log/`) ends `done ok` |
| `20261031T204938` | `--settings 'dir-arm64:{"arguments":"exit 9"}' --play dir-arm64` | exit `0x9`: the arguments reached the child and its code came back |
| `20261031T205011` | `--play dir-arm64-fault --wait 180 --shot` | exit `0xc0000005`, the app back on Home |
| `20261031T205520` | `--play app-367520 --until first-frame+10 --shot` | Hollow Knight first frame at +11.1 s, ok |

- **`arm64.log`** (run `20261031T204905`): every check `ok`: `IsWow64Process2 process 0 native
  0xaa64`, not WoW64; no `wow64.dll`, `xtajit64.dll` or `libarm64ecfex.dll`; `kernel32.dll` and
  `version.dll` from `C:\windows\sysarm64`, a call into `version.dll`; ntdll is the aarch64
  build; the four RWX calls returned 1234, 4321, 777 and 99 (RWX, rewritten in place, a later
  page, RW made `PAGE_EXECUTE_READ`); a thread's exit code 42; the program's own child with
  `exit 7` ended with 7; `done ok`.
- **The run log** (`pull/s1-host.log`) of each probe run: `[arm64-child] native ARM64 child:
  private aarch64 ntdll, no window, no FEX`, `[ec-child-ntdll] loading …/aarch64-windows/ntdll.dll`
  (twice in `20261031T204905`: the program and its `exit 7` child), `[child-ntdll] x18-patched 787
  instructions`, the `[anon-view] guest code ranges: RW view …` line, and `session: title 2: ended,
  exit code 0x0000002a` (`0x00000009`, `0xc0000005`). For `arm64-fault` the child's thread raised
  `c0000005` at a write to address 0 and `abort_process` tore down that pseudo-process only.
- **Screenshots** (`screen-stop.png`, kept in the run directories): after `arm64` the app is on
  Home with the box "arm64 stopped unexpectedly / It exited with code 0x0000002A." over it (the app
  calls every nonzero code a stop; 42 is the probe's pass); after `arm64-fault` the same box says
  "arm64-fault stopped unexpectedly / It exited with code 0xC0000005.", with Home and its Recent
  row behind it: the app stayed usable. Hollow Knight's shows its title menu (Start Game, Options,
  Achievements, Extras, Quit Game) under the on-screen controls.

**Later IPAs.** The pool-copy change (decision 0176, madeira-unix 0262) and the x18 patcher's
later forms kept the probe passing: `arm64` exit 42 on IPA `d4c7ef73…` (run `20261101T002236`)
and on IPA `5b14b446…` (run `20261101T011306`), each with Hollow Knight's first-frame+10
passing ([2026-10-31-wow-arm64-start.md](2026-10-31-wow-arm64-start.md)).

Decision 0170 moved to accepted with these runs, and amends 0082 and `ARCHITECTURE.md`'s "All
guests are x86".

## Wine's ARM64 notepad: the aarch64 assemblies (2026-11-01)

Wine's own ARM64 `notepad.exe` (`.work/compat/notepad-arm64.exe`, imported as `dir-notepad`), a
GUI program with an application manifest naming Common Controls 6, on IPA `bfbf4f78` (run
`20261101T051825`): `import_dll Loading library comctl32.dll (which is needed by
C:\windows\sysarm64\comdlg32.dll) failed (error c000007b)`, the same for `notepad.exe`'s own
import, then exit `0xc0000135`. The prefix log said `winsxs: 20 assemblies installed`: each of
Wine's 10 manifests for `x86` (the i386 set) and `arm64` (the ARM64EC set, which the ARM64EC ntdll
takes for an `arm64`, `amd64` or `*` request). The aarch64 ntdll of a plain ARM64 child also
builds its manifests' architecture as `arm64` (actctx.c `current_archW`), so its `*` request found
`arm64_microsoft.windows.common-controls_…_deadbeef` and the ARM64EC `comctl32_v6.dll`, an image
it cannot load.

- **wine-pe 0058:** the aarch64 ntdll looks an `arm64` assembly up as `sysarm64_…` in
  `C:\windows\winsxs\manifests` (`lookup_manifest_file`), as 0056 takes its system DLLs from
  `sysarm64`. The manifest's own architecture stays `arm64`, which `is_matching_identity` checks,
  and the DLL path follows the manifest's directory name. The ARM64EC and i386 ntdll keep their
  lookup; their records changed only by the build's version string (a new commit in the tree).
- **`wine_host.c` `link_winsxs`:** a third set, `sysarm64_` directories with `processorArchitecture`
  `arm64` linked into `Runtime/aarch64-windows`, which has every assembly's module. The
  `_deadbeef` manifests are rewritten at every session start, so an existing prefix gets them on
  its next play. comctl32 5 needs nothing new: it is the plain `comctl32.dll` the child already
  takes from `sysarm64`.
- **Host:** `tools/tests/test_winsxs.py` checks the three sets, that every assembly's module is
  in the aarch64 set too, and the `sysarm64_` prefix of 0058.
- **`menu:open`** waited for a first frame that a GDI-only program never draws; it now also takes a
  guest window up 10 s with no frame (`Dev/UIDriver.swift`, DEVICE.md).

| Run | IPA | What | Result |
| --- | --- | --- | --- |
| `20261101T053113` | `5f72d802…` | `--action play:dir-notepad --action wait:20 --shot-each-action --wait 90` | `winsxs: 30 assemblies installed, 0 failed`; `comctl32_v6.dll` mapped as a native image; no `c000007b`; notepad's window up |
| `20261101T053916` | `89baa276…` | notepad with the text bar (PLA-267, PLA-606; see [2026-10-30-wow-notice-and-play.md](2026-10-30-wow-notice-and-play.md#text-bar-into-wines-arm64-notepad-2026-11-01)) | ok, 8 actions |
| `20261101T054245` | `89baa276…` | `--play app-367520 --until first-frame+10 --shot` | Hollow Knight first frame at +10.3 s, title menu |
| `20261101T054342` | `89baa276…` | `--play dir-arm64 --wait 180 --shot` | exit `0x2a` (pass) |
| `20261101T054448` | `89baa276…` | `--settings 'dir-d3d12:{"graphics":"vulkan"}' --play dir-d3d12 --wait 180` | exit `0x0` |

The screenshot `action-02-wait_20.png` of `20261101T053113` shows "Untitled - Notepad" with its
File, Edit, Format, View and Help menus, an empty edit area and the status bar "Ln 1, Col 1". The
caption buttons show the letters `0`, `1` and `r`, the Marlett codes for minimise, maximise and
close, drawn in another font. Hollow Knight's run is the runtime smoke for the wine-pe change.
`./pp test --quick` passed.

### Marlett in the prefix's fonts (2026-11-01)

Not ARM64-only: the app shipped no Marlett at all. win32u draws every window's caption buttons
with it (`dlls/win32u/defwnd.c` `draw_frame_caption`, `CreateFont("Marlett", SYMBOL_CHARSET)`;
`menu.c` its menus' magic bitmaps, user32 `uitools.c` its `DrawFrameControl` captions), and
`Runtime/fonts` had only Wine's Tahoma faces, so font matching fell back and drew the codes as
letters. An x86-64 window showed the same: Tomb Raider's error box's close glyph drew as `r`
([2026-10-11-gdi-windows.md](2026-10-11-gdi-windows.md#findings-along-the-way)). Wine's tracked
`fonts/marlett.ttf` (6,136 B, LGPL-2.1-or-later in its name table) is now staged as
`Runtime/fonts/marlett.ttf` (`build/stages/stage-artifacts.py` `FONTS`), which `wine_host.c`
`link_fonts` links into `C:\windows\fonts` with the rest (`fonts: 3 links` in the run's log), and
registered as `Marlett (TrueType)` in the seed's top-up `Fonts` key for DirectWrite
(`app/tools/prefix-registry.py`); its SFD header is excerpted with the Tahoma faces' in the notices
(`build/notices-assemble.sh`, [NOTICES.md](../NOTICES.md#wine-fallback-fonts)). Host:
`tools/tests/test_fonts.py`, `test_prefix_registry.py`.

IPA sha256 `b0fdcf2a63fec7e65a273289cc76264902144f6ef8b91ea4f1b80aa7d7caf46d` (branch
`dev/pla-516-battlenet`):

| Run | What | Result |
| --- | --- | --- |
| `20261101T060119` | notepad, then the text bar's `textbar:tab` ([2026-10-30-wow-notice-and-play.md](2026-10-30-wow-notice-and-play.md#text-bar-into-wines-arm64-notepad-2026-11-01)) | ok, 7 actions; `action-02-wait_20.png`: the caption buttons are the minimise bar, the maximise box and the close cross |
| `20261101T060426` | `--play app-367520 --until first-frame+10 --shot` | Hollow Knight first frame at +10.50 s |
| `20261101T060520` | `--play dir-arm64 --wait 180 --shot` | exit `0x2a` (pass) |
| `20261101T060616` | `--settings 'dir-d3d12:{"graphics":"vulkan"}' --play dir-d3d12 --wait 180` | exit `0x0` |

Not checked after the change: an x86-64 window's caption (no x86-64 title with a captioned GDI
window was played). The fix is the same file for every architecture's win32u.
`./pp test --quick` passed.

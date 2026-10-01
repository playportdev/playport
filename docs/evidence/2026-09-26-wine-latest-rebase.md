# Wine on upstream: Madeira's fork rebased onto wine-11.18

**Date:** 2026-09-26. **Status:** done; `pins.lock` builds Wine from WineHQ
wine-11.18 with Madeira's fork as `patches/wine-port` and its replacements
ported in `patches/madeira-unix` (section 9,
[decision 0013](../decisions/0013-wine-on-upstream.md)). The IPA built from
the pins plays Hollow Knight on the phone to its main menu at 120 fps. The
approach is decision
[0007](../decisions/0007-dxmt-on-upstream.md)/[0008](../decisions/0008-fex-on-upstream.md)'s,
applied to the third component.

## 1. What moves

| | Now | Target |
| --- | --- | --- |
| Wine base | willfaust/wine `madeira-lgpl` `723d1bf5`, on WineHQ **wine-11.4** `cc893ef9` | WineHQ **wine-11.18** commit `7b3fff76fa5178f6ce0141b2c776afa2a822f101` (tag object `ccf4f04c`, 2026-09-18), 3,493 upstream commits later |
| Madeira's fork commits | 56 non-merge commits (12.8k lines over 69 files), built as the pin | a `wine-port` series: those 56 rebased |
| Madeira's whole-file replacements | `build/ntdll-unix`, `build/win32u-unix`, `build/wineserver` in Madeira (about 92k lines; each `*_ios.c` is a forked copy of a wine-11.4 source) | each three-way merged onto its wine-11.18 original |
| Playport's series | `patches/wine-pe` 0001-0006, `patches/wine-unix` 0001-0003 | unchanged if they still apply |

**Why the release, not `master`.** WineHQ tags a development release every two
weeks; wine-11.18 was a week old and 218 commits behind `master`. A tag gives
the next rebase a fixed target, as for FEX.

## 2. Step 1: the fork's 56 commits

`git rebase wine-11.18` of `madeira-lgpl` (merge base `wine-11.4`) with
`merge.conflictstyle=zdiff3`, every conflict resolved by reading both sides.
49 of 56 applied without conflicts. `git range-diff` against the original:
42 are identical, 14 differ. 7 of those 14 are the resolutions below. In the
other 7 only context lines changed (a renamed argument, a new neighbouring
line); the range-diff shows each of their hunks in the same function as
before.

| Madeira commit | Conflict | Resolution |
| --- | --- | --- |
| `24fa958` catch-up | `server/winstation.c`: upstream rewrote `DECL_HANDLER(create_desktop)` on `create_named_object`; new and existing desktops now share one exit | upstream's handler; the iOS virtual-desktop block (`WSF_VISIBLE`, cursor clip, forced input desktop) after the new/existing branch, before upstream's input-desktop line, so it covers both cases as before |
| `f3339da` EC-ntdll fixes | `unix/unix_private.h`: upstream deleted the unix-side `is_ec_code` (the EC check moved into the syscall dispatcher, `f12bd89a`, `2f69c014`) and `teb_key` (thread data is now reached through `get_thread_data()` and its own key) | upstream's header; `is_ec_code` (with the port's per-thread-PEB fix) and an `extern teb_key` kept under `WINE_IOS`, for the iOS replacements that still call them |
| `de9cfea` Crashpad-VEH guard | `exception.c`: upstream calls handlers through `call_vectored_handler()` | the port's context snapshot/restore around upstream's call |
| | `signal_arm64ec.c` `leave_syscall_callback`: upstream added the suspend-doorbell check | upstream's body after the port's null-CPU-area return |
| | `unix/debug.c`: upstream takes debug info from `get_thread_data()`, falls back to `initial_info` and skips pid/tid without one | upstream's: it now does what the port's TEB-less-thread guard (ml379) did |
| | `unix/sync.c`: upstream takes the tid from `get_thread_data()->tid` | the port's alert taps (ml400/406/407) with upstream's lookup |
| `81f81e1` rename | the lines resolved above | the rename applied to them |
| `90455e3` ARM64EC traces | `server/event.c`: upstream moved event set-up into `event_init` (`object_params`, `create_named_obj_handle`) | the ml809 stats zeroing and the ml805 create record moved into `event_init`: a create is recorded at every event's birth, not in the request handler, which no longer sees the object |
| | `server/handle.c`: `close_handle` is optional in `object_ops` | the ml805 close record before upstream's null-checked call |
| `e828644` census, ECO QoS, cpu-count | `unix/sync.c`: the tid lookup, as above | the ml1133/ml1115 counters before upstream's lookup |
| | `unix/system.c`: upstream replaced `peb->NumberOfProcessors = num` with a `cpu_count` global behind the PEB and every processor query | the ml1122 `cpu-count` override sets `cpu_count`, so every processor query agrees with it, not only the PEB |
| `feb96ad` xinput host pads | `xinput1_3/main.c`: upstream replaced the per-controller lock with one `xinput_cs`, reads state through `get_current_state`, and keeps keystroke edges in its own `last_state`, read through `xinput_get_state` | upstream's locking. The host snapshot still comes first in `xinput_get_state`, `XInputSetState`, `XInputEnable`, `XInputGetCapabilitiesEx`, battery and DSound GUIDs. The port's keystroke split is dropped: upstream's `check_for_keystroke` already reads through `xinput_get_state`, so host pads use the same edge detector |

Playport's `patches/wine-pe` (6) and `patches/wine-unix` (3) apply to the
rebased tree without conflicts. With `patches/wine-pe` on top, the `pe` stage's
build (`build/stages/wine-pe.sh` steps 2-6, run on that tree) completes:
`make` exits 0 in both `build-macos` and `build-arm64ec`, and both PE machine
checks pass. The PE sets change as upstream changed them:

- 1,465 → 1,437 aarch64-windows files and 1,002 → 986 arm64ec-windows files.
  Upstream no longer builds 32-bit-only DLLs for 64-bit ARM (`*_DISABLED_SUBDIRS`):
  `crtdll`, `ctl3d32`, `d3d8`, `d3dim`, `d3dim700`, the `dm*` DirectMusic DLLs,
  `dplay`, `dplayx`, `dpwsockx`, `iccvid`, `iprop`, `msscript.ocx`,
  `msvcp70`/`71`, `msvcr70`/`71`, `msvcrt20`/`40`, `msvcrtd`, `olecli32`,
  `olepro32`, `olethk32` and `vdmdbg`. Windows x64 has none of these in
  System32 either, so an x86-64 title should not look for them.
- New in both sets: `dsrole`, `icu`, `icuin`, `icuuc`, `iyuv_32`, `ndfapi`,
  `rtscom`, `thumbcache`, `tiptsf`, `windows.devices.radios`, `winsqlite3`,
  `wkscli`; also `lsass.exe` in aarch64.

## 3. Step 2: the replacements

Each `*_ios.c` is merged in a Madeira checkout at the pin with
`patches/madeira-unix` applied (so "ours" carries Playport's fixes too), with
`git merge-file --zdiff3`: base is the matching wine file at `madeira-lgpl`,
theirs is the same file on the rebased series. Each directory is then compiled
against the rebased tree (with `patches/wine-unix` on it) by the `unix`
stage's shims, once with Madeira's flags and once with
`-Wimplicit-function-declaration -Wint-conversion` turned back on as warnings,
and that warning list is compared with the same compile of the current build
tree (`$PLAYPORT_BUILD/run/unix`).

**`build/win32u-unix`: all 46 units compile and `libwin32u_unix.a` links.**
Six conflicts, and three changes that merged cleanly but did not compile or
called a function that no longer exists:

| File | Upstream change | Resolution |
| --- | --- | --- |
| `class_ios.c` | class data moved into server shared memory (`class_shm->info`), `is_winproc_unicode` removed, `local` became `is_local_class()`, builtins are registered by `fnid` | upstream's code; the per-PEB builtin winproc table (`ios_resolve_builtin`, `ios_cur_user32_module`) and the bounded `class_list` walk kept on it |
| `driver_ios.c` | the null driver's client surface moved and changed signature | upstream's; the ml1920 gamepad query kept |
| | `window_surface_funcs` now carries `.size`; `window_surface_create` lost its size argument | the iOS surface funcs written with designated initialisers |
| | `send_hardware_message` is now `server_send_hardware_message` (same body; the old name was an implicit declaration that would not link) | the two iOS input calls renamed |
| `winstation_ios.c` | `user_thread_info.top_window` is an `HWND` | the iOS early return passes it through without `UlongToHandle` |

**`build/wineserver`: all 45 wine/server units compile** (the replacements
and the 27 `unix-gaps.sh` rebuilds from the tree, plus the new `alpc.c`, which
that list must gain). The implicit-declaration warnings are the same three as
in the current build (`ios_usd_time_enabled`, `ios_usd_report_alias`,
`sd_is_valid`: `request_ios.c`'s `"security.h"` resolves to
`include/security.h`, as today).

| File | Upstream change | Resolution |
| --- | --- | --- |
| `request_ios.c` | the first thread is added with `add_process_thread` | upstream's, with the `[wineserver]` log lines around it |
| `mapping_ios.c` | image data directories read through `GET_DATA_DIR` | ml936's `reloc_dir` is the BASERELOC directory's presence; `has_relocs` adds the RELOCS_STRIPPED test as upstream does |
| | the user-data mapping is a `create_named_object` with `mapping_init_data` | the ml731c alias placement after upstream's creation |
| `mach_ios.c` | the arm64 integer context is `x0[18]` and `x19[12]` (x19-x28, fp, lr); x18 moved to a `SERVER_CTX_TLS` block | both register captures (thread state and syscall frame) fill the split arrays; x18 is not reported (iOS owns it) |
| `window_ios.c` | `create_window` takes the dpi context and the monitor dpi | the iOS desktop auto-create takes them as the `get_desktop_window` force path does |

`main.c`, `mach.c` and `unicode.c` did not change upstream, so `main_ios.c`,
`mach_ios.c` (apart from the context layout) and `unicode_ios.c` carry over.

## 4. Step 3: ntdll-unix, the thread-data model

The five smaller `build/ntdll-unix` replacements are ported (commit `234f4c4`
in the port's Madeira clone): `env_ios.c`, `process_ios.c`, `loader_ios.c`,
`server_ios.c` and `thread_ios.c`. With the unported `signal_arm64_ios.c` and
`virtual_ios.c` left out, 21 of the 23 ntdll-unix units compile against
wine-11.18. `wcheck-ntdll.sh` compiles them with `build.sh`'s flags and the
warnings those flags hide turned back on. It reports the same warnings as the
same compile of the current build (Apple functions with no declaration, and
`unix_init_startup_info`).

What wine-11.18 changed, and what the port does:

- **Thread data.** Per-thread server fds, the tid, the suspend flag and the
  signal and kernel stacks moved out of the TEB (`ntdll_thread_data` in
  `GdiTebBatch`) into `struct thread_data`, reached through `thread_data_key`.
  `NtCurrentTeb()` now reads `thread_data->teb`. The first thread gets its
  thread data before `server_init_process( data )`, and its TEB only in
  `init_startup_info`. A new thread gets thread data in
  `create_server_thread` and its TEB from `virtual_alloc_teb( data )`.
  `start_thread` was folded into `server_init_thread( data )`, and
  `set_thread_id` and `signal_init_threading` are gone (`init_teb` fills
  `ClientId` from `data->tid`).
- **The main image.** It moved into the `main_module` global, which
  `virtual_map_main_module` fills. `load_main_exe` and `load_start_exe` lost
  their `module` argument, `init_peb` takes `debugged`, and `get_load_order`
  takes the system-dir flag and the mapping.

| File | Resolution |
| --- | --- |
| `loader_ios.c` `start_main_thread` | upstream's order (thread data, `server_init_process( data )`, `init_startup_info`, `dbg_init`), with the iOS log marks. The x18 TSD-slot probe runs right after the thread data is made, and the key holds NULL until the TEB exists. A new `ios_publish_first_teb` stores the TEB after `init_startup_info` and aborts if the slot does not read back that TEB. No PE code runs before then. |
| `loader_ios.c` `wine_ios_child_main` | a pseudo-process child is a raw pthread, so it now gets `virtual_alloc_thread_data()` and `thread_data_key`, then `virtual_alloc_teb( data )`. The `teb_key` store is gone. `server_init_process_child( data, fd )` sets `data->tid` and the TEB's `ClientId`/`RealClientId` to the child's pid (the global `pid` is the session's). The child's `main_module` is saved and restored around its `init_startup_info`, like `main_image_info`. |
| `loader_ios.c` `load_main_exe` | upstream's body, with Madeira's `[main-exe]` traces. On iOS, a system-dir exe with no file is loaded as the builtin at any time, as in 11.4, not only while the prefix bootstraps. |
| `loader_ios.c` `load_builtin` | the `LO_DISABLED` check in the iOS early return uses the new `get_load_order` arguments. The rest of the function is in `#else` (iOS returns before it), so it takes upstream's text, including 7fcd356f ("always load builtins from the ARM64 directory on ARM64EC"). |
| `env_ios.c` | `init_peb( params, debugged, module )`. The module is `main_module` taken right after `load_main_exe`, so ml111's per-thread PEB write and ml983's owner note keep a per-child module. |
| `server_ios.c` | request and reply go through `data->request_fd`/`reply_fd`, keeping the in-process wineserver wake (`ios_wineserver_wake`). `init_thread_pipe( data )` keeps the ml586 fd trace. The iOS suspend override uses `data->suspend`. `signal_start_thread` takes three arguments and still starts at the owner-aware `ios_cur_image_info()` entry. The ml669 bad-close log gains upstream's null-`peb` guard. |
| `server_ios.c` `server_init_thread` | takes the iOS parts of the old `start_thread`: the ml1133 QoS/eco hook and publishing the TEB through `ios_teb_tls_key`. A system thread publishes NULL. |
| `thread_ios.c` | `create_server_thread` (new upstream) carries the ml586 request-pipe trace, and `NtCreateThreadEx` is upstream's. `pthread_exit_wrapper` closes the fds from `get_thread_data()`. The ml558 native-thread guard tests thread data, not the TEB (a system thread has fds but no TEB). The ml413/ml173 exit hooks run only when there is a TEB. `send_debug_event` takes the thread data. `apple_spawn_main_thread` (new) is left out on iOS. |

What `virtual_ios.c` must now provide, from the undefined symbols of the ported
objects compared with the current build: `virtual_alloc_first_thread_data`,
`virtual_alloc_thread_data`, `virtual_free_thread_data`,
`virtual_alloc_teb( struct thread_data * )`, `virtual_map_main_module`,
`thread_data_key` and `cpu_count`. It also has to store the TEB into
`ios_teb_tls_key` only where the loader and `server_init_thread` do not.

## 5. Step 4: `virtual_ios.c`

A whole-file three-way merge of `virtual_ios.c` gives 21 conflicts, and most
of them are misaligned: Madeira added large blocks of iOS code between
upstream functions, and diff3 pairs those blocks with unrelated upstream text.
Applying upstream's own `virtual.c` diff (`723d1bf5..wine-port-11.18`, 61
hunks) with `patch -F3` instead places 53 hunks and rejects 8. Each of the 8
fuzzed hunks was checked where it landed.

| Hunk | Resolution |
| --- | --- |
| `address_space_start` | the x86 DOS-area branch is dropped as upstream does. iOS keeps `0x100010000`, above the 4GB `__PAGEZERO`. |
| `map_free_area` top-down | Madeira's `gap_lo` now starts at `max( base, view end )` (upstream's fix) and keeps the `[va-scan]` counters. |
| `virtual_map_image`, `virtual_map_section` | moved to `pe_mapping_info`: shared file, image info and name come from the mapping, and `load_builtin` takes the new arguments. The ml366 `[img-map-fail]` line names `pe_mapping->nt_name`, and the eager JIT copy of builtin exec sections reads the alignment from `pe_mapping->image`. The `[map-sec]` traces are kept. |
| `virtual_init` | the DOS-area mapping is dropped as upstream does. `get_system_affinity_mask` is now inline in `unix_private.h` (from `cpu_count`), so it is removed here and `get_host_page_size` added. The ml433 cage holdback is kept. |
| TEB and thread data | `init_teb`, `init_thread_data`, `virtual_alloc_first_thread_data`, `virtual_alloc_first_teb` and `virtual_alloc_teb` are upstream's. The iOS changes: the shared user data goes where `map_view` places it (it cannot be at `0x7ffe0000`), followed by the ml952 sub-floor window for guest reads of that address. Madeira's below-2GB exemption for the TEB block is no longer needed, since 11.18 sets no upper limit. |
| `set_large_address_space` | upstream's function (now static, called from `virtual_alloc_first_teb`) replaces `virtual_set_large_address_space`, which Madeira called from `init_peb`. On iOS it still resets `address_space_start` to `0x10000` for a 64-bit process, as 11.4 did, and ends with the ml990 `user_space_limit` clamp. |
| `free_reserved_memory` | upstream moved it above its callers. The moved copy gets ml799's guard, which never frees the FEX arena, and the old copy is removed. |
| `get_host_addr_space_limit` (fuzzed, applied) | upstream added an `__APPLE__` return of `0x7ffffe000000`, macOS's ceiling. That is `#if !WINE_IOS`, so iOS keeps the ml122/ml749 walk and the kernel `max_address`. |

Check: all 23 ntdll-unix units other than `signal_arm64` compile. The
warnings in `virtual_ios.c` with the hidden warnings turned back on (19
undeclared `mach_vm_*` calls) are the same as for the same compile of
`.work/run/unix`. Across those 22 objects, the unresolved symbols equal the
current build's except for `signal_init_threading`, which 11.18 removed. So
`virtual_ios.c` now provides every thread-data and main-module entry point that
the other ported units call. It is committed as `bd67ea9` in the port's
Madeira clone.

## 6. Step 5: `signal_arm64_ios.c`

Applying upstream's `signal_arm64.c` diff (57 hunks) to the 14,649-line
replacement with `patch -F3` places 46 hunks, 10 of them with fuzz, and rejects
11. The assembly hunks all apply: the syscall and unix-call dispatchers use
x11/x12 for scratch, take their frame from `sp` for unwinding, and export the
kernel-stack and user-stack labels; the return path raises `SIGUSR2` for
`RESTORE_FLAGS_EMULATION`; `signal_start_thread` finds the TEB in x2. The iOS
prologue that loads x18 from the TLS slot comes before any of those registers
are used. Upstream's new semantics are kept where iOS allows.

| Place | Resolution |
| --- | --- |
| `signal_set_full_context` | takes upstream's cooperative-suspend branch (`suspend_pending`, `SuspendDoorbell`). The iOS bounce to `KiUserEmulationDispatcher` stays here, with its ml420 JIT-pool exception and its ml944-947 probes. It now also sets `InSimulation` and clears `RESTORE_FLAGS_EMULATION`, so the dispatcher does not repeat the bounce through `SIGUSR2`. |
| `is_emulated_code` (`virtual_ios.c`) | upstream's test uses `is_arm64ec()` from `main_image_info` and the session bitmap. On iOS it follows the current pseudo-process (`ios_is_arm64ec_cur`), reads that process's own `EcCodeBitMap` (`is_ec_code`), and never counts a JIT-pool pc as emulated, for the same reason as ml420. `NtSetContextThread`, `restore_context` and `usr2_handler` all make the same decision through it. |
| `is_ec_code` (`unix_private.h`, `WINE_IOS`) | reads the thread's peb through `get_thread_data()->teb`, since `teb_key` no longer exists. The `extern teb_key` is removed. |
| `setup_raise_exception`, `setup_exception` | take the thread data and skip the debug event while simulating, as upstream does. The iOS `setup_exception` wrapper, which reports a pool pc as its PE address, is kept. |
| `handle_syscall_fault` | upstream's (`data->jmp_buf`, and no longer handled without a syscall frame). |
| `segv_handler`, `ill_handler`, `bus_handler`, `trap_handler`, `abrt_handler` | the iOS handlers are kept. They only pass the thread data to `virtual_handle_fault`, `handle_syscall_fault` and `setup_raise_exception`. Upstream's ESR decoding in `segv_handler` is not taken. |
| `SIGBUS` | upstream sends it to `segv_handler`. It stays with the iOS `bus_handler`, which does the alignment and FEX-pool repair. |
| `quit_handler` | upstream's logic, after the ml483 no-TEB check. |
| `usr1_handler` | takes the cooperative suspend for a thread in simulation, and `CONTEXT_ARM64_X18` for the in-syscall case. A thread with thread data but no TEB yet now answers the suspend with `server_select`, as upstream does. Upstream's rebuild of the syscall frame when the signal lands in a dispatcher prologue is left out: it resumes at the kernel-stack label, which reads x18, and on iOS sigreturn clears x18 and skips the prologue that reloads it. |
| `usr2_handler` | upstream's `KiUserEmulationDispatcher` resume for an emulated `frame->pc`, after the ml483 check, and no longer run without a syscall frame. |

Check: all 23 ntdll-unix units compile against the rebased tree. With the
hidden warnings turned back on, `signal_arm64_ios.c` gives the same warnings
as the same compile of `.work/run/unix` (undeclared `mach_*`,
`sys_icache_invalidate`, `ios_tail_carve_lookup_trylock`). Across all 23
objects, the unresolved symbols equal those of the current build's 22. The
defined symbols differ only by upstream's renames and additions
(`thread_data_key`, `virtual_*_thread_data`, `virtual_map_main_module`,
`is_emulated_code`, the dispatcher label pointers, the ALPC and `Ps*`
entry points). No file in the Madeira app sources, win32u or wineserver names
a removed symbol. The port is `4407378` in the port's Madeira clone, and the
`unix_private.h` change is `340dd2a1` on `wine-unix-11.18`; it belongs in the
fork commit that keeps `is_ec_code` (f3339da9f6f) when the series is written.

Madeira's `build/ntdll-unix/build.sh` then compiles all 23 ntdll units and
every unixlib except two, so `libntdll_unix.a` is not yet built:

- `bcrypt_unixlib`: wine-11.18 has no `dlls/bcrypt/gnutls.c`. bcrypt now uses
  SymCrypt on the PE side and has no unix library, so `build.sh` must drop
  it, and `unix-gaps.sh`'s gnutls-config check must stop requiring
  `bcrypt_unix_call_funcs`.
- `crypt32_unixlib_ios.c`: 11.18 adds `unix_export_cert_store` (PFX export
  through `gnutls_pkcs12_*`), so the replacement's function tables fail
  their size assertion. It needs the new call, and the GnuTLS symbol table
  needs the new functions.

## 7. Step 6: the unixlibs and the link

Four unix-side pieces outside the seven replacements had to follow 11.18. The
port is `cb3d218` in the port's Madeira clone.

| Piece | 11.18 change | Resolution |
| --- | --- | --- |
| bcrypt | no unix library: bcrypt uses SymCrypt on the PE side, `dlls/bcrypt/gnutls.c` is gone, and its `Makefile.in` has no `UNIXLIB` | `build.sh` no longer compiles or archives `bcrypt_unixlib`; `virtual_ios.c`'s static unixlib lookup drops its `bcrypt` branch; `gen_gnutls_symtab.sh` scans only secur32 and crypt32 |
| crypt32 | `unix_export_cert_store` (PFX export through `gnutls_pkcs12_*` and `gnutls_x509_privkey_import_rsa_raw`) | upstream's `unixlib.c` diff applied to `crypt32_unixlib_ios.c` with `patch -F3`: 13 of 13 hunks, no fuzz. All six new GnuTLS functions are in `libgnutls.a`, so the regenerated symbol table (70 entries) has them |
| mmdevapi (`audio_null_ios.c`) | upstream a70f1eb8 and 4c3dd4e1: `main_loop` became `main_loop_start` and `main_loop_stop`, `timer_loop` was removed, and `release_stream_params` lost `timer_thread`. The driver now starts its own timer thread with `PsCreateSystemThread` at the first `start` | table entries 2 to 9 re-indexed (still 37, so no size check could catch it: entries 3 to 9 would have called the wrong function, and `release_stream` would have written its result over the old `timer_thread` slot). The two main-loop calls are no-ops, as in winecoreaudio. The 10 ms timer loop runs on a system thread made at the first `start` (upstream's `create_unix_thread`: time-critical priority, named `audio_client_timer`), which `release_stream` joins. A `_Static_assert` now ties the table to its count |
| ntdll `alpc.c` | new unit | added to `libntdll_unix.a`'s member list; without it the ALPC syscalls are unresolved |
| wineserver `alpc.c` | new unit, not replaced by Madeira | `unix-gaps.sh` rebuilds it from the tree with the other unpatched units when the tree has it |

`build/stages/unix-gaps.sh` now checks `bcrypt_unix_call_funcs` only when the
tree has `dlls/bcrypt/gnutls.c`, and rebuilds `server/alpc.c` only when it
exists, so the current wine-11.4 build is unchanged.

Checks, on the port root (`.work/port/wine/unix`, with `toolchains/gnutls-ios`
copied from `.work/run/unix`):

- `stages/unix.sh ROOT ntdll`: 31 of 31 units; `unix-gaps.sh ROOT
  gnutls-config`: secur32 and crypt32 tables defined.
- `stages/unix.sh ROOT win32u`, then `unix-gaps.sh ROOT wineserver linktest`:
  the same result as the current build's `run/logs/unix.log` (the plain
  `libwineserver.a` fails on the four known duplicate symbols; the `ws4` one
  links).
- The linked test binary's undefined symbols (left to `dynamic_lookup` or
  libSystem) match the current build's except `rewinddir`, a libc function
  11.18's `fd_ios.c` path now uses. A first run found `send_hardware_message`
  there: the port root's `libwin32u_unix.a` predated Step 2's fix, and a
  rebuild cleared it. ROOT must be an absolute path: Madeira's wineserver
  `build.sh` fails on a relative shims path.

## 8. Step 7: first IPA and first play

**The IPA.** No pin moves yet. The pipeline ran on a run directory
(`PLAYPORT_RUN=$PLAYPORT_BUILD/port/run`, `PLAYPORT_OUT=$PLAYPORT_BUILD/port/out`)
whose `unix` and `pe` are the port's trees (`$PLAYPORT_BUILD/port/wine/unix`,
`.../pe`) and whose `fex`, `dxmt-*` link to the current run's trees, with
`pp build --from stage`. The stage stage needed the prefix registry seed
regenerated (`pp registry`: 11.18's builtins register differently, 47 lines added
and 8 removed in `system.reg`); `verify-ipa.py` passed all 60 checks. The
records this rewrote (`app/artifacts.tsv`, `build/generated/wine-pe-*.tsv`,
`app/registry`) were put back afterwards: they belong to the pin move.

**The first play hung** after `sending init_first_thread`: no first frame
after 400 s. The wineserver's loop had stopped (its `POST iter` trace ended at
iteration 10), and a `WINE_HOST_SAMPLE` run showed the server thread at
100 % in `grab_object`, called from `receive_fd`. Upstream's
`create_thread` no longer links a new thread into its process
(`add_process_thread` is now the caller's job). Step 2 had made that change on
the accept path, but not on the iOS path for an injected client
(`master_socket_handle_client`). The first thread was therefore never on the
process's list, `get_process_first_thread()` returned NULL, and
`grab_object(NULL)` faulted. The fault did not crash the app: the server
thread kept faulting at the same instruction. The fix (`bfd46b3` in the
port's Madeira clone) calls `add_process_thread` there as upstream's accept
path does.

**The play.** IPA sha256
`4c7a895a818724d44553f0538ccede75e8a16115b2d2929a891d212f2a535c05` (dev).
`pp ui --play app-367520 --until first-frame+10`: JIT 3.71 s, game start
+3.76 s, first frame +10.64 s. The current build's run before it, on the same
phone, had its first frame at +10.18 s. At first-frame+10 the screen was still
black while the HUD showed 119.96 fps. A second play, at first-frame+45,
showed the main menu (the current build shows it by first-frame+10) at 65 fps
with a GPU time of 8.18 ms. That was the phone's fifth launch in 15 minutes,
so this is no performance comparison yet. The log has no protocol error and
no FATAL line.

## 9. Step 8: the pin move

The port is now what `pp build` builds from ([decision 0013](../decisions/0013-wine-on-upstream.md)):

- `pins.lock`: `wine` is WineHQ wine-11.18, commit `7b3fff76` (the tag object
  is `ccf4f04c`; a pin names the commit), from `gitlab.winehq.org/wine/wine`;
  the new `wine-port` row is Madeira's `723d1bf5`, which the `sources` stage
  checks against Madeira's `wine` gitlink.
- `patches/wine-port`: the 56 rebased commits, each with `Madeira-commit:`
  and `Rebased: clean` (49) or `resolved` (7, section 2), then the
  `is_ec_code` follow-up (section 6) as 0057. `patches/wine-unix` and
  `patches/wine-pe` are byte-for-byte unchanged: their patch-ids on the new
  base equal the committed files'.
- `patches/madeira-unix` 0020-0026: the replacement ports of sections 3-8,
  class `madeira-port` (`pp test`'s patch check now allows that class there).
- The `unix` and `pe` stages take Wine from a mirror in
  `$PLAYPORT_BUILD/cache/wine.git` (`mirror` in `build/lib.sh`, moved there
  from `stages/fex.sh`), apply `wine-port` first, and stamp both new inputs.
  `pp sync` treats `wine` like `fex`: never moved; a moved Madeira `wine`
  gitlink holds as `wine-port-moved`; `wine-unix` and `wine-pe` replay on
  top of `wine-port`. Its test fixture now shows the replay classes on
  Madeira's own code, the only component a sync still moves.

**A patch-id trap.** Madeira commit `18c256cd` (wine-port 0035) has a message
line starting with `diff `. `git patch-id` reads that line as the start of a
diff, so the patch file gave two ids and `check_series` never matched the
tree. `series_ids` now reads each patch file from its first `---` line.

**The build.** `pp build` from the pins (unix, pe, fex, dxmt rebuilt): 60 of
60 IPA checks. It rewrote `app/artifacts.tsv`, both
`build/generated/wine-pe-*.tsv` and `app/registry/system.reg` (`pp registry`;
the seed follows 11.18's builtins), committed with the move.

**The play.** IPA sha256
`966167bd6066cafc35461298beb9bec4e01f5b7c8387c90ede78cbd9f5f8c50e` (dev),
installed in place. `pp ui --play app-367520 --until first-frame+30 --shot`:
JIT 3.62 s, game start +3.66 s, first frame +8.79 s; the stop screenshot shows
the main menu with the HUD at 119.96 fps, GPU 6.72 ms, 2736x1260.

## 10. What is left

- **The device gate past the menu**: sound (the timer thread in section 7 is
  new), a play into the game, and a 10-minute run at 120 fps.
- **Merges that are clean but wrong.** The replacements were written against
  wine-11.4's layout and are built with `-Wno-implicit-function-declaration
  -Wno-int-conversion`; a stale call can still compile. The checks in
  sections 3-7 compared warnings and undefined symbols with the previous
  build, which catches renames but not changed semantics.

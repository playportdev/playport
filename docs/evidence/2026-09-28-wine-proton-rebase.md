# Wine from Valve's Proton branch: measured, and carried as a series

**Date:** 2026-09-28. **Plan:** [Wine from Valve's Proton branch](../plans/2026-09-27-wine-on-proton.md),
steps 0 to 6. **Pins read:** `wine` 7b3fff7 (WineHQ wine-11.18), `wine-port`
723d1bf, `madeira` 8c050d0; ValveSoftware/wine `proton_11.0` at `dc26e61847081a1b5cb0733dc30feba6ee575482`
(2026-08-03, the head when fetched). **Status:** done. Step 0 chose B: the base stays
WineHQ, and Valve's wanted commits become `patches/wine-valve`
([decision 0018](../decisions/0018-valve-wine-as-a-series.md)). The series
(125 commits, 115 after review dropped ten inert ones, section 5) builds, and
the IPA passes the phone gate (section 8): Hollow
Knight on DXMT and on Vulkan, the video case, and no regression in frame
times or first frame against the same tree without the series. Dev IPAs
`b2d13ae130c4d0c952ac9f53ce9eba2861c12fca9ae7b3b3e64b7b2d0097b1e8` (the
A/B) and `bf0aaa48789b26d2c4fc1f440ad87be99558b6df47829504050acaa6e5d50583`
(the branch rebased onto `origin/main`).

**Later:** the app sets Steam's game id since [decision 0020](../decisions/0020-steam-game-id.md),
so the ten `SteamGameId`-keyed picks review dropped (section 5) and the two
left out at the pick for the same reason are back in the series, 127 patches
([steam-game-id](2026-09-28-steam-game-id.md)). `valve-commits.tsv` has their
new verdicts; the counts below are the series as this record built it.

The files beside this record: `valve-commits.tsv` (all 1,453 of Valve's
commits with their verdicts, oldest first), the step-0 scripts
(`classify.py`, `choose_valve.py`, `trial.sh`, `trial_list.sh`) and the three
trial logs.

## 1. What `proton_11.0` is

`wine-11.0..proton_11.0` is 1,453 commits, no merges: Valve's branch is
WineHQ's wine-11.0 with Valve's commits rebased on top. wine-11.18, the
current base, is 18 development releases later. 342 of the 1,453 subjects
say `HACK`.

## 2. Step 0: Valve's commits by class

`classify.py` tags each commit, and the primary class is the first tag in
the table's order. A commit is `upstream` when wine-11.18 has it: the same
stable patch-id, a `cherry picked from` line naming a commit of
`wine-11.0..wine-11.18`, or the same subject there. The replaced files are the
22 Wine sources Madeira's `*_ios.c` replacements take the place of
(`dlls/ntdll/unix/{loader,process,server,env,virtual,signal_arm64,thread,cdrom}.c`,
`dlls/win32u/{class,winstation,sysparams,defwnd,driver,message,freetype}.c`,
`server/{request,main,mach,unicode,fd,window,mapping,queue}.c`,
`dlls/dwrite/freetype.c`, `dlls/crypt32/unixlib.c`).

| Class (plan step 0.1) | Commits | Lines |
| --- | --- | --- |
| already in wine-11.18 (backports) | 395 | 305,387 |
| fsync and ntsync | 15 | 2,059 |
| winex11, winewayland, winebus (evdev, hidraw), pulse, media-converter: unused | 130 | 4,743 |
| ARM64EC and FEX | 29 | 1,042 |
| changes to files the replacements override | 124 | 5,368 |
| winegstreamer | 77 | 7,069 |
| other unix-side changes | 52 | 5,354 |
| the rest, PE side | 631 | 212,253 |

The PE-side line count is dominated by generated files: Valve's branch
deletes `configure` (25,834 lines) and winevulkan's generated code
(99,551), and adds vk.xml (34,539).

**The hand-port class** (plan step 0.2): 152 commits that are not backports
change at least one replaced file, 3,306 lines in those files. 75 of them are
`HACK`s. Most are Linux or Steam client work: `WINESTEAMNOEXEC` and other
`SteamGameId` switches in `loader.c` (59 commits touch it), gamescope and
fshack display modes in `sysparams.c`, touch and pointer input in
`queue.c`, `defwnd.c` and `message.c`, fsync options, gpuvis and GDB link
maps. A few are general: `Force virtual memory allocation order` (402 lines
of `virtual.c`), `Exclude natively mapped areas from free areas list`,
`NtSetInformationProcess( ProcessTlsInformation )`,
`Wait for thread suspension in NtSuspendThread()`. Going to A, the
replacements would also have to move back from wine-11.18 to wine-11.0 first:
upstream changed those 22 files by 3,709 insertions and 2,906 deletions
between the two (`git diff --shortstat wine-11.0 wine-11.18 -- FILES`).

**The ARM64EC and FEX class** (plan step 0.2):

- 9 are backports wine-11.18 has (227 lines): ARM64EC cooperative suspend
  (`e4054376336`), the synthesized caller context in `RtlRaiseException`
  (`fe2a1b0215b`), `capture_context` for non-EC callers (`12bd94e739f`),
  `BTCpuNotifyProcessExecuteFlagsChange` (`8fa2c47eb36`), cooperative suspend
  for syscall callbacks and `NtContinue` in them (`2d371454032`,
  `05c1b2a2001`, `086e1971f27`), `RtlVirtualUnwind2` fault catching
  (`ac9b4f69d65`) and the 32-bit ARM architecture list (`ab182d6f28a`).
- 10 are five commits and their reverts in Valve's own tree (410 lines):
  Asahi TSO, kernel-side unaligned atomics, the FEX stats shm, a WIP ARM64EC
  suspend (replaced by `e4054376336`) and a `RtlVirtualUnwind2` page-fault
  handler (replaced by `ac9b4f69d65`).
- 18 are Valve's own (631 lines). Section 4 says what became of each.

**The trial rebase** (plan step 0.3), `trial.sh`, which cherry-picks each
commit and on a conflict counts the files and hunks and then takes the
picked side to go on:

| Series onto `proton_11.0` | Commits | Conflicting | Hunks |
| --- | --- | --- | --- |
| `patches/wine-port` as it applies to wine-11.18 (57) | 57 | 10 | 22 |
| Madeira's `madeira-lgpl` originals on wine-11.4 (56) | 56 | 8 | 13 |

The conflicts are the same places the 0013 rebase met going up
(`server/winstation.c`, `unix/sync.c`, `signal_arm64ec.c`,
`server/event.c`/`handle.c`, `unix/system.c`, `xinput1_3/main.c`) plus
`unixlib.h`, `loader.c`, `server/thread.c` and `server/inproc_sync.c`. Git
counts only what it can see: the port series compiles against 11.18's
`struct thread_data` and `main_module`, which 11.0 does not have.

## 3. The checkpoint: B

The plan's rule: A when the replacement class is small and the ARM64EC and
FEX work depends on the rest of Valve's tree, otherwise B.

- The replacement class is not small: 152 commits, 3,306 lines to carry by
  hand, after porting the replacements back across 6,615 changed lines.
- The ARM64EC and FEX work does not depend on Valve's tree: the parts the
  plan names are backports wine-11.18 already has. Of Valve's own 18, three
  change replaced files; of the other 15, 11 cherry-pick onto wine-11.18
  plus `patches/wine-port` cleanly (`trial_list.sh`). Two conflict on newer
  text of upstream's and Madeira's (the Wine Mono version, the ARM64EC
  dispatcher and Madeira's probes in it), and two only on context that
  other Valve commits added (a `services.exe` list of variables to keep, a
  declaration in `wow64`). None needs the rest of Valve's tree to work.

So B: WineHQ stays the base and the wanted commits become
`patches/wine-valve`, on wine-11.18, the `wine` pin unchanged.

## 4. The series: which commits

`choose_valve.py` gives each commit one verdict, in this order (counts after
the picks of section 5):

| Verdict | Commits | Why left out |
| --- | --- | --- |
| upstream | 395 | wine-11.18 has it |
| proton | 258 | Steam client, Proton integration, launchers and anti-cheat, VR, gamescope, fshack and OpenGL, AMD and NVIDIA GPU spoofing (`amd_ags_x64`, `atiadlxx`), speech (`windows.media.speech`, `protontts`), winevulkan's generated code |
| media | 183 | Media Foundation, DirectShow, winegstreamer and winedmo: Playport keeps its own video work ([hk-video](2026-09-26-hk-video.md)) |
| replaced | 127 | changes a file an `*_ios.c` replacement overrides (the rest of the 152 are in earlier verdicts) |
| taken | 115 | the series |
| unused | 114 | winex11, winewayland, winebus, hidclass, pulse, opengl32; dinput's HID joystick mapping; setupapi's winebus presence |
| inert | 77 | does nothing in this runtime: `wine.inf` (the app never runs it), wineboot, `services.exe`, Wine Mono and Wine Gecko hacks (neither ships), the package repository, hacks keyed on `SteamGameId` (the app does not set it) |
| unix-side | 55 | unix code outside the replacements, including win32u (the plan's wanted classes are PE-side) |
| reverted | 25 | reverted in Valve's own tree |
| d3dx | 25 | upstream's own d3dx9/10/11 texture work (48 commits since 11.0) overlaps Valve's backport of it; 17 of these 25 conflict |
| sync | 15 | fsync, ntsync |
| left out at the pick | 14 | section 5 |
| build | 10 | configure, makedep, generated files |
| tests | 10 | tests only |
| wow64 | 9 | 32-bit guests, which are not built |
| fixup | 9 | the target is left out |
| other | 12 | bcrypt's GnuTLS backend (gone in 11.18), Madeira's own xinput and TLS work, and the ARM64EC and FEX commits below |

What the plan asked to check, and what came of it:

- **fsync and ntsync stay out.** None of the 15 fsync/ntsync commits is
  taken, and `inproc_sync` keeps wine-11.18's code. Madeira's userspace
  ntsync (`madsync`, opt-in since `patches/madeira-unix` 0014) is what the
  iOS build has; no `futex_waitv` or `/dev/ntsync` probe is added.
- **FEX's DLL names.** Valve's `a98b4d5e8e7` and its fixup make Wine load
  FEX as `libarm64ecfex.dll` (`Wow64\amd64` in `wine.inf`, and
  `load_arm64ec_module`). `build/stages/fex.sh` builds `libarm64ecfex.dll`,
  and `stage-artifacts.py` ships it as `xtajit64.dll`, the name Windows and
  upstream Wine use, which twelve `patches/wine-port` patches and the app's
  JIT-pool code name. Not taken.
- **Wine Mono.** `469a9fea3d1` ("HACK: Use x86 mono on aarch64") changes
  `#elif defined(__x86_64__)` to also match `__aarch64__`. llvm-mingw's
  arm64ec target defines `__x86_64__` and not `__aarch64__` (`clang
  --target=arm64ec-w64-mingw32 -dM -E`), so the `mscoree.dll` an x86-64 game
  loads already picks the x86 Wine Mono (`libmono-2.0-x86_64.dll`); the HACK
  would only move the aarch64 build off the arm64 Wine Mono 11.3.0 that
  wine-11.18 added. The app ships no Wine Mono yet. Not taken.
- **AVX and SVE.** `626cd7ace63` makes the ARM64EC exception, APC and
  thread-start frames room for an `XSTATE` context (0x4d0 to 0xcd0 bytes) and
  copies the upper YMM halves when FEX sets `CONTEXT_ARM64_FEX_YMMSTATE`.
  FEX sets that flag only when it reports AVX2, and on iOS it reports no AVX:
  `patches/fex-port` 0009 builds `HostFeatures` by hand and leaves
  `SupportsAVX` false. The commit would still advertise AVX in the shared
  `XState` while CPUID denies it. `579584c8cf7` (SVE xstate headers) and
  `2a8c650fb47` (the SVE predicate register, in `signal_arm64.c`) are for
  SVE hosts; Apple CPUs have none. Not taken.
- **Other ARM64EC and FEX commits.** The six WoW64 suspend commits are for
  32-bit guests; `8d813e09b87` (FEX's TSC scaling) is in wineboot and
  `1b8936d2834` (FEX's environment variables) in `services.exe`, neither of
  which the app runs; `b130f25d66f` is `configure.ac`; `b24ecb4824a` works
  around LLVM issue 101355 for older toolchains, and Madeira's ARM64EC build
  runs without it on llvm-mingw's LLVM 23; `a260f8bc13c` and `96666ae3beb`
  change replaced files. None taken.
- **winegstreamer.** Playport's Media Foundation video work stays on
  wine-11.18 as it is (`patches/wine-unix` 0005, `patches/wine-pe` 0008,
  `patches/madeira-unix` 0031); none of Valve's 115 winegstreamer commits
  or the rest of its media stack is taken, so there is nothing to re-port.

## 5. The picks

`git cherry-pick -x` of the 139 chosen commits, in Valve's order, onto
wine-11.18 plus `patches/wine-port` (`merge.conflictstyle=zdiff3`), each
conflict read on both sides:

- 118 applied cleanly, 12 needed resolving, and 9 conflicted and were left
  out.
- Each clean pick was checked against its original, as AGENTS.md asks of
  auto-merged hunks. Of the 103 clean picks in the series, 99 carry
  Valve's diff unchanged (the same stable patch-id). In the other 4
  (`91493b40ba5`, `9af7641cb65`, `efd72a829c7`, `6d993a3a5f8`), only
  context lines and offsets differ; the added and removed lines are
  Valve's.
- The 12 resolved (`Picked: resolved`):

| Valve commit | Conflict | Resolution |
| --- | --- | --- |
| `35c974f49b4` Disable 16-bit TIB hack | upstream reworked `RtlSetCurrentDirectory_U` (a same-directory early return, the TIB check moved down) | the `0 &&` applied to the moved check |
| `12e7d48882a` winedbg: dump crash info to stderr | `dbg_process_list` is no longer static | the new flag beside it |
| `39e7eed749a` webservices: Prefer native | upstream added version-resource lines to `Makefile.in` | both |
| `fadcf28ba20` winhttp: connect end checks out of the loop | `netconn_verify_cert` takes the chain now (`f27d14a2`) | Valve's restructure, passing `&conn->chain` |
| `095fdddb5e1` xaudio2: Prefer native | version-resource lines, three `Makefile.in` | both |
| `baf7cf6aec6` `WINE_HEAP_DELAY_FREE` | it reworks the `SteamGameId` mfc42 hack (`ee597bb9541`), which is left out | its `get_env` and `loader_init` check, without the mfc42 hunk |
| `89d7ee5f985` mmdevapi: round `min_period_frames` up | upstream computes the periods with `MulDiv` | upstream's default; the minimum rounded up and the default bounded by it, as Valve's |
| `b6f7c600d36` msctf: a list of thread managers | upstream's `ITfFnReconversion` stub (`605b5772`) sits where `TF_GetThreadMgr` moves to | both |
| `bd7e90c83fd`, `486fe0fb0ed` mmdevapi: `VT_BOOL`, `VT_CLSID` properties | upstream's propstore tests differ | the code; the test hunks left out |
| `06e63ed967a` user32: `SkipPointerFrameMessages` stub | upstream's new pointer-frame functions | both |
| `4c175582270` ddraw: ignore the hwnd clipper in exclusive fullscreen | upstream's ddraw tests differ | the code; the test hunks left out |

- 14 were left out at the pick (`valve-commits.tsv` says why). The 9 that
  conflicted: upstream has the same fix or a newer one (`eda0a9bf629`
  `GetPointerType`, `e415577be81` `_isatty`, `4dd6a640f97`
  `GetPointerInfoHistory`, `17f7a76dc56` `ITfFnReconversion`,
  `acd2f9f92fd` `ImeSetCompositionString`); keyed on `SteamGameId`, which the
  app does not set (`a20b0e65ebe`, `c7e869c1f61`); a fix to the left-out
  lsteamclient import override (`7c37252819e`); the Wine Mono HACK
  (section 4). And 5 that applied cleanly: `8e3cb561e12` added a second
  `GetPointerDevice` beside the stub Madeira's fork already has (found by
  reading the spec file); the ucrtbase search HACK and its fixup
  (`d9e1c67bc93`, `49f6a0c6a6e`), which Valve's own fixup compiles out on
  arm64ec and aarch64; `a0a6df09f50`, a `PdhGetFormattedCounterArray` stub
  that wine-11.18 already implements (the first build failed on the second
  definition); and `8f5a9799232`, which makes ntdll re-protect a table in its
  own image (a new `.mrdata` section) at every module load, for software that
  walks that table. On iOS ntdll's image is under Madeira's JIT-pool
  mappings, and no title in the cohort reads the table.
- 10 clean picks were dropped after review, because they are keyed on
  `SteamGameId`, which the app does not set: `3b4421a7703` (gdiplus,
  SpriteFontX), `70409daaac8` (advapi32, DeathLoop), `2b1f2b43060` and
  `16b8cdb5a96` (msvcrt, Indiana Jones and DarkStar One), `a677f27c228`
  (rsaenh, SF6), `318c31b48ae` (user32, Skyrim SE), `a814afa8315` (d2d1,
  Spell Force 3), `19c6f062639` (ddraw, e-Racer), `c6a17f3d62a` (d3d8, STAR
  WARS Starfighter) and `1994def5d44` (kernelbase `WINE_SHRINK_ENV`, which
  defaults to a `SteamGameId` and otherwise strips only Linux and
  Steam-runtime variables). `valve-commits.tsv` had them as `inert` (back since
  [decision 0020](../decisions/0020-steam-game-id.md)). The
  other 115 still apply in order, and `patches/wine-unix` and
  `patches/wine-pe` on top. The builds and the phone gate of sections 7 and
  8 are of the 125.

`patches/wine-valve` is the 115, written with `git format-patch -N
--zero-commit --no-signature` and given `Valve-commit:`, `Picked:`, `Class:
valve`, `Evidence:` and `Offered-upstream:` trailers (the `-x` line
removed). It changes 124 files, 2,611 lines in and 320 out, all PE side
apart from two headers (`include/msxml6.idl`, `include/wine/strmbase.h`) and
one line of secur32's unix side, `schannel_gnutls.c`, which Madeira's build
compiles into `libntdll_unix.a`: `cb50ee2f255` adds
`%NO_SHUFFLE_EXTENSIONS` to the GnuTLS priority string, the workaround for a
handshake bug in GnuTLS 3.8.9, the version Playport links. By
component: kernelbase (34 commits, most of them command-line switches for
Chromium-based launchers, keyed on the executable's path), ntdll PE (9: heap
options, LFH, the 16-bit TIB, `__wine_unix_call`, x64 debug registers), user32,
msxml3, winhttp and secur32 (TLS renegotiation), wined3d, ddraw, dmime,
mmdevapi, msctf, the xaudio2 family (prefer native), msi, dwmapi and
others.

`patches/wine-unix` (5) and `patches/wine-pe` (8) apply unchanged on top of
`wine-port` plus `wine-valve`.

## 6. Tooling and records

- `pins.lock`: a `wine-valve` row (the `proton_11.0` commit the series was
  picked from); `wine` and `wine-port` unchanged.
- `build/stages/unix.sh` and `build/stages/wine-pe.sh` apply `wine-port
  wine-valve` and then `wine-unix` or `wine-pe`; `build/pipeline` puts the
  new row and series into the `unix` and `pe` digests.
- `tools/checks.py`: class `valve`, only in `patches/wine-valve`, whose
  patches must also have `Valve-commit:` and `Picked:`.
- `tools/sync.py`: `wine-valve` is a Wine series, replayed on `wine-port`,
  and `wine-unix` and `wine-pe` replay on both; the fixture has a
  `wine-valve` patch between them.
- Decision [0018](../decisions/0018-valve-wine-as-a-series.md); AGENTS.md
  (pins), ARCHITECTURE.md (patch series, the Wine rows), UPSTREAM-SYNC.md,
  LICENSING.md, NOTICES.md, DISTRIBUTION.md and the `pins.lock` comment.

## 7. Build

In this worktree's fresh build area, so every tree was built from its pin,
as `pp build --clean` would.

- **First build** (127 patches): `make -k` failed in `dlls/pdh` in both
  trees, `redefinition of 'PdhGetFormattedCounterArrayW'`: wine-11.18
  implements what Valve's `a0a6df09f50` stubs. That commit, and
  `8f5a9799232` (section 5), were dropped.
- **The series build** (125 patches): `make build-macos exit=0; make
  build-arm64ec exit=0`, both PE machine checks pass, and `verify-ipa.py`
  passes all 66 checks. Dev IPA
  `b2d13ae130c4d0c952ac9f53ce9eba2861c12fca9ae7b3b3e64b7b2d0097b1e8`. A
  later rebuild of the same tree gave the same unix archives, byte for byte.
- **The baseline**: the same tree without `patches/wine-valve` (origin/main
  `96fa472`'s build scripts), for the A/B of section 8. Dev IPA
  `e68fa94df42baf524021e42c5db1422127022a396eb59a5a8a1bddac96d98c69`, 66
  checks.
- **What changed between them.** `libwin32u_unix.a`, `libwineserver.a`,
  `libwinegstreamer_unix.a` and `libdxmt_combined.a` are byte-identical. In
  `libntdll_unix.a` one of 34 members differs, `secur32_unixlib.o` (the
  GnuTLS priority string). The aarch64-windows and arm64ec-windows PE sets
  hold the same files as the committed manifests; the DLLs the series
  touches differ in content.
- **The committed records** (`app/artifacts.tsv`,
  `build/generated/wine-pe-*.tsv`) are not in this change: Wine PE and DXMT
  hash their build directory, so only a build in the main checkout's
  `.work/run` records rows anyone commits (AGENTS.md, "Committed build
  records"). This build's are beside its IPA (`out/…/records/`). The first
  main-checkout build after the merge rewrites them, and they are committed
  then.

## 8. Phone gate

**Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi, on
battery (67 % to 57 % across the perf runs), shared with other agents'
sessions between these. **IPAs:** the series build `b2d13ae1…` and the
baseline `e68fa94d…` (section 7), each installed in place for its runs. Run
directories are in this worktree's `$PLAYPORT_BUILD` (`ui-runs/`,
`perf-ab/`).

### 8.1 Plays on the series IPA

| Run | What | Timeline | At the stop |
| --- | --- | --- | --- |
| `ui-runs/20260928T021646` | DXMT (`--settings 'app-367520:{}'`), `--until first-frame+10 --shot` | JIT 3.02 s, game start +3.63 s, first frame +8.77 s | the main menu, HUD 101 FPS, GPU 6.01 ms, `DXMT D3D11 FL_11_1` |
| `ui-runs/20260928T021729` | the Vulkan backend (`{"graphics":"vulkan"}`), the same | first frame +9.99 s | the main menu fading in, HUD `Metal 4`, 99 FPS, GPU 5.64 ms, no DXMT tag |
| `ui-runs/20260928T022130` | [hk-video](2026-09-26-hk-video.md)'s case: a New Game on profile 4 (empty), then no presses | first frame +9.29 s | see below |

The video case: after the slot, the prologue poem, then the opening
cinematic with the right colours at the clip's rate (HUD 25.03 FPS, frame
interval 39.94 ms, GPU 8.47 ms), then King's Pass with the Knight in
control. The calibration screens did not appear this time, so the two
steps meant for them landed on the poem and skipped nothing.
`s1-host.log` has winegstreamer's unixlib
(`winegstreamer_unix_call_funcs`) and no `_wassert`,
`NtTerminateProcess`, `WindowsVideoMedia error`, `STATUS_NO_MEMORY` or `HOST
MAP FAILED`. The app was ended in King's Pass before the game saved, so
profile 4 is still empty. Profile 1 was loaded once afterwards, so the
profile screen's cursor is back on the slot `hk-new-game` expects.

### 8.2 Frame times: `pp perf`

The plan's `pp perf --secs 180 --pad first-frame+25:hk-new-game`, with
`--settings '{}' --cool 5 --shot first-frame+60`, alternating the two IPAs.
The [11.18 baseline record](2026-09-26-hk-native-baseline-wine-11.18.md)
is not the comparison: its IPA predates `patches/madeira-unix` 0027 (Mono's
trampoline, the main thread from 175 to 22 Mi/f) and later changes. The
baseline here is the same wine-11.18 tree without the series, built the same
way and played on the same phone in the same hour. `hk-new-game` lands in
profile 1's save (Dirtmouth).

| Run | IPA | Thermal at start | FPS mean | p10 | median | frame ms | GPU ms | main thread in play | all threads in play |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `valve-1` | series | serious | 82.1 | 58.3 | 76.4 | 12.00 | 9.14 | 19.41 Mi/f | 61.9 Mi/f |
| `base-1` | baseline | nominal | 90.7 | 72.2 | 83.4 | 10.88 | 8.74 | 18.70 Mi/f | 59.3 Mi/f |
| `valve-2` | series | nominal | 90.8 | 72.7 | 82.7 | 10.85 | 8.52 | 18.94 Mi/f | 60.3 Mi/f |
| `base-2` | baseline | nominal | 90.8 | 71.5 | 82.4 | 10.85 | 8.39 | 18.85 Mi/f | 60.1 Mi/f |

`valve-1` started hot (other sessions had just run; its `--cool` had no
earlier run of this build area to wait on), and the P cores were parked for
most of its play, so it does not compare. From a nominal start, the series'
frame times equal the baseline's: 10.85 ms against 10.88 and 10.85, and the
main thread's work per frame in play is the same within 1 %. The per-30-s
frame rates track each other (`pp perf --compare`).

### 8.3 First frame

The perf runs put the series' first frame about a second later
(`valve-2` +10.05 s against +9.26 and +9.22 s), so the first frame was
measured again with plays to `first-frame+3`, the IPAs alternated (`B V V B
B V`, then `V V B B` twice), plus every play above. Hollow Knight's start
has two modes. The main thread works for about 3 s after the game starts and
then waits for Unity's loading thread (`Loading.PreloadManager`), and the
first frame comes when that thread finishes. In one mode the loading thread
does about 12 G instructions, in the other about 24 G (the same work rate,
for about a second longer), and the whole start from game start to first
frame about 73 G or 81 to 89 G. The mode changes from run to run on both IPAs:

| IPA | Plays | Long-load mode | First frame, all | First frame, short mode | First frame, long mode |
| --- | --- | --- | --- | --- | --- |
| series | 13 | 8 | 9.96 ± 0.61 s | 9.32 ± 0.35 s (n=5) | 10.36 ± 0.30 s (n=8) |
| baseline | 12 | 8 | 9.85 ± 0.53 s | 9.23 ± 0.30 s (n=4) | 10.16 ± 0.28 s (n=8) |

(Mean ± standard deviation. The Vulkan play is left out; the video and
profile-screen plays are in, since their input comes after the first frame.)
The difference, +0.11 s, is half its standard error (0.23 s). In the short
mode the start costs the same instructions on both (73.4 G and 73.6 G). The
first eight runs had made it look like a regression: the series happened to
hit the long mode in 6 of its first 8 plays and the baseline in 0 of its
first 3. A build without the one heap commit in the series
(`91d72984d6b`, LFH block groups) was tested as a suspect, since the
loading thread is in Mono: it showed both modes too (2 of 4 long), so the
commit stayed. The first frame does not get worse.

### 8.4 The branch's IPA

After the A/B the build area was rebuilt from the branch (the series
unchanged since `b2d13ae1`), and again after the branch was rebased onto
`origin/main` `d3a2916` (two app and documentation commits; no Wine tree
changed, so only the app was rebuilt). Rebuilds of the same trees give the
same unix archives and staged runtime; the IPAs differ only in the app and
its signature. Dev IPA
`bf0aaa48789b26d2c4fc1f440ad87be99558b6df47829504050acaa6e5d50583`, 66
checks, installed in place: `pp ui --play app-367520 --until first-frame+10
--shot` (`ui-runs/20260928T034333`) has JIT 3.20 s, game start +3.88 s,
first frame +9.32 s, and the main menu at 101.4 FPS, GPU 6.05 ms, on DXMT.
The rebuild before the rebase (`2c7ebc27…`, `ui-runs/20260928T033926`)
reached its first frame at +9.42 s.

So the series passes the plan's bar: Hollow Knight reaches its menu on DXMT
and on Vulkan, the video case plays, and neither the frame times nor the
first frame are worse than the same tree without it.

## 9. Work log

- 01:27 worktree, build area linked (`.work/inputs`, `.work/cache`).
- 01:30 `proton_11.0` fetched into a scratch clone whose objects are the
  cache mirror's (alternates, read only); head `dc26e61`, as the plan read it.
- 01:31 to 01:38 step 0: classes, lines, both trial rebases. Checkpoint B.
- 01:38 to 01:44 the picks (section 5), `wine-unix` and `wine-pe` on top.
- 01:45 series written, tooling changed, first build started.
- 02:06 first IPA (127 patches): pdh failed to build; two commits dropped.
- 02:14 the series IPA `b2d13ae1`; 02:16 to 02:27 the DXMT, Vulkan and video
  plays (8.1); 02:27 the baseline IPA `e68fa94d`.
- 02:28 to 02:59 the four perf runs (8.2).
- 02:59 to 03:32 the first-frame plays, the no-LFH build `36003e7e` and its
  plays (8.3).
- 03:37 the branch's IPA `2c7ebc27` and its play; 03:42 rebased onto
  `origin/main`, IPA `bf0aaa48` and its play (8.4). `pp test`, `pp names`
  and `pp secrets` pass.

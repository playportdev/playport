# Every dependency to its latest version (alignment plan, step 1)

**Date:** 2026-10-05. **Plan:** [Proton ARM64 alignment](../plans/2026-10-05-proton-arm64-alignment.md),
step 1 (rows 2–10), under decision [0049](../decisions/0049-latest-pins.md).
**Kind:** build records for one move per commit. The phone was away (the
owner's) from 14:14: by the owner's direction each move is built and tested
on the workstation and committed with its IPA, and the gate plays and
`pp perf` runs are made later on these IPAs, in order, so that a regression
can be bisected.

## Baseline (before any move)

- Commit `e71e8a7` (decision 0049, no pin change), dev IPA
  `.work/out/20261005-140757-b1c15122/Playport-26.5-b1c15122.ipa`, SHA256
  `b1c1512228c25d16a0e08860ad878bde053f04378630d35d6359ec54958803f3`.
- Gate, one locked session (`pp install --no-build`, then both plays):
  - Hollow Knight (`app-367520`), `.work/ui-runs/20261005T140831`: JIT after
    2.39 s, first frame at +9.48 s, ran on to `first-frame+10`; the screenshot
    shows the main menu.
  - Portal 2 (`app-620`), `.work/ui-runs/20261005T140921`: JIT after 2.42 s,
    first frame at +5.46 s (as in the 2026-10-04 records, 5.6–5.7 s), ran on to
    `first-frame+10`; the screenshot is black (the game's start, before its
    menu, as at that point in earlier runs).
- `pp perf` before (both routes): **pending: phone away.** The Hollow Knight
  run (`dl0-base-hk`) was stopped in its cooldown wait before it measured.

## The moves

One row per dependency. Valve's columns are the 2026-10-05 snapshot in the
plan (stable `proton_11.0` / experimental / bleeding-edge).

| Row | Old pin | New pin | Latest upstream | Valve stable / experimental / bleeding-edge | Build, `pp test` | Gate | `pp perf` |
|---|---|---|---|---|---|---|---|
| `wine` | wine-11.18 `7b3fff7` | wine-11.19 `455e350` | wine-11.19 (2026-10-02; no later tag) | Valve Wine `dc26e61` / `6d211aa` / `750fd01` | passed | pending: phone away | pending: phone away |
| `fex` + `rpmalloc` | FEX-2609.1 `9fbdc00`; rpmalloc `09142d7` | `main` `3648ee9`; rpmalloc `09142d7` (unchanged: main's `External/rpmalloc`) | `main` `3648ee9` (2026-10-02, the head on 2026-10-05 14:34) | FEX-2607 `1cc4b93` / main `0df84d3` / main `3648ee9` | passed | pending: phone away | pending: phone away |
| `dxmt` | `7c8dee1` | `main` `68af85e` | `main` `68af85e` (16 commits ahead) | not used by Valve | passed; `pp slots` clean | pending: phone away | pending: phone away |
| `mesa` | `82d4f86` | `main` `b39d173` | `main` `b39d173` (2026-10-05 09:42 UTC, 369 commits ahead) | not comparable (Valve uses the Linux drivers) | passed; KosmicKrisp host test passed | pending: phone away | pending: phone away |
| `dxvk` | `52fe923` | `master` `e5ffd0f` | `master` `e5ffd0f` (2026-10-05 10:53 UTC, 18 commits ahead) | `a676404` / `6853015` / `d30be2b` (bleeding-edge is one commit behind: `e5ffd0f` "Disable present timing by default") | passed | pending: phone away | pending: phone away |
| `vkd3d-proton` | `472989a` | `master` `31d1f89` | `master` `31d1f89` (2026-10-02, 20 commits ahead) | `212991f` / `44cf7c2` / `31d1f89` (bleeding-edge = the head) | passed | pending: phone away | pending: phone away |
| `wine-valve` | `dc26e61` (`proton_11.0`) | `750fd01` (`bleeding-edge`) | bleeding-edge `750fd01` (2026-10-03; `proton_11.0` plus 409 commits) | `dc26e61` / `6d211aa` / `750fd01` | passed | pending: phone away | pending: phone away |

## IPAs, in order

Each IPA is a dev build of exactly its commit (a clean tree), kept in its
`out/` directory for the plays and a bisection.

| Step | Commit | IPA | SHA256 |
|---|---|---|---|
| baseline | `e71e8a7` | `.work/out/20261005-140757-b1c15122/Playport-26.5-b1c15122.ipa` | `b1c1512228c25d16a0e08860ad878bde053f04378630d35d6359ec54958803f3` |
| wine-11.19 | `7d0f5b3` | `.work/out/20261005-143326-b047db1e/Playport-26.5-b047db1e.ipa` | `b047db1e9d16d1405732f6230513f20c47832d7da7a29825e0725ef80a6c89da` |
| FEX main | `22ac169` | `.work/out/20261005-143851-8f671fd2/Playport-26.5-8f671fd2.ipa` | `8f671fd208fb0521204df33f2ba5aa0aa5b63dbd1209e0fa7051091adea2e872` |
| DXMT main | `2cd6d80` | `.work/out/20261005-144347-96b9b196/Playport-26.5-96b9b196.ipa` | `96b9b196ce4c5e90a2357e6e2636d2c9fef78ab66f04d35b211cb2af1ebd7b7a` |
| Mesa main | `6d09073` | `.work/out/20261005-144853-492712d6/Playport-26.5-492712d6.ipa` | `492712d6fa6d702c700b06054e5980f21b0aca7560550efb81d6112946e20157` |
| DXVK master | `cf020cb` | `.work/out/20261005-145319-543f20f6/Playport-26.5-543f20f6.ipa` | `543f20f6d232997cc4a5e71728fc2ce0b6d343d521ffdb41e05eb8bc330ede29` |
| vkd3d-proton master | `c6b8936` | `.work/out/20261005-145755-c85a8ec2/Playport-26.5-c85a8ec2.ipa` | `c85a8ec2f299c73ff5bee1e5ebe6d16096a07bd323af58eb11e383c4f30fdd08` |

## wine → wine-11.19

- **Distance:** 353 WineHQ commits, `wine-11.18..wine-11.19` (`455e3509b98a`).
- **Trial** (`pp rebase wine-pe|wine-unix 455e3509 --trial`): wine-pe stack
  211 patches, 210 clean, 1 conflict; wine-unix stack 198 patches, 197 clean,
  1 conflict. No 3-way merge, nothing upstream.
- **Resolution (one):** `wine-port/0031` (Crashpad-VEH context guard), in
  `dlls/ntdll/signal_arm64ec.c`'s syscall table. Upstream added
  `NtOpenPrivateNamespace` after `NtOpenMutant` (`3f65f20`) and made
  `NtReleaseSemaphore`'s count signed (`f89a7ca`); the patch wraps
  `NtOpenMutant` and `NtReleaseMutant`. Kept both: the patch's
  `DEFINE_WRAPPED_SYSCALL` lines with upstream's new and changed lines. The
  wine-unix run replayed it by rerere; its tree and exported series are the
  same as wine-pe's. Its trailer is now `Rebased: resolved`.
- **Range-diff flags:** only `wine-port/0031`, the resolution above (checked:
  the two added or changed upstream lines and nothing else). No clean patch
  changed. `wine-valve` replayed clean (127 patches).
- **The replacements** (Madeira's `*_ios.c`, built against these Wine
  headers): 7 WineHQ commits in 11.18..11.19 touch the files they override;
  the server protocol did not change. `madeira-unix/0080` (class
  `madeira-port`) carries three into them:
  - `b28fa1c` (`pImeToAsciiEx` takes the IME update pointer, `gdi_driver.h`):
    `driver_ios.c`'s null and loader drivers; needed to compile;
  - `0998bfa` (a zero group affinity is the whole group): `thread_ios.c`;
  - `4e819f0` (hardware messages mergeable): `queue_ios.c`.
  `f59c425` (win32u `freetype.c`) comes in through `freetype_ios.c`'s
  `#include`. **Not carried:** the three `virtual.c` commits (`76159fc` the
  first thread data below 16 GiB, `4c18d96` a top-down reserve, `5285712`
  the 64-bit virtual heap from `mmap`). They change the Linux preloader's
  address layout; `virtual_ios.c` places the first thread data, the reserves
  and the virtual heap for iOS itself (the 4 GiB `__PAGEZERO`, the arena and
  the guest band), so carrying them is a separate change for the phone.
- **Build:** the `unix`, `pe`, `dxmt` and `vulkan` stages ran; the three
  `wine-pe-*.tsv` manifests and `app/artifacts.tsv` changed, and the prefix
  registry seed gained one key (`app/registry/system.reg`, `pp registry`).
  `pp test`: all passed.
- **Open question 5** (does wine-11.19's wow64 consume `ChpeV2CpuAreaInfo` as
  FEX `af04940` assumes): WineHQ's `dlls/wow64` does not read it at all. The
  consumer is ntdll's unix side: `signal_arm64.c`'s suspend doorbell
  (`SuspendDoorbell` with `InSimulation`/`InSyscallCallback`) and the thread
  context code, which take the TEB's pointer whoever set it — the premise of
  `af04940`. Neither changed between 11.18 and 11.19. On Playport that code is
  Madeira's `signal_arm64_ios.c` (which has the doorbell path) and
  `thread_ios.c`; whether they behave as WineHQ's for a WoW64 thread's CPU
  area is what the FEX move's Portal 2 play shows.

## fex + rpmalloc → FEX main

- **Distance:** 145 FEX commits in `9fbdc00..3648ee9`. `main` does not descend
  from the FEX-2609.1 tag (merge base `395b132`, "Docs: Update for release
  FEX-2609"; the tag has 3 commits of its own). Re-fetched before landing: the
  head had not moved. FEX `main`'s `External/rpmalloc` is `09142d7`, the
  rpmalloc pin, so `rpmalloc` and `rpmalloc-port` do not move. `main` moves
  the `vixl` and `Vulkan-Headers` submodules; `build/stages/fex.sh` now clones
  the FEX tree again when it lacks the pin (commit `8dd5f31`), so they move
  with it.
- **Trial** (`pp rebase fex main --trial`): 83 patches, 72 clean, 5 3-way,
  6 conflicts. The run landed with `pp rebase fex --write --pins` (the
  `fex` branch column is now `main`): 72 clean, 5 3-way, 6 resolved.
- **Resolutions:**
  - `fex-port/0001` (`Syscalls.h`): upstream's `getrandom()` kept at the end
    of the Linux branch, then the port's Apple branch (no `getrandom` there;
    only a native Apple build would need it, which Playport does not make).
  - `fex-port/0006` (`Priv.h`): upstream's `UnimplementedLog(__func__)` call,
    then the port's encoded exit status.
  - `fex-port/0009` (`CPUFeatures.cpp`): the port's iOS block with upstream's
    new `ProcessPID` parameter, which it also stores.
  - `fex-port/0043` (`SharedCodeBufferManager.cpp`): upstream's new
    constructor (JIT-buffer naming), then the port's generation counter.
  - `fex/0016` (`WOW64/Module.cpp`, 5 hunks): upstream's new form
    (`LoadStateFromWowContext` without the WowTEB argument, the context API
    off TLS, `WowContext` a pointer) with the patch's guest-window
    translations on it (GDT base, the unix-call arguments, the
    `Wow64SystemServiceEx` stack pointer, the SMC fault address, the access
    violation's address).
  - `fex/0018` (`OpcodeDispatcher.cpp`): the memory destination of
    upstream's new `XCHGOpImpl` and its `CLZERO` now go through
    `GuestToHostAddress`; every other memory path upstream added there was
    checked, and these two are the only new ones.
- **Range-diff flags (checked in the new tree):** `fex-port/0014`
  (`Logging.cpp`: the iOS guard around `SilentLog` still inside `Init()`),
  `0024` (`Core.cpp`: the telemetry globals still at file scope), `0041`
  (context only; the iOS degrade loop runs before upstream's `VirtualName`),
  `0054` (context only), `fex/0005` (context: 0009's `ProcessPID` line). No
  clean patch changed.
- **Build:** the `fex` stage built both DLLs; `app/artifacts.tsv` changed.
  FEX `main`'s new `Scripts/NeedDisabledSVE.py` prints a traceback at
  configure on the x86 build host (it reads the host's `/proc/cpuinfo`); it
  is not fatal and both configures still end with `-mcpu=cortex-a78`.
  `pp test`: all passed.
- **Brought in** (alignment plan A2): the WoW64 CHPEv2 commits `af04940`,
  `4956ac2` and `b1e54d8`, and the disk-cache cap and pruning (B1, which stays
  off). Whether `fex/0016` and `0018`'s WoW64 resolutions hold on Portal 2
  (i386) is the Portal 2 play of this IPA: pending, phone away.

## dxmt → main

- **Distance:** 16 commits, `7c8dee1..68af85e` (fixes in d3d10/d3d11/d3d12,
  airconv, nvapi, nvngx, two CI changes). Madeira's `dxmt-port` row did not
  move (Madeira is not moved in this step).
- **Trial** (`pp rebase dxmt 68af85e --trial`): 54 patches, 53 clean,
  1 conflict.
- **Resolution (one):** `dxmt/0006` (Playport's: initialise the encoding
  context's `device_` and `queue_` before its command contexts). Upstream
  `fb45156` now declares and initialises `device_` first, the same fix for the
  same crash. Kept upstream's `device_` and the patch's `queue_` beside it, so
  the initialisation order stays the one Playport has run; the patch is now
  that one move, and its message says so. Its trailers are unchanged.
- **Range-diff flags:** none other than 0006 (shown as replaced). No clean
  patch changed.
- **Generated sources and slots:** `gen_remote_guard.py` and
  `gen_api_names.py` run in the patched tree changed nothing; `pp slots`:
  150 slots, 149 calls, every call matches its slot.
- **Build:** the `dxmt` stage; `app/artifacts.tsv` changed. `pp test`: all
  passed.

## mesa → main

- **Distance:** 369 commits, `82d4f86..b39d173` (GitLab's compare; the build
  fetches Mesa shallow). Three of the 552 changed files are under
  `src/kosmickrisp` or the Vulkan WSI.
- **Replay:** `patches/mesa` (16 patches) applies to `b39d173` with plain
  `git am`: all clean, no 3-way merge, nothing upstream.
- **Build:** the `vulkan` stage (Mesa's `src host ios check framework`, then
  DXVK and vkd3d-proton) passed, including the Mach-O import check; no build
  record changed (the KosmicKrisp framework is not in `app/artifacts.tsv`).
  The KosmicKrisp host test (`build/stages/mesa.sh … hosttest`, a mock Metal
  bridge): all 24 pipelines built and drawn, 127 MSL libraries, no
  untranslated intrinsics. `pp test`: all passed.

## dxvk → master

- **Distance:** 18 commits, `52fe923..e5ffd0f` (GitHub compare). Proton
  bleeding-edge's DXVK `d30be2b` is the commit before the head; the head adds
  only "Disable present timing by default".
- Unmodified (no series). **Build:** the `vulkan` stage; `app/artifacts.tsv`
  changed (the DXVK DLLs). `pp test`: all passed.

## vkd3d-proton → master

- **Distance:** 20 commits, `472989a..31d1f89` (GitHub compare), the commit
  Proton bleeding-edge carries.
- **Replay:** `patches/vkd3d-proton` (4 patches) applies with plain `git am`:
  all clean.
- **Build:** the `vulkan` stage; one build record changed (`d3d12core.dll`
  in `app/artifacts.tsv`). `pp test`: all passed.

## wine-valve → Valve's bleeding-edge

- **What bleeding-edge is:** Valve Wine's `bleeding-edge` (`750fd011356`,
  2026-10-03) is `proton_11.0` at the old pin `dc26e61` plus 409 commits, no
  merges; `wine-11.0` plus 1,862 in all. So every `Valve-commit:` the series
  names is still on the branch, and the re-pick is the 409 sorted by 0018's
  rules.
- **How they were sorted:** the 2026-09-28 record's `classify.py` and
  `choose_valve.py` (`2026-09-28-wine-proton-rebase/`), with the range set to
  `dc26e61..bleeding-edge` and "upstream" meaning wine-11.19 has it; the 28
  commits the scripts left as wanted were then read one by one. Every
  commit's verdict is in
  [`2026-10-05-deps-latest/valve-bleeding-edge-commits.tsv`](2026-10-05-deps-latest/valve-bleeding-edge-commits.tsv):

  | Verdict | Commits |
  | --- | --- |
  | upstream (wine-11.19 has it) | 318 |
  | unused (winex11, winebus, pulse, opengl32; Valve's GameInput, 8, which enumerates HID pads over winebus) | 16 |
  | proton (Steam, gamescope, VR, winevulkan, GPU spoofing) | 13 |
  | reverted (pairs in Valve's tree, and see below) | 12 |
  | replaced (a file an `*_ios.c` replacement overrides) | 11 |
  | fixup (target left out) | 8 |
  | media | 6 |
  | **taken** | **6** |
  | inert (`wine.inf`, ntoskrnl PnP) | 5 |
  | wow64 (the suspend-helper reverts, below) | 5 |
  | tests, unix-side, build, madeira, conflict | 3, 2, 1, 1, 2 |

- **Taken** (`patches/wine-valve` 0126–0131, `Picked:` as noted):
  `b6225e37cd2` ntdll: section names in `DEFINE_USER_FUNC` (The Finals; clean),
  `91642a856d5` and `542ca26b64e` kernelbase: direct composition off for two
  NW.js games (clean; resolved: the option list now has Valve's ARM-only
  `msedgewebview2` line above it, which is not taken, `proton`),
  `33c82fc8321` gdi32: font linking for runs with missing glyphs,
  `26036b79eda` and `021ee94d7d9` setupapi: device instance ID validation and
  `SetupDiOpenDeviceInfo` (these three resolved by leaving their test hunks
  out, as 0018's picks did; the code hunks are Valve's, checked line by line).
- **Dropped from the series:** `0120`, Valve's revert of "ntoskrnl: Enumerate
  child devices on a separate thread" (`6d993a3a5f8`): bleeding-edge reapplies
  it (`fd0129e61a3`), so the pair is left out. The four patches after it
  replay unchanged. The series is 132 patches (127 − 1 + 6).
- **Left out after reading:** the two cmd `start` commits (they conflict with
  WineHQ's cmd parsing rework in 11.19 and are a pending WineHQ merge
  request; the app runs no cmd scripts), the Far Cry 4 xinput HACK and its
  fixup (Madeira's host-pad xinput answers first), FAudio and wmadmod's WMA
  decoder (media), Valve's Intel driver-store spoof, a revert of the x86 Wine
  Mono HACK the series never took, and an add-then-remove pair in
  `ntdll/exception.c`.
- **The WoW64 suspend-helper reverts (alignment B2):** `2c1ef7131cb`,
  `65388665d4a`, `c97ffea75a5` (and `cc17cbcb13e`, `8cd623d83f4`) revert
  Valve-only WoW64 suspend code. `patches/wine-valve` never carried what they
  revert, so with them Playport's Wine side already matches bleeding-edge
  here; nothing is picked.
- **Replaced files (not carried):** 11 commits change a file a replacement
  overrides, among them `c5798e587d5` (simulated async read for Assassin's
  Creed Valhalla, `SteamGameId`-keyed), `26442e0a3ce` (`WINESTEAMNOEXEC` for
  Sniper Elite V2) and Valve's reverts of its EAC locale HACKs.
- **Build:** the `unix`, `pe`, `dxmt` and `vulkan` stages; the three
  `wine-pe-*.tsv` manifests and `app/artifacts.tsv` changed. `pp test`: all
  passed. `pins.lock`'s `wine-valve` row is now the `bleeding-edge` branch, so
  `pp sync`'s `wine-valve-new.tsv` lists bleeding-edge's new commits (the B2
  note about the sync report).

# Plan: align with Valve's ARM64 Proton

**Date:** 2026-10-05. **Kind:** plan, nothing done yet. **Pins read:**
`pins.lock` at the commit that adds this plan (`madeira` 8c050d0, `wine`
wine-11.18, `wine-valve` dc26e61, `fex` FEX-2609.1, `dxmt` 7c8dee1, `mesa`
82d4f86, `dxvk` 52fe923, `vkd3d-proton` 472989a, `gbe` release-2026_09_27).

## Goal

Treat Valve's ARM64 work in Proton (FEX through ARM64EC/WoW64, and its FEX and
Wine defaults) as the reference platform. Take its defaults and changes where
they apply to iOS, and record a reason wherever we differ. Provenance stays
willfaust/Madeira (decision 0001). Valve's tree is a reference only, never a
base.

Two steps, in order: **(1)** bring every dependency to its latest version,
then **(2)** re-evaluate each alignment item on that build and act on it.
Nothing from step 2 starts before step 1 is finished.

**Owner's direction (2026-10-05): latest possible, not latest release.** Every
dependency moves to the head of its development branch, and the Valve
reference is Proton **bleeding-edge**:

- FEX: `main` (what bleeding-edge ships), not FEX-2609.1 or a later monthly tag.
- Madeira, DXMT, Mesa, DXVK, vkd3d-proton: their `main`/`master` heads
  (bleeding-edge's DXVK and vkd3d-proton are already the heads).
- `wine-valve`: picks from Valve Wine's bleeding-edge branch (`750fd011` at
  this snapshot), not proton_11.0. The three WoW64 suspend-helper reverts come
  with it (B2).
- `wine`: the newest WineHQ development tag (wine-11.19 today). WineHQ
  `master` moves daily and Madeira's ports are rebased per tag; take `master`
  only if a tag lacks something Valve's bleeding-edge Wine depends on, and
  record why.
- The ARM defaults that differ between Proton branches (disk cache, CPU
  topology fallback) are judged against bleeding-edge.

This changes the pin policy of decisions 0008 (FEX releases), 0013 (Wine
tags) and 0018 (`wine-valve` from proton_11.0): step 1 opens with one decision
record that supersedes those parts, and every later move cites it.

## Valve's reference snapshot (2026-10-05)

| Proton branch | Head | FEX | Wine (ValveSoftware/wine) | DXVK | vkd3d-proton |
|---|---|---|---|---|---|
| proton_11.0 (stable) | `5b89db94` | `1cc4b93e` (FEX-2607) | `dc26e618` | `a6764047` | `212991fc` |
| experimental_11.0 | `70b7e109` | `0df84d38` (FEX main) | `6d211aab` | `68530156` | `44cf7c20` |
| bleeding-edge | `b3749405` | `3648ee97` (FEX main head, 10-03) | `750fd011` | `d30be2ba` (master head) | `31d1f89c` (master head) |

On all three branches:

- The global `FEX_Config.json` is identical (8 keys, listed in item A0).
- `fex_application_profiles` has one entry: 292030, `setup*` → `X87ReducedPrecision=0`.

Experimental and bleeding-edge add two ARM defaults that stable lacks:

- `FEX_DISKCACHE=1` (Proton `09d3d6e5`).
- A `WINE_CPU_TOPOLOGY` value taken from the process's CPU affinity.

Sources:

- https://github.com/ValveSoftware/Proton/blob/b37494057ba64f96acf66eebe33928838d64b9b6/FEX_Config.json
- https://github.com/ValveSoftware/Proton/blob/b37494057ba64f96acf66eebe33928838d64b9b6/proton
- https://github.com/ValveSoftware/Proton/blob/b37494057ba64f96acf66eebe33928838d64b9b6/Makefile.in
- https://github.com/ValveSoftware/Proton/commit/09d3d6e5f60c51a6c30501306d88f8d385188901

Re-read the heads before starting. Valve moves these branches weekly.

## Step 1: every dependency to its latest version

### Rules for every move

- **One dependency per commit.** The only exception is `rpmalloc`: its row is
  defined as the FEX commit's `External/rpmalloc` gitlink, so it moves in the
  same commit as `fex`. The commit carries the pin, the re-ported series, the
  build records (`app/artifacts.tsv`, `build/generated/wine-pe-*.tsv`) and an
  evidence record `docs/evidence/<date>-<dep>-<sha8>.md` with the IPA sha256.
- **How each moves**, per AGENTS.md "Pins" and UPSTREAM-SYNC.md:
  - Madeira moves only by `pp sync <sha>`.
  - `wine`, `fex`, `rpmalloc`, `dxmt` and `wine-valve` move by a manual rebase or
    pick. Check every auto-merged hunk with `git range-diff` against both sides.
  - After a DXMT rebase, run `gen_remote_guard.py` and `gen_api_names.py`;
    `pp slots` must then be clean.
  - `mesa`, `dxvk`, `vkd3d-proton` and `gbe` are a pin edit, plus a replay of
    their series where they have one.
- **Gate (both titles, every commit).** Run these in one locked session:

  ```sh
  ./pp test
  ./pp phone lock -- sh -c './pp install --no-build && \
    ./pp ui --play app-367520 --until first-frame+10 --shot && \
    ./pp ui --play app-620 --until first-frame+10 --shot'
  ```

- **Before and after `pp perf`**, on the same IPA pair, starting at thermal
  `nominal`. Use the routes from `docs/evidence/2026-10-05-portal2-cpu-spin.md`:

  ```sh
  ./pp perf --secs 100 --pad first-frame+25:hk-new-game --pad first-frame+45:hk-walk
  ./pp perf --secs 140 --pad first-frame+30:p2-cold-boot --pad first-frame+88:p2-walk
  ```

  Record FPS, Mi/f (main thread and all threads), CPU P/E and power, and
  hitches of 25/50/100 ms or more. The "before" of commit N is the "after" of
  commit N−1.
- A move that fails the gate, or regresses either title beyond run-to-run
  noise, is held. The hold and its cause go in the evidence record. Nothing is
  forced through.

### Order and targets

| # | Row(s) | Pin now | Latest upstream (2026-10-05) | Valve's choice | Notes |
|---|---|---|---|---|---|
| 1 | `madeira` | `8c050d0` | `main` `bbbf8d0` (2026-10-04), 438 commits ahead | (none) | `pp sync`. If Madeira moved its Wine, DXMT, FEX or rpmalloc, the sync holds (`*-port-moved`). Re-port the `patches/*-port` series and the `madeira-port` patches at the end of `madeira-unix`, then land the port rows and the Madeira pin together in one commit (UPSTREAM-SYNC.md). This goes first because the port rows must equal Madeira's gitlinks. |
| 2 | `wine` | wine-11.18 `7b3fff7` | **wine-11.19** (tagged 2026-10-02) | Valve Wine `dc26e61` (stable) / `750fd01` (bleeding-edge) | 0013 re-port. Replay `patches/wine-valve` after it, and record every dropped or resolved pick. |
| 2b | `wine-valve` | `dc26e61` (proton_11.0) | Valve Wine bleeding-edge `750fd011` | bleeding-edge | Re-pick from bleeding-edge (owner's direction), classifying each commit by 0018's rules; the WoW64 suspend-helper reverts come with it (B2). |
| 3 | `fex` + `rpmalloc` | FEX-2609.1 `9fbdc00` | `main` `3648ee9` (2026-10-03) | bleeding-edge = main head | FEX `main` (owner's direction). Brings the WoW64 commits `af04940`, `4956ac2` and `b1e54d8` (A2) and the disk-cache cap and pruning (B1). |
| 4 | `dxmt` | `7c8dee1` | `main` `fb45156`, 3 commits ahead | not used by Valve | Then run `gen_remote_guard.py`, `gen_api_names.py` and `pp slots`. Check whether Madeira's `dxmt-port` moved in step 1. |
| 5 | `mesa` | `82d4f86` | `main` head when the step runs (not checked) | not comparable (Valve uses the Linux drivers) | Replay `patches/mesa`. |
| 6 | `dxvk` | `52fe923` (38 commits past v3.1.1) | `master` `d30be2b`, 17 commits ahead | bleeding-edge = `d30be2b` | Unmodified. |
| 7 | `vkd3d-proton` | `472989a` | `master` `31d1f89`, 20 commits ahead | bleeding-edge = `31d1f89` | Replay `patches/vkd3d-proton`. |
| 8 | `gbe` | release-2026_09_27 | the same (newest release) | not used | No move unless a newer release appears. |
| 9 | `freetype`, `abseil-cpp`, `xtool`, `gstreamer`, `idevice`, `rust` | see `pins.lock` | not checked | n/a | Each in its own commit with the same gate. `abseil-cpp` follows gbe's protobuf, so it moves only when gbe names a newer one. |
| 10 | `llvm-project` 15.0.7, `stikjit` 1.6.0 | (these) | newer exist | n/a | **Expected holds; record the reason.** airconv is built against LLVM 15. A StikJIT 3.x move changes the JIT script protocol (runtime-risks plan, item 1). Try each move and record why it holds; do not force it. |

**Deliverable of step 1:** `docs/evidence/<date>-deps-latest.md`. It contains:

- one row per dependency: old pin, new pin, latest upstream, Valve's
  stable/experimental gitlink, gate result, and the before/after `pp perf` deltas;
- an explicit list of where Valve's pins differ from upstream latest. Today
  stable Proton is on FEX-2607 and older DXVK/vkd3d-proton, while bleeding-edge
  tracks the heads.

## Step 2: alignment items (re-evaluate each after step 1)

Status as of this plan:

- **Already aligned:** the four ordering switches (0021); Multiblock (FEX's
  default true); x87 at 64-bit for every game with Witcher `setup*` at 80-bit
  (0048, adopted 2026-10-05); the profile data.
- **Playport-only addition:** LRCPC2 from the host.

Each item below has its change, its expected effect, its risk, the measurement
on the phone and whether it needs a decision record.

### A. Adopt after measurement

**A0. Refresh the Proton data in `FEXProfile`.**
- **Change:** `protonSource` still names bleeding-edge `c9e0da9d736c`
  (2026-09-26). Update it to the heads in the snapshot table, and diff the
  8 keys and `fex_application_profiles` again.
- **Expected effect:** none at runtime; the data stays current.
- **Risk:** low.
- **Phone measurement:** none. `swift test` covers it.
- **Decision record:** no.

**A1. Global `MaxInst=500`.**
- **Change:** take Proton's global value under the profile entry and the
  game's page. Export `FEX_MAXINST` on every launch, and update
  `defaultBlockSize`, the page's default label and the tests.
- **Expected effect:** unknown. Smaller blocks may compile faster and stutter
  less on first runs. They may also add dispatch overhead and lose multiblock
  optimisation in steady play. Nothing has measured it on the phone.
- **Risk:** medium, performance only.
- **Phone measurement:**
  1. A dev-page sweep of 500/1000/2000/5000 on both routes above.
  2. Then ABBA pairs of 500 against 5000 at 60 FPS: Mi/f, power, hitch counts,
     Play→first-frame, and the JIT pool head/tail.
  3. Adopt only if neither title regresses in Mi/f or tail latency.
- **Decision record:** yes. It supersedes the MaxInst part of 0021 (0048
  deferred it). Source: `FEX_Config.json` above; the FEX default 5000 is in
  `FEXCore/Source/Interface/Config/Config.json.in`.

**A2. WoW64 CHPEv2 suspend/termination (FEX side).**
- **Change:** comes with step 1 row 3 if FEX moves to main (or to FEX-2610, if
  that release contains them):
  - `af04940` sets `ChpeV2CpuAreaInfo` for WoW64 threads;
  - `4956ac2` makes `BTCpuThreadTerm` use the target thread's CPU area;
  - `b1e54d8` makes `BTCpuThreadTerm` wait for real suspension through `NtGetContextThread`.

  Take all three or none: the second fixes the first.
- **Expected effect:** per the commit message, correct 32-bit debug events
  and contexts, fewer wineserver round trips per suspend, and no remote thread
  for inter-process suspend.
- **Risk:** high on iOS. Madeira's suspend is its own design
  (`MADEIRA_REAL_SUSPEND=1`, `madeira-unix` 0010 safe-point hold), and the
  `fex-port` WoW64 patches touch the same frontend. Watch for deadlocks at
  thread exit and wrong-thread state.
- **Phone measurement:**
  - Portal 2: pause/resume in game repeated 10 times, save/load, quit to menu,
    and exit while worker threads are alive.
  - Hollow Knight: the standard play.
  - Compare `[sync-census]` and the wineserver request rate before and after.
- **Decision record:** only if the suspension contract changes. Otherwise this
  is an ordinary FEX rebase under 0008.

Commits:

- https://github.com/FEX-Emu/FEX/commit/af04940466a028bdfc8fcbea8318e3a4719e561f
- https://github.com/FEX-Emu/FEX/commit/4956ac23e52cca211041e4ae58c98bde595f5ea3
- https://github.com/FEX-Emu/FEX/commit/b1e54d803ba1473d2c3b6b8a92b377ef431b2394

### B. Investigate before adopting

**B1. FEX disk cache on by default** (Valve experimental/bleeding-edge, Proton `09d3d6e5`).
- **Change if adopted:** `FEX_DISKCACHE=1` by default from the launch
  (`FEXProfile`), with a cap well below FEX's 1 GiB `DiskCacheMaxFileSize`.
  This needs a FEX that has the cap and the stale-entry pruning: FEX main, or
  the release after 2609.
- **Expected effect:** fewer recompiles on warm starts. The 2026-09-26
  evidence found 99.9 % cache hits but **no** reduction in hitches on Hollow
  Knight.
- **Risk:** high, because of the open Witcher 3 warm-start crash (rpmalloc
  `page_available_to_free`, "FEX HEAP WAS ZEROED"). Other risks: disk growth on
  a phone; cache keys that leave out `HostFeatures` (0021 cost, LRCPC2); and
  guest-window relocations for i386.
- **Before any default change:**
  1. Reproduce or clear the Witcher crash on the step-1 FEX.
  2. Add a UI action that clears the cache (decision 0012: no side channel).
  3. Cold, warm and repeated runs of both titles, with config flips
     (x87, MaxInst, LRCPC2).
  4. Record the cache size after 3 plays.
- **Decision record:** yes. It changes the "stays off" outcome of the
  first-run-stutter evidence and needs a mobile cache budget.

**B2. Valve Wine ARM64 commits past stable (experimental-only).**
- **Change:** list Valve's ARM64EC/WoW64/FEX-related commits between
  `dc26e61` and `6d211aab`/`750fd011`, and classify them by 0018's rules.
  Facts found so far:
  - The three suspend-helper reverts (`2c1ef71`, `65388665`, `c97ffea`, all
    2026-09-11) remove Valve-only code that `patches/wine-valve` never carried.
  - `36338c0`, `e122adf` and `1c0dd8b` are WineHQ commits (`0b8d0add`,
    `3b6b0ced`, `f286074a`) that are already in wine-11.16/11.17 and later, so
    they are in the base.
- **Inference, not verified:** on these points Playport's Wine side may already
  match bleeding-edge. What remains is whether Madeira's `*_ios.c` replacements
  bypass the WineHQ files involved, and whether WineHQ's wow64 reads
  `ChpeV2CpuAreaInfo` the way FEX `af04940` expects.
- **Expected effect:** this is a correctness audit, not a speed change.
- **Risk:** the replacements may silently bypass the WineHQ code.
- **Phone measurement:** as for A2.
- **Decision record:** yes, if `wine-valve` should track experimental rather
  than proton_11.0. That changes 0018's "proton_11.0" wording. The `pp sync`
  report lists only proton_11.0, so experimental deltas are invisible to it today.

**B3. Large address aware for i386 (`WINE_LARGE_ADDRESS_AWARE`, on by default in Proton).**
- **Change if adopted:** port Valve `799e5f0f` ("ntdll/loader: add support for
  overriding IMAGE_FILE_LARGE_ADDRESS_AWARE") into Madeira's `virtual_ios.c`
  WoW64 limit logic as a `madeira-unix` patch. Keep Proton's per-game
  `noforcelgadd` exceptions as data.
  - Setting the variable alone does nothing: WineHQ `virtual.c` has no such
    variable, and Valve's code is on by default only inside Valve Wine.
- **First, measure:**
  - whether `portal2.exe` already has the LAA flag;
  - what the guest window (0047) gives a non-LAA image today: a 2 GiB or a
    4 GiB user limit.
- **Expected effect:** more address space for non-LAA 32-bit games. There
  could be no effect at all on Portal 2.
- **Risk:** medium. Some i386 code assumes pointers stay below 2 GiB, and the
  guest-window and allocator contracts are involved.
- **Phone measurement:** Portal 2 map transitions and save/load. Log the
  guest's virtual-allocation failures and the window's peak use.
- **Decision record:** yes (a new global i386 policy).

**B4. Per-executable FEX profiles for child processes.**
- **Change:** today Witcher `setup*` applies only when the app launches it
  (0021 cost). Proton writes `AppOverrides` into a per-launch FEX config file
  (`FEX_APP_CONFIG`), which FEX matches per process.
- **Investigate:** whether `FEX_APP_CONFIG` works in one Mach process with
  per-pseudo-process emulators.
- **Expected effect:** child installers get the right x87 precision.
- **Risk:** low. No current cohort title needs it.
- **Decision record:** yes, if the transport changes (extends 0021).

**B5. Release-build log defaults.**
- **Change:** unless the user enables logging, Proton sets `WINEDEBUG=-all`,
  `DXVK_LOG_LEVEL=none`, `VKD3D_DEBUG=none` and `VKD3D_SHADER_DEBUG=none`.
  Check what the release variant sets today (decision 0009) and apply the same
  defaults to release only.
- **Expected effect:** a small CPU saving and a smaller `playport.log`.
- **Risk:** losing diagnostics.
- **Phone measurement:** a release play of both titles, comparing log size and
  CPU.
- **Decision record:** no.

**B6. Steam appinfo FEX settings (`STEAM_FEX_TSOENABLED`, `STEAM_FEX_MULTIBLOCK`).**
- **Investigate:** whether Playport's PICS client receives these fields, and
  what values 620 and 367520 get.
- **Expected effect:** unknown. Valve's per-game TSO/Multiblock data is not
  public.
- **Risk:** stale data could turn TSO off.
- **Decision record:** yes (remote data feeding launch defaults; amends 0021's
  "not carried").

**B7. `WINE_CPU_TOPOLOGY` from affinity** (experimental/bleeding-edge).
- **Investigate:** whether Wine's topology on iOS reports P and E cores
  sensibly to games. Valve's code uses Linux `sched_getaffinity`, which iOS
  does not have.
- **Expected effect:** only for games that size thread pools by core count.
- **Decision record:** only if it changes.

### C. Not applicable on iOS (record the reason, do not copy)

| Proton item | Why not |
|---|---|
| `ProfileStats=1` | Writes Linux stats shared memory. `pp perf` has its own telemetry (0021). |
| FEX Linux UnixLib (prctl hardware TSO and unaligned atomics, THP, VMA names) | Linux-only kernel interfaces. There is no UnixLib in the iOS build. |
| `-march=armv8.2-a -mtune=cortex-x3` | Tuning for Snapdragon/Cortex. Apple cores need their own check. |
| `-marm64x` for DXVK/vkd3d-proton | ARM64X serves native ARM64 callers. All guests are x86. Revisit only if native ARM64 Windows games come into scope. |
| fsync/ntsync, the Steam runtime, `PROTON_USE_ARM64` paths, `SilentLog`/`PROTON_LOG`, NVAPI | Linux launcher, driver or GPU specifics. In-process sync stays off (0023). |
| FEX `client.json`/`steamwebhelper.json` app configs | These target the Linux Steam client. Playport's Steam client is native Swift. |
| Valve Wine AVX/YMM contexts, SVE state | FEX on iOS advertises no AVX, and Apple CPUs have no SVE (0018). |
| `MIMALLOC_DISABLE_REDIRECT` for Teardown (1167630) | Per-game data, not an ARM default. Carry it only if Teardown is played. |
| Valve's FEX DLL names (`libarm64ecfex.dll`, `libwow64fex.dll`) | Playport ships `xtajit64.dll`/`xtajit.dll`, which Madeira's loader expects (0018). |

## Decision records this plan may need

- Latest-possible pins (step 1, owner's direction): FEX `main`, `wine-valve`
  from bleeding-edge, every other dependency at its branch head; supersedes
  the pin-source parts of 0008, 0013 and 0018.
- `MaxInst=500` (A1): supersedes part of 0021.
- Disk cache default (B1).
- LAA for i386 (B3).
- Optionally, a standing policy record that "Valve's ARM64 Proton is the
  reference platform", naming which branch is the reference for which kind of
  change.

## Open questions

1. *(Settled 2026-10-05: FEX `main`.)*
2. *(Settled 2026-10-05: Proton bleeding-edge is the reference.)*
3. Does `portal2.exe` carry the LAA flag, and what WoW64 limit does
   `virtual_ios.c` give non-LAA images?
4. Do Madeira's `*_ios.c` replacements override the WineHQ files that contain
   `0b8d0add`, `3b6b0ced` and `f286074a` (B2)?
5. Does WineHQ wine-11.19 wow64 consume `ChpeV2CpuAreaInfo` as FEX `af04940`
   assumes, or did Valve's experimental Wine carry a counterpart?
6. Is the Witcher 3 warm-cache crash a FEX disk-cache bug, an rpmalloc-port
   bug or a Madeira bug? It blocks B1.
7. How large a FEX disk cache is acceptable on the phone?

## Done when

- Step 1's evidence record lists every `pins.lock` row as moved or held with a
  reason, each with gate and `pp perf` results, and the Valve-versus-upstream
  difference table.
- Every item in A and B is adopted (with its evidence and decision record),
  closed with a reason, or left with a named blocker. The table in C is copied
  into ARCHITECTURE.md.
- The stale "Guests are x86-64 only" line in ARCHITECTURE.md is corrected
  (0047).


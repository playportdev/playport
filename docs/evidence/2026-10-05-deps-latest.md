# Every dependency to its latest version (alignment plan, step 1)

**Date:** 2026-10-05. **Plan:** [Proton ARM64 alignment](../plans/2026-10-05-proton-arm64-alignment.md),
step 1 (rows 2–10), under decision [0049](../decisions/0049-latest-pins.md).
**Kind:** one move per commit, each built and committed with its IPA while
the phone was away (14:14–15:43), then played in order on the phone (gate,
both titles, per IPA) and measured with `pp perf` on the baseline and the
final IPA. **Result:** every move passes the gate; the final build does no
more CPU work a frame than the baseline in either title and draws less CPU
power. Portal 2's count of short hitches in its load segment, higher on the
final IPA in the first pair, is run-to-run spread: repeats and a bisection
over the step IPAs (below) put the baseline alone at 52–268. Rows 8–10
(freetype, rust, StikJIT) pass one gate on the branch rebased onto `main`
0.3.2 (`35956f63`, [the last section](#rebase-onto-main-032-and-the-gates-of-rows-810)).

## IPAs, in order

**Why rebuilt:** the table listed eight IPAs, but `pp build` keeps only the
newest three `out/` directories, so the first builds of steps 1–6 no longer
existed when the plays were due. Steps 1–6 were therefore rebuilt from their exact commits (detached,
clean tree, `pp build --keep-outputs 20`). The rebuilds are not byte-identical
to the first builds: at the old pins, `d3d11.dll` (DXMT), `d3d12core.dll`
(vkd3d-proton), the two FEX DLLs and `winetest.exe` hash differently from the
committed records, after the build trees had moved forward and back (the
records at FEX main and later match, except `d3d12core.dll` before the
vkd3d-proton move). These rebuilt IPAs are the ones played; the first
baseline `b1c15122`, played at 14:08 (Hollow Knight +9.48 s, Portal 2
+5.46 s), is gone. Steps 7 and 8 are the first builds.

Gate: one locked session per IPA, `pp install --no-build --ipa IPA`, then
`pp ui --play app-367520 --until first-frame+10 --shot` and the same for
`app-620`. Times are from Play; every play reached `first-frame+10` and ran
on. Every Hollow Knight screenshot shows the main menu (Start Game, Options,
Achievements, Extras, Quit Game). Every Portal 2 screenshot shows the
"powered by Source" splash with Valve's copyright text, except DXMT's, which
is black at that moment. Portal 2 runs on Vulkan, which that move does not
touch, and the baseline's 14:08 play was black there too, so this is the
splash's timing.

| Step | Commit | IPA (`.work/out/…`) | SHA256 (installed) | HK JIT / first frame | P2 JIT / first frame | Gate |
|---|---|---|---|---|---|---|
| baseline | `e71e8a7` | `20261005-152202-a834313d/Playport-26.5-a834313d.ipa` | `a834313d194859e97adf6f638ac18a27e33d714ca3763fa72ce09294a64ea06d` | 2.53 s / 9.49 s | 2.46 s / 5.43 s | pass |
| wine-11.19 | `7d0f5b3` | `20261005-153220-53dbed03/Playport-26.5-53dbed03.ipa` | `53dbed03795fb8571d9bdfac41ddb32e99738f34a4b4e819a468d44cf9d3ec67` | 2.47 s / 8.40 s | 2.53 s / 5.51 s | pass |
| FEX main | `22ac169` | `20261005-153421-46978e44/Playport-26.5-46978e44.ipa` | `46978e440e0a8fa3e037c8aa8ae77c142779df1bb0a83db148ba33c3102baf5d` | 2.47 s / 9.47 s | 2.53 s / 5.52 s | pass |
| DXMT main | `2cd6d80` | `20261005-153622-355f2a8e/Playport-26.5-355f2a8e.ipa` | `355f2a8e2c8576adf46e25a2d032900f6c26b144c05d24f843ae353ba60c9d2e` | 2.40 s / 9.54 s | 2.37 s / 5.34 s | pass |
| Mesa main | `6d09073` | `20261005-153851-2cd9106f/Playport-26.5-2cd9106f.ipa` | `2cd9106fca9c23de2149f310c8ec1e9590a07d4ebe6bb780363d34f8419af58c` | 2.53 s / 9.50 s | 2.28 s / 5.31 s | pass |
| DXVK master | `cf020cb` | `20261005-154054-d18103b0/Playport-26.5-d18103b0.ipa` | `d18103b0b24863970a8393228614d14d3aeddc29b9fb6919e425a2aa7e3a2338` | 2.33 s / 9.36 s | 2.43 s / 5.37 s | pass |
| vkd3d-proton master | `c6b8936` | `20261005-145755-c85a8ec2/Playport-26.5-c85a8ec2.ipa` | `c85a8ec2f299c73ff5bee1e5ebe6d16096a07bd323af58eb11e383c4f30fdd08` | 2.46 s / 9.45 s | 2.41 s / 5.40 s | pass |
| wine-valve bleeding-edge | `b011dbf` | `20261005-150922-eb5ae2ad/Playport-26.5-eb5ae2ad.ipa` | `eb5ae2adcbef49fa1f4d1cd163a44903d821f55697cd657b2a635c787e5f421e` | 2.38 s / 8.38 s | 2.58 s / 5.59 s | pass |

The phone was left with the final IPA (`eb5ae2ad`) installed. Portal 2 is an
i386 WoW64 title, so its passes on the FEX main IPA and every later one show
that the `fex/0016` and `0018` WoW64 resolutions hold as far as the start of
the game. The scripted walk in `pp perf` below also runs on the final IPA.

## `pp perf`, baseline against final

Routes as the plan gives them (`pp perf --secs 100 --pad
first-frame+25:hk-new-game --pad first-frame+45:hk-walk`; `pp perf --title
app-620 --secs 140 --pad first-frame+30:p2-cold-boot --pad
first-frame+88:p2-walk`), with `--cool 10 --cool-max 30` for the first run
and `--cool 15 --cool-max 20` for the others. All four started at thermal
`nominal`, stayed there, and ran on battery (66 → 55 % over the four). The
windows are the walks: Hollow Knight t = 60–100 s, Portal 2 t = 95–135 s
(averages of the 5 s buckets; Mi/f from `threads.txt`, million instructions
a frame).

| | HK base `dl-base-hk` | HK final `dl-final-hk` | P2 base `dl-base-p2` | P2 final `dl-final-p2` |
|---|---|---|---|---|
| FPS mean / p10 (whole run) | 58.2 / 54.0 | 58.3 / 54.2 | 58.5 / 54.0 | 58.7 / 55.6 |
| FPS in the window | 59.1 | 59.1 | 60.0 | 60.0 |
| main thread `002c` Mi/f | 23.6 | 23.0 | 15.0 | 14.1 |
| all threads Mi/f | 73.5 | 72.1 | 68.9 | 64.4 |
| process CPU (P / E) | 121 % (88 / 33) | 118 % (86 / 32) | 121 % (35 / 86) | 125 % (28 / 97) |
| CPU power (`[xp]`) | 686 mW | 630 mW | 367 mW | 295 mW |
| wineserver requests a frame | 18.7 | 18.7 | 48.5 | 43.8 |
| hitches ≥ 25 / 50 / 100 ms | 384 / 10 / 5 | 361 / 10 / 5 | 192 / 20 / 7 | 302 / 20 / 8 |
| of them before t = 60 s (load) | 257 / 7 / 3 | 210 / 7 / 3 | 52 / 19 / 7 | 134 / 19 / 8 |
| from t = 60 s (play) | 127 / 3 / 2 | 151 / 3 / 2 | 140 / 1 / 0 | 168 / 1 / 0 |

- No regression beyond noise in frame rate, work a frame or power. Portal 2's
  main thread does 6 % less work a frame and all threads 7 % less, at 20 %
  less CPU power, with more of it on the E cores.
- **Closed as run-to-run spread:** Portal 2's hitches of 25 ms or more rose
  from 192 to 302 in this pair, most of it in the load segment before
  t = 60 s (52 → 134). The repeats below show the baseline IPA alone spans
  52–268 there, so this is not a regression of any move.
- Not split per move in frame rate, work or power: only the baseline and the
  final IPA were measured for those.

### Portal 2's load-segment hitches: repeats and bisection

The same Portal 2 route and options (`--cool 15 --cool-max 20`; every run
started and stayed at thermal `nominal`, on battery 63 → 28 %), each run its
own locked session of `pp install --no-build --ipa IPA` then `pp perf`. Counts
of hitches of 25 / 50 / 100 ms or more from `hitches.txt`, split at
t = 60 s; the last column is the ≥ 25 ms count per 10 s from t = 0 to 140.

| Run (`.work/perf-runs/…`) | IPA | all | load (t < 60) | play (t ≥ 60) | ≥ 25 ms per 10 s |
|---|---|---|---|---|---|
| `dl-base-p2` | baseline `a834313d` | 192 / 20 / 7 | 52 / 19 / 7 | 140 / 1 / 0 | 3 2 1 2 18 23 0 1 24 26 22 20 15 12 |
| `dl-base-p2c` | baseline `a834313d` | 252 / 16 / 6 | 98 / 15 / 6 | 154 / 1 / 0 | 1 5 9 2 55 23 0 31 10 19 19 18 23 24 |
| `dl-base-p2d` | baseline `a834313d` | 415 / 16 / 8 | 268 / 16 / 8 | 147 / 0 / 0 | 33 6 79 11 73 61 1 26 18 18 20 28 15 20 |
| `bis-wine-p2` | wine-11.19 `53dbed03` | 232 / 18 / 7 | 64 / 17 / 7 | 168 / 1 / 0 | 0 13 2 3 33 7 23 26 24 22 9 18 26 15 |
| `bis-wine-p2b` | wine-11.19 `53dbed03` | 298 / 17 / 6 | 174 / 14 / 6 | 124 / 3 / 0 | 79 19 29 3 25 13 0 3 25 24 11 25 17 13 |
| `bis-fex-p2` | FEX main `46978e44` | 322 / 16 / 7 | 171 / 16 / 7 | 151 / 0 / 0 | 35 35 68 3 11 15 0 27 17 18 17 32 11 24 |
| `bis-fex-p2b` | FEX main `46978e44` | 227 / 17 / 6 | 95 / 17 / 6 | 132 / 0 / 0 | 1 12 1 55 11 8 0 23 12 18 18 27 10 24 |
| `bis-mesa-p2` | Mesa main `2cd9106f` | 264 / 17 / 6 | 99 / 17 / 6 | 165 / 0 / 0 | 59 2 1 4 15 8 14 29 32 18 9 12 21 22 |
| `dl-final-p2` | final `eb5ae2ad` | 302 / 20 / 8 | 134 / 19 / 8 | 168 / 1 / 0 | 63 13 1 18 25 10 32 37 23 15 19 13 15 11 |
| `dl-final-p2c` | final `eb5ae2ad` | 267 / 17 / 7 | 151 / 17 / 7 | 116 / 0 / 0 | 56 5 54 2 17 6 0 1 19 21 9 24 20 16 |

- The final IPA's repeat (151) reproduced the count, so a second baseline run
  followed (98), and then a halving over the step IPAs: Mesa (99), FEX (171),
  wine-11.19 (64), and a second run on each side of the apparent wine → FEX
  boundary: FEX 95, wine-11.19 174. The boundary did not hold, and a third
  baseline run gave 268, the highest of all.
- The count is driven by bursts: 30–80 hitches of 25 ms or more inside one
  10 s window, most of them frames of exactly 25.0 ms (one and a half refresh
  intervals), in a window that differs from run to run. Each IPA run twice or
  more shows both a run with such a burst and one without. The ≥ 50 ms
  (14–20) and ≥ 100 ms (6–8) counts, and the mean frame rate (58.5–58.8), are
  the same on every run.
- **Verdict:** run-to-run spread, not a regression; no move is responsible.
  Nothing is reverted. The ≥ 25 ms count of a single Portal 2 run is not a
  usable regression signal for this route; compare the ≥ 50 and ≥ 100 ms
  counts, or several runs a side.

## The moves

One row per dependency. Valve's columns are the 2026-10-05 snapshot in the
plan (stable `proton_11.0` / experimental / bleeding-edge). Rows 8–10 (`gbe`,
the build-time sources, `llvm-project`, `stikjit`) are in
[their own section](#rows-810-gbe-the-build-time-sources-llvm-project-stikjit) below;
`madeira` (row 11) is not moved yet.

| Row | Old pin | New pin | Latest upstream | Valve stable / experimental / bleeding-edge | Build, `pp test` | Gate | `pp perf` |
|---|---|---|---|---|---|---|---|
| `wine` | wine-11.18 `7b3fff7` | wine-11.19 `455e350` | wine-11.19 (2026-10-02; no later tag) | Valve Wine `dc26e61` / `6d211aa` / `750fd01` | passed | pass (above) | final vs baseline (above) |
| `fex` + `rpmalloc` | FEX-2609.1 `9fbdc00`; rpmalloc `09142d7` | `main` `3648ee9`; rpmalloc `09142d7` (unchanged: main's `External/rpmalloc`) | `main` `3648ee9` (2026-10-02, the head on 2026-10-05 14:34) | FEX-2607 `1cc4b93` / main `0df84d3` / main `3648ee9` | passed | pass (above) | final vs baseline (above) |
| `dxmt` | `7c8dee1` | `main` `68af85e` | `main` `68af85e` (16 commits ahead) | not used by Valve | passed; `pp slots` clean | pass (above) | final vs baseline (above) |
| `mesa` | `82d4f86` | `main` `b39d173` | `main` `b39d173` (2026-10-05 09:42 UTC, 369 commits ahead) | not comparable (Valve uses the Linux drivers) | passed; KosmicKrisp host test passed | pass (above) | final vs baseline (above) |
| `dxvk` | `52fe923` | `master` `e5ffd0f` | `master` `e5ffd0f` (2026-10-05 10:53 UTC, 18 commits ahead) | `a676404` / `6853015` / `d30be2b` (bleeding-edge is one commit behind: `e5ffd0f` "Disable present timing by default") | passed | pass (above) | final vs baseline (above) |
| `vkd3d-proton` | `472989a` | `master` `31d1f89` | `master` `31d1f89` (2026-10-02, 20 commits ahead) | `212991f` / `44cf7c2` / `31d1f89` (bleeding-edge = the head) | passed | pass (above) | final vs baseline (above) |
| `wine-valve` | `dc26e61` (`proton_11.0`) | `750fd01` (`bleeding-edge`) | bleeding-edge `750fd01` (2026-10-03; `proton_11.0` plus 409 commits) | `dc26e61` / `6d211aa` / `750fd01` | passed | pass (above) | final vs baseline (above) |

## Where Valve's pins differ from upstream latest

- **FEX:** stable Proton (`proton_11.0`) ships FEX-2607 (`1cc4b93`), two
  monthly releases behind; experimental has `main` `0df84d3` (09-28);
  bleeding-edge has `main` `3648ee9`, which is Playport's new pin.
- **Wine:** every Valve branch is WineHQ wine-11.0 with Valve's commits on
  top (bleeding-edge: 1,862); Playport is WineHQ wine-11.19 with the Valve
  commits it takes as a series (132 patches). 318 of the 409 commits
  bleeding-edge added since `proton_11.0` are backports wine-11.19 already
  has.
- **DXVK:** stable `a676404`, experimental `6853015`, bleeding-edge `d30be2b`;
  `master` (Playport's pin `e5ffd0f`) is one commit past bleeding-edge.
- **vkd3d-proton:** stable `212991f`, experimental `44cf7c2`, bleeding-edge
  `31d1f89` = `master` = Playport's pin.
- **DXMT, Mesa (KosmicKrisp):** Valve uses neither (DXVK and vkd3d-proton on
  the Linux Vulkan drivers).

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

## Rows 8–10: gbe, the build-time sources, llvm-project, stikjit

Latest upstream read on 2026-10-05 at about 20:00. One commit per move, each
built (`pp build --keep-outputs 20`) and tested (`pp test`: all passed). The
phone was held while these were built, so the per-move IPAs below were not
played; after the rebase onto `main`, one gate on the rebased final IPA,
which contains all three moves, passed
([below](#rebase-onto-main-032-and-the-gates-of-rows-810)). Every row is now moved or held with its reason; `madeira`
(row 11) moves later, after the Madeira reconciliation.

| Move | Commit | IPA (`.work/out/…`) | SHA256 | Gate |
|---|---|---|---|---|
| freetype VER-2-14-3 | `1669ff0` | `20261005-200932-60b066f7/Playport-26.5-60b066f7.ipa` | `60b066f744c480b13ad4e21e76df77b64d337acdeb95b576bec8fb616b997289` | superseded: gated in the rebased final `35956f63` |
| rust 1.99.0 | `a4c78a8` | `20261005-202628-8a2f0518/Playport-26.5-8a2f0518.ipa` | `8a2f0518e357c88b36b28daba014858d12fcb02cff2a90e420078a36859f6977` | superseded: gated in the rebased final `35956f63` |
| stikjit 1.9.0 (the final IPA of rows 8–10) | `7bdc25c` | `20261005-203120-bbefed05/Playport-26.5-bbefed05.ipa` | `bbefed057a7f86e02bff9c1867ed330aefe4e6198100d0e76080e78c0c5e895d` | superseded: gated in the rebased final `35956f63` |

Each IPA was built from the tree its commit records (the rust IPA from the
commit before an amend that added only its records and docs). All three
change runtime code (FreeType in `libwin32u_unix.a`, Rust in
`libidevice_ffi.a`, the JIT helper's framework). A gate on an IPA that
contains all three covers them, as long as it passes; it did, so no
per-move gate or bisection was run.

| Row | Old pin | New pin, or held | Latest upstream | Build, `pp test` | Gate |
|---|---|---|---|---|---|
| `freetype` | `VER-2-13-3` | `VER-2-14-3` (`0a0221a`) | `VER-2-14-3` | passed | pass (final `35956f63`) |
| `rust` | 1.98.1 | 1.99.0 (`b940084`, dist 2026-10-01) | 1.99.0 (stable) | passed | pass (final `35956f63`) |
| `stikjit` | 1.6.0 | 1.9.0 (`3228726`) | 1.9.0 (2026-09-27) | passed | pass (final `35956f63`) |
| `gbe` | release-2026_09_27 `7103add` | held: no newer release | release-2026_09_27 (the `dev` head is the tag) | not needed | not needed |
| `abseil-cpp` | 20250512.1 | held: follows gbe's protobuf | 20260817.0 | not needed | not needed |
| `xtool` | 1.20.1 | held: needs a new machine-wide Darwin SDK | 1.21.0 | 1.21.0 built; the app stage refused the SDK | not needed |
| `gstreamer` | 1.28.7 | held: newest stable; a move needs a new licensing audit | 1.28.7 stable; 1.29.2 development | not needed | not needed |
| `idevice` | `d32c818` | held: already the head | `master` `d32c818` = v0.1.68 | not needed | not needed |
| `llvm-project` | llvmorg-15.0.7 | held: DXMT's airconv targets LLVM 15 | 15.0.7 is the last 15.x | not needed | not needed |

### freetype → VER-2-14-3

- **What it is in the app:** Wine's unix-side font rasteriser, built by
  Madeira's `build/freetype-ios/build.sh` (all optional dependencies off) and
  merged into `libwin32u_unix.a`, so a move changes runtime code.
- **Build:** `build/stages/unix.sh` cloned FreeType only when the run tree had
  no clone, so a moved pin kept the old source; it now clones again when the
  clone is not at the pinned tag. Only `libwin32u_unix.a` changed in
  `app/artifacts.tsv`; no Wine PE record changed.
- **Records that name the version:** `build/source-bundle.json` (tag and
  commit), `docs/LICENSING.md`, the comment in `build/notices-assemble.sh`, and
  the app's FTL credit line in `build/app-notices.json`, which now reads as
  2.14.3's `docs/FTL.TXT` asks (its sources say 1996–2026, and the project URL
  is `https://freetype.org`).

### rust → 1.99.0

- **What it is in the app:** the compiler of idevice's C FFI
  (`libidevice_ffi.a`, the app's self-restart after a game, decision 0029),
  and the source of the Rust standard library linked into it, so a move
  changes runtime code. Only `libidevice_ffi.a` changed in
  `app/artifacts.tsv` (6,698,688 → 6,642,912 B).
- **The lock:** `build/rust-dist.lock.json` now names the 1.99.0 manifest
  (its sha256 checked against the published `channel-rust-1.99.0.toml.sha256`)
  and the three archives from it. The notices stage reads the lock from HEAD,
  so the pin and the lock were committed first and the build ran on that
  commit. The standard-library notices passed with the selection unchanged;
  like 1.98.1, the 1.99.0 `rustc` archive has no separate BSD-3-Clause text.
  `docs/NOTICES.md` and `docs/LICENSING.md` name 1.99.0.

### stikjit → 1.9.0

- **Now main's move.** `main` took this move in `522d253` (iOS 26 deployment
  target and StikJIT 1.9.0; 0.3.2), with the same pin, zip sha256, commit and
  module-selector check in `build/stages/stikjit.sh`, and the same records.
  After the rebase onto `main` (below), `7bdc25c` kept only this evidence
  record (`7ce2b51`); `docs/DEVICE.md` is `main`'s text, which covers every
  iOS 26 version and supersedes this branch's.
- **Not the expected hold.** The plan expected a hold because "a StikJIT 3.x
  move changes the JIT script protocol". 3.x is the StikDebug app (AGPL-3.0,
  never a pin candidate); the framework the pin names is at 1.9.0, and
  [stikjit-pin-cost](2026-09-28-stikjit-pin-cost.md) measured 1.6.0 → 1.9.0:
  the script protocol (`ScriptRunner.swift`, `JITSession.swift`), the
  embedded idevice library (the `idevice/` tree is `9ed4324` in both tags,
  checked again) and `prepare_memory_region` are unchanged, and a trial IPA
  enabled JIT for Hollow Knight on this phone. So the move is cheap and made.
- **Changes:** the pin, the release zip's sha256 and the tag's commit in
  `build/stages/stikjit.sh`, and that stage's check after the swiftinterface
  rewrite, which now skips names after a Swift 6.4 module selector (`::`), as
  the cost record found; the tag and commit in `build/source-bundle.json`,
  `build/app-notices.json`, `docs/LICENSING.md` and `docs/NOTICES.md`; the
  known-good table in `docs/DEVICE.md`. No build record changed (the
  framework is not in `app/artifacts.tsv`). The StikJIT audit in
  `docs/release-audits/stikjit-rust.md` is of 1.6.0; its idevice findings hold
  for 1.9.0, whose `idevice/` tree is the same.
- **What 1.9.0 adds:** `Script.customBase64` (unused: the helper passes
  `.custom(URL)`), and the personalized DDI again below iOS 26.4. From iOS
  26.4, as on this phone (iOS 27.0), both versions mount the cryptex DDI.

### The holds

- **gbe:** `release-2026_09_27` is gbe_fork's newest release, and its `dev`
  branch head is the same commit (`7103add`). Nothing to move.
- **abseil-cpp:** the pin is the Abseil release gbe's protobuf names
  (`set(abseil-cpp-version "20250512.1")` in protobuf's
  `cmake/dependencies.cmake`, from gbe's `third-party/deps/common`). Abseil has
  newer releases (20260817.0), but it moves only when gbe's protobuf does.
- **xtool:** 1.21.0 (`d76498a`) builds with the increased-memory-limit diff
  unchanged (it applies cleanly; upstream still lacks the entitlement), but
  its SDK builder's epoch went from 2 to 3, and the app stage then stops:
  "Darwin SDK is out of date, and was installed in 'slim' mode … install a
  new SDK with `xtool sdk install`". The Darwin SDK is installed once for
  the machine (AGENTS.md, Disk) and every checkout's xtool uses it, so the
  move needs a new SDK install from Xcode for the whole workstation and moves
  every checkout together. Held; the move is that SDK install plus the pin,
  the diff's name and a rebuild of the xtool when its version differs from
  the pin (the pipeline rebuilds it only when the binary is missing). The
  workstation's xtool was rebuilt at 1.20.1 after the trial. **Owner,
  2026-10-05:** held for now; the SDK reinstall is done when convenient.
- **gstreamer:** 1.28.7 is GStreamer's newest stable release. 1.29.2 is a
  development snapshot (odd minor) with an iOS xcframework. The app links the
  release statically, and its notices come from a reviewed lock of Cerbero's
  1.28.7 recipes and the 17 source archives the registered plugins reach
  (`build/gstreamer-notices.sources.json`, `docs/release-audits/gstreamer.md`,
  release-reviewed under decision 0039). A move, to 1.29.x or a later 1.28,
  needs that audit redone; not a pin edit. Held. **Owner, 2026-10-05:**
  GStreamer stays on 1.28.7 stable; 1.29.x is a development snapshot.
- **idevice:** the pin `d32c818` is `master`'s head and v0.1.68. Nothing to
  move.
- **llvm-project:** 15.0.7 is the last LLVM 15 release. DXMT `main` (the
  pin `68af85e`) builds airconv against `llvmorg-15.0.7` (its CI's
  `LLVM_VERSION` and `docs/DEVELOPMENT.md`), and the AIR it emits is what
  Metal reads; a later LLVM is a DXMT port, not a pin move. Held.


## Rebase onto `main` 0.3.2, and the gates of rows 8–10

`deps-latest` (20 commits on `659cdab`) was rebased onto `main` `522d253`
(0.3.1, decision 0050 and 0.3.2's iOS 26 deployment target with StikJIT
1.9.0). Commits on this branch before the rebase keep their old IDs in the
text above; the IPAs were built from those.

| Before | After | Commit |
|---|---|---|
| `e71e8a7` | `62a4a82` | decision 0049 |
| `7d0f5b3` | `f516ce3` | wine 11.19 |
| `22ac169` | `c96db80` | FEX main |
| `2cd6d80` | `2516063` | DXMT main |
| `6d09073` | `a4c4e8f` | Mesa main |
| `cf020cb` | `aff1433` | DXVK master |
| `c6b8936` | `23a00df` | vkd3d-proton master |
| `b011dbf` | `119555d` | wine-valve bleeding-edge |
| `1669ff0` | `1e86afc` | freetype VER-2-14-3 |
| `a4c78a8` | `2370713` | rust 1.99.0 |
| `7bdc25c` | `7ce2b51` | stikjit 1.9.0: evidence only (above) |

- **Conflicts:** `docs/decisions/README.md` (0049 and 0050 both appended a
  row: both kept, in number order); `app/artifacts.tsv` and the three
  `build/generated/wine-pe-*.tsv` at the wine commit (resolved to this
  branch's records, since `main`'s differed only by its own builds); and
  `docs/DEVICE.md` at the stikjit commit (`main`'s text). The pin, the stage
  and the notices of the stikjit commit merged without a conflict, as `main`
  made the same change.
- **Build records:** only the final HEAD was built (`pp build --keep-outputs
  20`, dev). It rebuilt no tree and rewrote no record, so the records the
  rebase carried are the ones the final tree builds. The commits in the
  middle of the branch were not rebuilt on the new base; their records are
  those of their builds on the old base.
- **Checks:** `pp test` all passed; `pp names` and `pp secrets` clean.
- **Final IPA:** `.work/out/20261005-223917-35956f63/Playport-26.5-35956f63.ipa`,
  sha256 `35956f639b57f6bd5a905f0d29320e2b5b81fce1e834b6636d1dd13edb0b14cc`
  (verify-ipa: 79 checks passed). It has freetype 2.14.3, rust 1.99.0,
  StikJIT 1.9.0 and `main`'s iOS 26 changes. It supersedes the three per-move
  IPAs above (`60b066f7`, `8a2f0518`, `bbefed05`), which were not played: a
  gate on the final covers all three moves.
- **Reinstall of the titles:** the games had been removed from the phone.
  Installed in place over `main`'s build (`b010759f`), the final IPA kept the
  container: the setup checklist read pairing, LocalDevVPN and Steam done.
  Both titles came back through the UI with the paired Steam session
  (`pp ui --action install:APP`), with no prompt: Hollow Knight (5.23 GB) in
  34 s, Portal 2 (12.76 GB) in 157 s.
- **A JIT outage first (the phone, not the build):** the first gate at 22:45
  failed before the game: the JIT helper stopped at "checking the DDI mount"
  with `Socket ConnectionReset (idevice code 1/0)`, and a retry failed the
  same way. The gated `eb5ae2ad` (StikJIT 1.6.0), installed in place for a
  check, failed identically, so it was the phone's state; the owner fixed
  LocalDevVPN and the pairing, and the final IPA was installed again.

### Gate of the final IPA

One locked session at 22:52 (`gate.sh`: `pp install --no-build --ipa`, then
both plays with `--until first-frame+10 --shot`). Both reached
`first-frame+10` and ran on; JIT came up through StikJIT 1.9.0 each time.

| Title | JIT | runtime started | game started | first frame | Screenshot |
|---|---|---|---|---|---|
| Hollow Knight | 2.31 s | +3.10 s | +3.20 s | +9.53 s | the game's first-run language list (the reinstall reset its settings) |
| Portal 2 | 2.50 s | +3.70 s | +3.82 s | +7.48 s | black: the splash's timing, as on the earlier gates |

Hollow Knight's language was then set to English by the scripted pad
(`pp pad send`), so later runs reach the main menu again.

**Rows 8–10 gated:** freetype 2.14.3, rust 1.99.0 and StikJIT 1.9.0 pass, by
this one gate on the IPA that contains all three (no gate failed, so no
per-move bisection was needed).

### `pp perf` on the rebased final

The routes above, `--cool 15 --cool-max 20`, thermal `nominal` throughout,
on battery (90 → 88 %). Compared with the final IPA before the rebase
(`eb5ae2ad`); the windows are the walks.

| | HK `dl-final-hk` | HK `rb-final-hk` | P2 `dl-final-p2` | P2 `rb-final-p2` |
|---|---|---|---|---|
| FPS mean / p10 (whole run) | 58.3 / 54.2 | 57.1 / 52.2 | 58.7 / 55.6 | 57.7 / 41.2 |
| FPS in the window | 59.1 | 58.9 | 60.0 | 59.3 |
| main thread `002c` Mi/f | 23.0 | 22.9 | 14.1 | 14.3 |
| all threads Mi/f | 72.1 | 79.4 | 64.4 | 66.8 |
| CPU power in the window | 630 mW | 735 mW | 295 mW | 298 mW |
| hitches ≥ 25 / 50 / 100 ms | 361 / 10 / 5 | 224 / 18 / 10 | 302 / 20 / 8 | 257 / 21 / 10 |

- **Not a like-for-like pair.** Both titles were installed afresh just
  before, so these were their first runs on new files: Hollow Knight had
  lost its settings (and so, likely, the profile-1 save the route lands in:
  a 942 ms frame at t = 40 s fits the new-game path), and Portal 2's first
  map load ran to t ≈ 67 s instead of ending before t = 60 s, which moves
  its load hitches into the play segment (≥ 50 ms 13 there, from t = 61.9 to
  67.2 s).
- The main thread does the same work a frame in both titles (23.0 → 22.9,
  14.1 → 14.3 Mi/f), and Portal 2's walk is the same (59.3–60 FPS, 295 →
  298 mW). Hollow Knight's other threads did 10 % more work in its window,
  on a route whose scene probably differed. No regression is read from this
  pair; a repeat once both titles are back in their usual state would
  settle it.

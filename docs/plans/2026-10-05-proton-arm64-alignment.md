# Plan: align with Valve's ARM64 Proton

**Linear:** [PLA-76](https://linear.app/playportdev/issue/PLA-76).
**Review 2026-10-13:** step 1 is done (rows 2–10 moved or held; row 11
superseded by [0054](../decisions/0054-madeira-frozen.md)). Step 2, item by
item (each marked below):

| Item | Status |
| --- | --- |
| A0 Proton data in `FEXProfile` | done (3bbc21d); re-read 2026-10-17 (W2): data unchanged, `protonSource` names bleeding-edge `47c39230` |
| A1 `MaxInst=500` | done ([0055](../decisions/0055-maxinst-500-global.md)) |
| A2 WoW64 suspend/termination | done: came with FEX `main`, then adapted to iOS's real suspend by patches (PLA-93, 222, 223, 226, 229, 302, 304); leftovers open in their own issues |
| B1 disk cache default | done: on by default ([0056](../decisions/0056-fex-disk-cache-on.md), [2026-10-14 evidence](../evidence/2026-10-14-fex-disk-cache-on.md); PLA-341): the warm-start crashes were rpmalloc's one-block pages (rpmalloc 0004) |
| B2 Valve Wine past stable | done (`wine-valve` from bleeding-edge, `pp sync` lists it); questions 4 and 5 answered |
| B3 LAA for i386 | closed (W6, [evidence](../evidence/2026-10-17-i386-laa.md)): every i386 game image checked (Portal 2, DiRT 3, MKKE) is LAA, so Valve's override would change nothing; reopen when a played i386 title's image lacks the flag and fails near 2 GiB |
| B4 child-process FEX profiles | designed, not implemented (W3, [evidence](../evidence/2026-10-17-fex-child-profiles.md)): `FEX_APP_CONFIG` works per pseudo-process; waits for a played title with a child entry (B6 is closed) |
| B5 release log defaults | done (2331995) |
| B6 Steam appinfo FEX settings | closed (W4, [evidence](../evidence/2026-10-17-steam-appinfo-fex.md)): the only public value, `tso_enable`, is Auto for every reviewed title, Portal 2 included; Hollow Knight has none; reopen when a played title's is Force On or Off |
| B7 CPU topology | closed (W5, [evidence](../evidence/2026-10-17-cpu-topology.md)): six equal cores, `EfficiencyClass` 0, as Valve's Proton shows on ARM; Valve's `WINE_CPU_TOPOLOGY` would be unset on the phone; reopen when a played title reads the class |
| C table into ARCHITECTURE.md | done ([section](../ARCHITECTURE.md#valves-arm64-proton-items-not-carried), W1) |
| Portal 2 follow-ups | open, not re-measured |

Older "not started" lines below describe the original snapshot.

**Pins now (Review 2026-10-13, `pins.lock`, not changed by this review):**
`madeira` 8c050d0 (frozen, 0054), `wine` 455e350 (wine-11.19),
`wine-valve` 750fd01 (bleeding-edge), `fex` 3648ee9 (`main`), `rpmalloc`
09142d7, `dxmt` 68af85e, `mesa` b39d173, `dxvk` e5ffd0f, `vkd3d-proton`
31d1f89, `gbe` 7103add (release-2026_09_27); port rows `wine-port` 723d1bf,
`dxmt-port` ca8a251, `fex-port` 0f8edf8, `rpmalloc-port` 1f271c0 (frozen
provenance records, 0054); `freetype` VER-2-14-3, `llvm-project` 15.0.7,
`abseil-cpp` 20250512.1, `xtool` 1.20.1, `stikjit` 1.9.0, `gstreamer`
1.28.7, `idevice` d32c818, `rust` 1.99.0, and since this plan `ca-bundle`
2026-09-25 (7bebfdf, PLA-40) and `wine-mono` 11.3.0 (1a10332, PLA-125). No
component row has moved since the 2026-10-05 moves; upstream heads were not
re-read in this review.

**Date:** 2026-10-05. **Kind:** plan; step 1 done, step 2 partly done
(Review 2026-10-13). **Pins read:**
`pins.lock` at the commit that adds this plan (`madeira` 8c050d0, `wine`
wine-11.18, `wine-valve` dc26e61, `fex` FEX-2609.1, `dxmt` 7c8dee1, `mesa`
82d4f86, `dxvk` 52fe923, `vkd3d-proton` 472989a, `gbe` release-2026_09_27).

## Runner state (workstation only, 2026-10-17)

- **Branch:** `dev/pla-76-proton-alignment-ws`, off `main` at f7ac25f, in the owner-authorized
  side copy `$PLAYPORT_BUILD/worktrees/pla-76-proton-alignment`. The owner authorized it to
  build (2026-10-17, beyond decision 0069): its own `.work` holds reflinked copies of main's
  `cache`, `inputs` and `run`, with build directories that named main's path removed. No
  install or phone. Its build records are not canonical (the build path differs); main's build
  regenerates them after merge. Not merged, not pushed.
- **Queue, one writer per item:** W1 the C table into ARCHITECTURE.md; W2 A0 re-read against
  Valve's current bleeding-edge (FEX config, app profiles, ARM defaults); W3 B4
  `FEX_APP_CONFIG` in one Mach process (source reading, a design); W4 B6 what Steam appinfo
  carries for 620 and 367520 and whether Playport's PICS client sees it; W5 B7 what Wine on iOS
  reports for P and E cores (source, desktop Wine where it answers); W6 B3 close or name a
  blocker; W7 [PLA-389](https://linear.app/playportdev/issue/PLA-389): FEX to Valve's
  `5285020d` by `pp rebase` (or b49837f alone if the rebase is out of reach), built to a verified
  dev IPA; W8 [PLA-390](https://linear.app/playportdev/issue/PLA-390): wine 11.20 and
  `wine-valve` c53678a, built likewise. Each ends in evidence or a plan rewrite; phone gates
  (Hollow Knight first frame+10 on the exact IPA) stay owed.
- **Not here:** B1 (done), the Portal 2 follow-ups (phone), installs.
- **Running:** W1 done (the commit adding [the C table](../ARCHITECTURE.md#valves-arm64-proton-items-not-carried)); W2 done
  ([2026-10-17 snapshot](#valves-reference-snapshot-2026-10-17)); W3 done (B4 designed,
  [evidence](../evidence/2026-10-17-fex-child-profiles.md); follow-up PLA-391); W4 done (B6 closed,
  [evidence](../evidence/2026-10-17-steam-appinfo-fex.md)); W5 done (B7 closed,
  [evidence](../evidence/2026-10-17-cpu-topology.md)); W6 done (B3 closed,
  [evidence](../evidence/2026-10-17-i386-laa.md)); W7 done (`fex` 5285020d and `rpmalloc` ed22744,
  a verified dev IPA, [evidence](../evidence/2026-10-18-fex-5285020d.md); phone gates owed); W8 done
  (`wine` wine-11.20 and `wine-valve` c53678ab, a verified dev IPA,
  [evidence](../evidence/2026-10-18-wine-11.20.md); phone gates owed); queue (one writer each): W9
  [PLA-393](https://linear.app/playportdev/issue/PLA-393), `pp rebase` checks each written
  patch applies where its pick did (running); W8b the hand port of WineHQ 7fb24b7 (reserved
  CPSR bits) into `signal_arm64_ios.c` and `thread_ios.c`, built to a verified IPA. Reports: `agent-notes/pla-76/reports/` in the side copy's build area.

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
- Madeira (frozen at `8c050d0` since decision 0054), DXMT, Mesa, DXVK, vkd3d-proton: their `main`/`master` heads
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

## Order across the plans (owner, 2026-10-05)

One sequence for this plan and
[the dependency strategy](finished.md#dependency-strategy):

| Order | What | From |
|---|---|---|
| 1 | Sync tooling for Madeira's reorganisation: `research/dxmt` → `dxmt` in `tools/sync.py` and `build/pipeline`, and what `madeira-dock` means for `sources` | strategy, step 0 |
| 2 | The rebase helper (rerere, conflict trial, `range-diff`, re-export), proven on the FEX → `main` move | strategy, step 1 |
| 3 | Wine, FEX, DXMT, Mesa, DXVK, vkd3d-proton and the rest to latest, one per commit. **Rows 2–7 and 2b done** (decision 0049, e71e8a7..b011dbf, one commit and IPA each): every IPA passes the gate on both titles; the final build does less CPU work a frame than the baseline, and Portal 2's ≥25 ms load-segment hitch count (52 → 134 in the first pair) is run-to-run spread, the baseline alone spanning 52–268 over three runs ([deps-latest](../evidence/2026-10-05-deps-latest.md)). **Rows 8–10 done** (1e86afc, 2370713, 7ce2b51 after the rebase): freetype VER-2-14-3, rust 1.99.0 and stikjit 1.9.0 moved, one commit and IPA each; gbe, abseil-cpp, idevice, llvm-project, xtool (needs a machine-wide Darwin SDK reinstall) and gstreamer (a new release needs a new licensing audit) held, each with its reason. Every `pins.lock` row except `madeira` (order 5) is now moved or held. **DONE (2026-10-05):** the branch was rebased onto `main` 0.3.2 (which had taken the StikJIT 1.9.0 move itself), and one gate on the rebased final IPA `35956f63`, which contains all three moves, passed on both titles (JIT 2.31 / 2.50 s, first frame +9.53 / +7.48 s); xtool and GStreamer held by the owner | alignment, step 1 (rows 2–10) |
| 4 | Madeira reconciliation: per overlapping area (i386/WoW64, in-process sync, winegstreamer, D3D9, DXMT slots 145–149), whose design Playport runs. **Superseded by [0054](../decisions/0054-madeira-frozen.md) (Madeira frozen); `madeira-main` kept as a reference branch.** | strategy, step 2 |
| 5 | Madeira to `main`, re-porting its fork deltas once, onto the new bases. **Superseded by [0054](../decisions/0054-madeira-frozen.md) (Madeira frozen); `madeira-main` kept as a reference branch.** Fastsync is ported onto `8c050d0` as Playport patches | alignment, step 1 (row 11) |
| 6 | The alignment items (A, B) and the Portal 2 performance follow-ups | alignment, step 2 |

Steps 1–2 come first because the helper pays off on the moves of step 3; step 4
needs Madeira `main` as it is when Madeira is next. Nothing is offered upstream
(owner, 2026-10-05): every patch stays carried.

## Valve's reference snapshot (2026-10-17)

Re-read by W2 from ValveSoftware/Proton and ValveSoftware/wine (blobless clones in the build
area). Every ARM64 Proton branch carries a commit only for its gitlinks on top of its Proton
base, so `ae4e5bc925d7` (which `protonSource` named) is not an ancestor of today's head.

| Proton branch | Head | FEX | Wine (ValveSoftware/wine) | DXVK | vkd3d-proton |
|---|---|---|---|---|---|
| proton_11.0 (stable) | `bc896217` (10-09) | `1cc4b93e` (FEX-2607) | `e60892cc` | `a6764047` | `212991fc` |
| experimental_11.0 | `7a94df49` (10-14) | `5285020d` (FEX main, 10-13) | `7fc704ef` | `a78a467c` | `0bb64c56` |
| bleeding-edge | `47c39230` (10-17) | `5285020d` (FEX main head, 10-13) | `c53678ab` (bleeding-edge head, 10-16) | `c8679a55` (master head, 10-17) | `0bb64c56` (master head, 10-14) |

Against `ae4e5bc925d7` and Playport:

- `FEX_Config.json` (the 8 keys) and `fex_application_profiles` (292030 `setup*` →
  `X87ReducedPrecision=0`) are byte-identical on all three branches and to `ae4e5bc925d7`:
  `FEXProfile` needs no data change; only `protonSource` moved.
- The ARM defaults are unchanged: `FEX_DISKCACHE=1` and `WINE_CPU_TOPOLOGY` from affinity on
  experimental and bleeding-edge only, `generate_fex_app_config` (appinfo TSO/Multiblock,
  `SilentLog`, `AppOverrides`) and `FEX_APP_CONFIG_LOCATION` as before. No FEX, MaxInst, LAA
  or other ARM64 default is new. `Makefile.in` did not change.
- Proton's own commits since (`1ef4b65a` WoW64 for 4005300 on x86_64 hosts only, two
  lsteamclient fixes, `f413b3fa` nvapi off without an NV kernel driver): nothing to carry.
- Playport is behind bleeding-edge on FEX (`3648ee9`, 29 commits; FEX-2610 tagged 10-07),
  `wine-valve` (`750fd01`, 36 commits, all listed by `pp sync`), `wine` (wine-11.19; WineHQ
  tagged wine-11.20 on 10-16), DXVK (`e5ffd0f`, 61) and vkd3d-proton (`31d1f89`, 9). `pp sync`
  reports only the `wine-valve` gap (`wine-valve-new.tsv`); it reads neither Proton nor the
  FEX, WineHQ, DXVK and vkd3d-proton heads.

Follow-ups from this re-read (to file in Linear; none blocks an item here):

1. FEX `5285020d`: `b49837f` fixes a race on the disk cache's data blob (cache on by default
   since 0056); `aad2c96`, `4dbb046` and `3a2b1c0` change ARM64EC's `Module.S` (NT syscall
   numbers read at run time, `NtDllRedirectionLUT` bounds in `CheckCall`), where fex-port
   patches also apply; `e3f402a`/`b2dffb5` bump the disk-cache key and version beside fex
   0041–0044; `679d6c7` moves `External/rpmalloc` (`09142d7` → `ed22744`). Port `b49837f` or
   move the pin (0049); either needs a build and a Hollow Knight play.
2. `wine-valve` `750fd01..c53678a`: the ARM64-relevant picks are WineHQ commits in wine-11.20:
   `f9a7e33` (reserved CPSR bits; its `signal_arm64.c` half lands in Madeira's
   `signal_arm64_ios.c` only by a hand port), `9de060e`/`e408a5a`/`c9e2884` (ARM64
   Acquire/Release without a full barrier, `winnt.h`), `b2a60dc` (`RtlWaitOnAddress` queue) and
   `ea85d1c` (thread group affinity under process affinity, B7). A wine-11.20 move brings them.
3. DXVK and vkd3d-proton heads moved past their pins; no ARM64-specific change was looked for.

### Earlier snapshot (2026-10-05, history)

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

Re-read the heads before starting. Valve moves these branches weekly. (On 2026-10-05
`ae4e5bc925d7` replaced `b3749405` on bleeding-edge, with FEX `7d3090f7`.)

## Step 1: every dependency to its latest version

### Rules for every move

- **One dependency per commit.** The only exception is `rpmalloc`: its row is
  defined as the FEX commit's `External/rpmalloc` gitlink, so it moves in the
  same commit as `fex`. The commit carries the pin, the re-ported series, the
  build records (`app/artifacts.tsv`, `build/generated/wine-pe-*.tsv`) and an
  evidence record `docs/evidence/<date>-<dep>-<sha8>.md` with the IPA sha256.
- **How each moves**, per AGENTS.md "Pins" and UPSTREAM-SYNC.md:
  - Madeira does not move: it is frozen at `8c050d0` (decision 0054); `pp sync` reports its new commits.
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

**Status (2026-10-05):** rows 2, 2b and 3–7 moved, one commit each, gated on both titles. Rows 8–10: freetype, rust and stikjit moved and gated (one gate on the final IPA rebased onto `main` 0.3.2, `35956f63`); gbe, abseil-cpp, idevice, llvm-project, xtool and gstreamer held with their reasons. Row 11 (`madeira`) not started. The step-1 deliverable (every row moved or held with a reason) holds apart from row 11. See [deps-latest](../evidence/2026-10-05-deps-latest.md). Open question 5 is answered there: WineHQ's `dlls/wow64` does not read `ChpeV2CpuAreaInfo`; ntdll's unix side does, which on Playport is `signal_arm64_ios.c` and `thread_ios.c`.

Madeira moves **last** (owner, 2026-10-05). The rule that the `*-port` rows equal
Madeira's gitlinks constrains only the port rows; the `wine`, `fex` and `dxmt`
base rows move under their current port rows, as 0007, 0008 and 0013 did.
Before the base moves, add the rebase helper of the dependency-strategy plan
(rerere, conflict trial, range-diff, re-export).

| # | Row(s) | Pin now | Latest upstream (2026-10-05) | Valve's choice | Notes |
|---|---|---|---|---|---|
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
| 11 | `madeira` | `8c050d0` | `main` `bbbf8d0` (2026-10-04), 438 commits ahead | (none) | **Superseded by [0054](../decisions/0054-madeira-frozen.md): frozen at `8c050d0`; `madeira-main` kept as a reference branch.** Before that: `pp sync`. If Madeira moved its Wine, DXMT, FEX or rpmalloc, the sync holds (`*-port-moved`). Re-port the `patches/*-port` series and the `madeira-port` patches at the end of `madeira-unix`, then land the port rows and the Madeira pin together in one commit (UPSTREAM-SYNC.md). Last (owner, 2026-10-05), after the Madeira reconciliation of `finished.md#dependency-strategy` (its steps 0 and 2: the sync tooling for Madeira's reorganisation, then a decision per overlapping area), so that Madeira's fork deltas are re-ported once, onto the new bases. |

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
- **Playport-only addition:** LRCPC2 from the host. *Review 2026-10-13:* now
  every host feature FEX cannot read on iOS: the app reads the kernel's
  `hw.optional.arm.FEAT_*` and passes `disable<x>` for each one reported 0
  (PLA-132, 33162cf and 08c02fc,
  [host-cpu-features](../evidence/2026-10-13-host-cpu-features.md)). Our phone's
  string is unchanged (`enablelrcpc2`); an A12 gets
  `disableflagm,disableflagm2,disableafp`.

Each item below has its change, its expected effect, its risk, the measurement
on the phone and whether it needs a decision record.

### A. Adopt after measurement

**A0. Refresh the Proton data in `FEXProfile`.** *Done (Review 2026-10-13):
3bbc21d (2026-10-06) checked the data against bleeding-edge `ae4e5bc925d7`
(2026-10-05). Re-read 2026-10-17 (W2): bleeding-edge `47c39230`, experimental_11.0
`7a94df49` and proton_11.0 `bc896217` carry the same 8 keys and profile; `protonSource`
names them, no data or test changed ([snapshot](#valves-reference-snapshot-2026-10-17)).*
- **Change:** `protonSource` still names bleeding-edge `c9e0da9d736c`
  (2026-09-26). Update it to the heads in the snapshot table, and diff the
  8 keys and `fex_application_profiles` again.
- **Expected effect:** none at runtime; the data stays current.
- **Risk:** low.
- **Phone measurement:** none. `swift test` covers it.
- **Decision record:** no.

**A1. Global `MaxInst=500`.** *Done 2026-10-06 (decision 0055): taken as Proton's
default without the sweep below, at the owner's direction.*
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

**A2. WoW64 CHPEv2 suspend/termination (FEX side).** *Done (Review
2026-10-13).* The three commits came with FEX `main` `3648ee9` (c96db80,
[deps-latest](../evidence/2026-10-05-deps-latest.md)). The risk below was
real: iOS's real suspend holds a thread only at a safe point and otherwise
defers, so `b1e54d8`'s wait through `NtGetContextThread` does not mean the
thread has stopped. Playport adapted the contract in patches, each with its
evidence; no decision record was written:
- PLA-223, a terminated WoW64 thread ran on into its freed CPU area
  (`TEB+0x1788`, `ChpeV2CpuAreaInfo`): fex 0027 keeps another thread's FEX
  state, fex 0028 with madeira-unix 0129 counts a write hold as unsafe
  ([fex-thread-faults](../evidence/2026-10-12-fex-thread-faults.md)).
  PLA-224 in the same record is not a suspend issue: the stale-pointer heal
  resolved a child's DLLs for the wrong process (madeira-unix 0128).
- PLA-222, a killed thread busy in FEX: madeira-unix 0130 rings FEX's
  `SuspendDoorbell` and ends it at `brk #0xCAFE`; PLA-226, the ARM64EC
  `ThreadTerm` race: fex 0029
  ([killed-threads](../evidence/2026-10-12-killed-threads.md)). PLA-230: 0140
  rings it for a terminating process's threads too, 0139 fixes the window
  teardown ([killed-threads-teardown](../evidence/2026-10-13-killed-threads-teardown.md)).
- PLA-229, a killed i386 thread in an in-process wait: madeira-unix 0142,
  wine-unix 0037, wine-pe 0043
  ([killed-wait-shared-queue](../evidence/2026-10-13-killed-wait-shared-queue.md)).
- PLA-302/304, another thread's context: madeira-unix 0136, 0137, wine-unix
  0036, fex 0037, wine-pe 0042
  ([wow64-thread-context](../evidence/2026-10-13-wow64-thread-context.md)).
- PLA-93, a real suspend held a thread inside FEX's module: madeira-unix 0143
  ([pla93-fex-code-safe-point](../evidence/2026-10-13-pla93-fex-code-safe-point.md)).

Left open in those records (all still open in Linear, 2026-10-13): PLA-225 (a
cross-terminated thread's kept FEX state leaks about 18 MB of band), PLA-229's
x86-64 killed waiters (now PLA-314), PLA-303 (`SetThreadContext` on a running thread). The
measurement below (Portal 2 pause/resume ×10, `[sync-census]` before/after)
was not run as written; the childabort and threadctx probes, the gates on both
titles and PLA-93's 20 Hollow Knight plays stand in for it.
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

**B1. FEX disk cache on by default** (Valve experimental/bleeding-edge, Proton `09d3d6e5`). *2026-10-06 (decision 0056): the Witcher 3 warm-start crash was a disk-cache
key bug, fixed by `patches/fex` 0021; the default is held off: Hollow Knight's warm
start corrupts rpmalloc (open); WoW64 keeps it off (0022); 5 GB budget and a
Settings action.* *Open (Review 2026-10-13): still held,
`FEXProfile.defaultDiskCache = false`; no later evidence on the Hollow Knight
crash. The Witcher 3 with its cache on crashed again in FEX on 2026-10-07
([pool-x64-images](../evidence/2026-10-07-pool-x64-images.md)). The cache key
now faces host features that vary by phone (PLA-132), the risk named below.*
*Done 2026-10-14 (PLA-341, [2026-10-14 evidence](../evidence/2026-10-14-fex-disk-cache-on.md)): both warm-start crashes were one rpmalloc bug, a
full page of one 7–8 MB block freed as if it were on the available list
(`patches/rpmalloc` 0004); the cache key now includes the FEX build (`patches/fex`
0041) and one database serves every TEB slot (0042, replacing 0021's per-slot
databases). `FEXProfile.defaultDiskCache = true`. Host features were already in
FEX's machine bucket.*
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

**B2. Valve Wine ARM64 commits past stable (experimental-only).** *Done
(Review 2026-10-13): `wine-valve` picks from bleeding-edge `750fd01`
(119555d); the suspend-helper reverts needed nothing, and `pp sync`'s
`wine-valve-new.tsv` now lists bleeding-edge
([deps-latest](../evidence/2026-10-05-deps-latest.md#wine-valve--valves-bleeding-edge)).
Questions 4 and 5 are answered below.*
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
- **Decision record:** covered by step 1's pin-policy record (`wine-valve`
  from bleeding-edge). Also teach the `pp sync` report to list bleeding-edge:
  today it lists only proton_11.0, so newer Valve deltas are invisible to it.

**B3. Large address aware for i386 (`WINE_LARGE_ADDRESS_AWARE`, on by default in Proton).**
*Closed 2026-10-17 (W6, [evidence](../evidence/2026-10-17-i386-laa.md)).* Playport gives a
WoW64 child 4 GiB or 2 GiB of its window from the image's own flag (madeira-unix 0063 and
the window patches; nothing reads the variable). Valve Wine (still in bleeding-edge
`c53678a`; the 2026-10-14 address-space reverts do not touch it) ORs the flag with
`WINE_LARGE_ADDRESS_AWARE`, on unless set to `0`, in ntdll and the i386 `kernel32`
`GlobalMemoryStatus`; Proton sets it except for three `noforcelgadd` titles, none in
Playport's list. Every i386 game image checked carries the flag (Portal 2, DiRT 3, MKKE);
only a launcher, a tool and an uninstaller do not. No decision record: the policy is
unchanged.
- **Reopen when** a played i386 title's game image lacks the flag and its guest
  allocations fail near 2 GiB. Then: one helper (flag OR override) at every site the
  evidence lists, Valve's `GlobalMemoryStatus` change as a `wine-pe` patch, Proton's
  `noforcelgadd` titles as data, and a phone gate on that title and Hollow Knight.

**B4. Per-executable FEX profiles for child processes.** *Designed, not
implemented (2026-10-17, W3; [evidence](../evidence/2026-10-17-fex-child-profiles.md)).*
- **Found:** `FEX_APP_CONFIG` works in one Mach process. Each pseudo-process
  loads its own emulator copy. Its `ProcessInit` (`BTCpuProcessInit` for WoW64)
  loads FEX's config from that process's PEB environment and matches
  `AppOverrides` against its own executable name.
- **The obstacle is ours:** Playport exports every value as `FEX_*`, and every
  child inherits those variables. The environment layer sits above
  `FEX_APP_CONFIG`, so it would mask a `setup*` entry in every process.
- **Design:** follow Proton. A per-launch file named by `FEX_APP_CONFIG` takes
  the keys the game's entries set (Proton's global value in `Config`, the
  entries in `AppOverrides`), and those keys leave the environment. A key the
  game's page chose stays in the environment. A game without entries is
  unchanged.
  - Code points: `FEXProfile.launch`, which adds `appConfig`;
    `LaunchCoordinator.applyEnvironment`, which writes the file outside
    `fex-emu` and sets the variable; a `patches/fex` log line with each
    process's effective values; the x87 footer on the game's page.
  - The evidence lists the host tests and the phone checks: Hollow Knight,
    The Witcher 3 and its `setup*` child, which is not yet identified.
- **Why not now:** it changes what `witcher3.exe` itself receives, through a
  file FEX has never been shown to read on the phone. It also needs a build,
  a FEX patch and phone runs, and no played title has a child entry.
  Implement it when one does. B6 is closed; if it reopens, Steam's TSO value goes
  in the same file.
- **Decision record:** yes, at implementation (extends 0021; the draft is in
  the evidence).

**B5. Release-build log defaults.** *Done (Review 2026-10-13): 2331995
(2026-10-06). The release runtime already set `WINEDEBUG=-all`; it now also
sets `DXVK_LOG_LEVEL`, `VKD3D_DEBUG` and `VKD3D_SHADER_DEBUG` to `none`
without overwrite (`WineHostRuntime.quietRuntime`). The release play comparing
log size and CPU was not recorded.*
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
*Closed with a reason (2026-10-17, W4; [evidence](../evidence/2026-10-17-steam-appinfo-fex.md)).
This was a reading of public PICS records and source. No runtime change was made.*
- **Source:**
  - TSO comes from the public PICS key
    `common/steam_frame_compatibility/configuration/tso_enable`, part of the Steam
    Frame review block. Steam's UI calls it *ARM Translation Memory Ordering*:
    0 is Auto, 1 Force On, 2 Force Off, and the player can override it.
  - No appinfo key for Multiblock exists. The only Multiblock in the client is the
    player's *Override ARM Translation Options* string, the format that Proton's
    `STEAM_COMPAT_FEX_CONFIG` parses.
  - How the ARM64 client turns either value into `STEAM_FEX_*` was not seen. The
    x86 client does not name the variables.
- **Values:**
  - Portal 2 (620): 0 (Auto), Frame-verified.
  - Hollow Knight (367520): no Frame block.
  - All 21 records with the block, out of 115 public records read (The Witcher 3,
    RDR2, Cyberpunk, BG3 among them): 0.
- **Playport:** the PICS client receives each full record
  (`Library.swift:177-215`), but `SteamAppInfo.parse` keeps none of this block
  (`SteamApp.swift:80-112`).
- **Why closed:** Auto leaves FEX at Proton's global `TSOEnabled=1`, which Playport
  already uses (0021). Carrying the key would change no played title. 0021's "not
  public" is now half true; it was not amended, because nothing is carried.
- **Reopen when:** a played title has `tso_enable` 1 or 2, or a Multiblock key
  appears. The design is in the evidence:
  - an optional `SteamAppInfo` field;
  - a `FEXProfile.launch` layer between Proton's entry and the page's picker;
  - B4's file, if B4 exists by then;
  - a decision record amending 0021 (remote data feeding a launch default).

**B7. `WINE_CPU_TOPOLOGY` from affinity** (experimental/bleeding-edge).
*Closed with a reason (W5, 2026-10-17,
[evidence](../evidence/2026-10-17-cpu-topology.md)). Source only; no phone reading.*
- **What the guest sees:** six equal cores in one package, no SMT, `EfficiencyClass` 0 on
  every core and CPU set, one NUMA node, one group of 6.
  - The source is WineHQ's Apple branch of `create_logical_proc_info` (from `hw.physicalcpu`,
    `hw.cacheconfig` and the top-level `hw.l*cachesize`). Playport compiles `system.c`
    unreplaced.
  - Each core is told one cluster's cache sizes.
  - With unequal clusters, an L2 mask can name CPUs that do not exist.
- **`WINE_CPU_TOPOLOGY`:** absent from our tree, since `wine-valve` did not pick it. Even
  picked, on iOS it would only lower the count.
- **Valve on a phone:** Proton's `9ccc0607` sets the variable only when the affinity is
  narrower than all CPUs, so Valve's value here would be unset. Valve's Wine finds P cores
  only through Intel's `/sys/devices/cpu_core/cpus`, so on ARM it too reports class 0. We
  match Valve.
- **Why not report P cores:**
  - `hw.perflevelN.*` gives counts, not CPU numbers, and the guest sees real numbers
    (`pthread_cpu_number_np`).
  - Affinity is bookkeeping only on iOS.
  - No played title is known to read the class.
  - A hybrid-aware engine could drop to 2 workers.
- **Reopen when:** a played title sizes or places work by `EfficiencyClass` or CPU sets, or a
  phone reading gives the cluster-to-CPU mapping. The change then: a `wine-unix` patch to the
  Apple branch, from `hw.perflevelN.*`, with a Hollow Knight gate.
- **Seen in passing:** FEX's CPUID reports one core on iOS (one MIDR entry), against six from
  `GetSystemInfo`.
- **Earlier:** on the desktop, `WINE_CPU_TOPOLOGY=6:…` did not change Tomb Raider's draw
  fault ([tomb-raider-draw-diagnostics](../evidence/2026-10-10-tomb-raider-draw-diagnostics.md)).
- **Decision record:** none (nothing changed).

### C. Not applicable on iOS (record the reason, do not copy)

*Review 2026-10-13: not yet copied into ARCHITECTURE.md (Done when).* *2026-10-17 (W1):
copied into [ARCHITECTURE.md](../ARCHITECTURE.md#valves-arm64-proton-items-not-carried), with two rows re-worded there: the UnixLib row
names fex-port 0030 (its entry points are no-ops), and the fsync row says fastsync is on
by default (0054), madsync off (0023).*

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

*Review 2026-10-13: the first three are written. The plan's "decision 0049"
is [0049](../decisions/0049-latest-pins.md), the latest-pins record (accepted
2026-10-05, its `madeira` row replaced by 0054); it also says Valve is the
reference, not the base, which covers part of the optional policy record. Its
small-and-frequent moves have not happened since 2026-10-05.*

- Latest-possible pins (step 1, owner's direction): FEX `main`, `wine-valve`
  from bleeding-edge, every other dependency at its branch head; supersedes
  the pin-source parts of 0008, 0013 and 0018. **Written: 0049.**
- `MaxInst=500` (A1): supersedes part of 0021. **Written: 0055.**
- Disk cache default (B1). **Written: 0056 (default held off).**
- LAA for i386 (B3). *Not needed: closed 2026-10-17 with the policy unchanged.*
- Child-process FEX profiles through `FEX_APP_CONFIG` (B4), at implementation:
  extends 0021 (draft in the [evidence](../evidence/2026-10-17-fex-child-profiles.md)).
- Optionally, a standing policy record that "Valve's ARM64 Proton is the
  reference platform", naming which branch is the reference for which kind of
  change.

## Open questions

1. *(Settled 2026-10-05: FEX `main`.)*
2. *(Settled 2026-10-05: Proton bleeding-edge is the reference.)*
3. Does `portal2.exe` carry the LAA flag, and what WoW64 limit does
   `virtual_ios.c` give non-LAA images? *Review 2026-10-13: yes; the
   workstation copy with the 2026-10-01 record's sha256 (`18b57b16…`) has
   Characteristics `0x0122` (`IMAGE_FILE_LARGE_ADDRESS_AWARE` set). A non-LAA
   image gets its window's 2 GiB, an LAA one 4 GiB (madeira-unix 0063).*
4. Do Madeira's `*_ios.c` replacements override the WineHQ files that contain
   `0b8d0add`, `3b6b0ced` and `f286074a` (B2)? *Review 2026-10-13: only one
   half of one. `0b8d0add` and `f286074a` change only
   `dlls/ntdll/signal_arm64ec.c` (the PE side, WineHQ's own file). `3b6b0ced`
   also sets `InSimulation = 1` in `unix/signal_arm64.c`; the built
   `signal_arm64_ios.c` sets it at both sites (`restore_context` and
   `usr2_handler`, read in the build area's tree).*
5. Does WineHQ wine-11.19 wow64 consume `ChpeV2CpuAreaInfo` as FEX `af04940`
   assumes, or did Valve's experimental Wine carry a counterpart? *Answered in
   [deps-latest](../evidence/2026-10-05-deps-latest.md): wow64 does not read
   it; ntdll's unix side does (`signal_arm64_ios.c`, `thread_ios.c` here).*
6. Is the Witcher 3 warm-cache crash a FEX disk-cache bug, an rpmalloc-port
   bug or a Madeira bug? It blocks B1. *Answered by 0056: a disk-cache key bug
   (fex 0021). Hollow Knight's warm-start rpmalloc corruption now blocks B1.*
7. How large a FEX disk cache is acceptable on the phone? *0056: 5 GB, or
   cleared under 10 GB free.*

## Portal 2 performance follow-ups

Handed over from the Portal 2 plan ([finished](finished.md#portal-2)) (owner, 2026-10-05).
*Review 2026-10-13: open. No 300 s human-play `pp perf` of Portal 2 against
`p2-human-720-x87` is recorded since; later Portal 2 `pp perf` runs use the
120–140 s pad route as A/B checks of other changes (for example
[fastsync-on-8c050d0](../evidence/2026-10-06-fastsync-on-8c050d0.md),
[jit-alias-release](../evidence/2026-10-12-jit-alias-release.md)).*
Target: a steady 720p at 60 FPS, also after the phone reaches "serious". Measure
every change with the owner's play, as the earlier runs did:
`pp perf --title app-620 --secs 300 --settings '{"screen":"720"}'` (300 s, a
death and reload included), compared with `p2-human-720-x87` (58.4 mean, 53.8
p10) by `pp perf --compare`.

- **P cores taken away at the thermal limit.** Late in each human play iOS moves
  the whole process to the E cores (P under 20 %) and FPS falls to 44–55, with
  every thread at `USER_INTERACTIVE`. Less CPU per frame is the lever. Re-measure
  after step 1 (FEX main, Wine and Mesa heads) and after A1 (`MaxInst=500`).
- **Death reload hitches** (0.2–0.6 s): the game's load at the thermal limit,
  13,000 selects and 9,000 event operations in its busiest second.
- **A pipeline's first Metal build** (0.2–0.4 s, once per install): a Metal
  binary archive in KosmicKrisp (see `docs/evidence/2026-10-04-portal2-shader-cache.md`).
- **Footprint growth** (about 4 MB a minute in a chamber; 35–40 MB a minute in
  human play including new areas): whether it levels off in a 30-minute run.
- **Wineserver requests:** 71 a frame in human play; `SetCursorPos` and its
  messages (9 a frame) are kept for Windows' semantics; `create_event` and
  `close_handle` (5 a frame) are unattributed.

## Done when

*Review 2026-10-13: the first item is met
([deps-latest](../evidence/2026-10-05-deps-latest.md)); A0, A1, A2, B2 and B5
are closed, B1 has a named blocker, B3, B4, B6 and B7 are open; the C table is
in ARCHITECTURE.md (2026-10-17, W1); the x86-64-only line is gone (ARCHITECTURE.md now
says i386 guests run through WoW64).*

- Step 1's evidence record lists every `pins.lock` row as moved or held with a
  reason, each with gate and `pp perf` results, and the Valve-versus-upstream
  difference table.
- Every item in A and B is adopted (with its evidence and decision record),
  closed with a reason, or left with a named blocker. The table in C is copied
  into ARCHITECTURE.md.
- The stale "Guests are x86-64 only" line in ARCHITECTURE.md is corrected
  (0047).


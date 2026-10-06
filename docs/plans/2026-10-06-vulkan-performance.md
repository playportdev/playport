# Plan: Vulkan at least on par with DXMT, on Hollow Knight in Direct3D 11 and 12

**Date:** 2026-10-06. **Kind:** plan, not started. **Pins read:** as in the
[KosmicKrisp-default plan](2026-10-06-kosmickrisp-default.md): `mesa` b39d173 (a
Mesa `main` commit of 2026-10-05; `main` was 54 commits ahead on 2026-10-06, none
of them in `src/kosmickrisp` or the Metal WSI) + `patches/mesa` (16), `dxvk` e5ffd0f (unmodified), `vkd3d-proton` 31d1f89 +
`patches/vkd3d-proton` (4), `dxmt` 68af85e. **Relation:** this plan is the
detailed form of that plan's steps 1 and 2. Its step 4 (Vulkan by default) waits
for this plan's exit criteria. **Owner's answers** (2026-10-06) are under
[Decisions taken](#decisions-taken).

## Goal

Hollow Knight (app-367520) has to run at least as well as it does on DXMT on
both Vulkan routes:

- **D3D11:** DXVK on KosmicKrisp (KK), with the game page set to `graphics: vulkan`.
- **D3D12:** vkd3d-proton on KK, with the same setting plus the argument
  `-force-d3d12`.

DXMT has no Direct3D 12, so both routes are compared with **DXMT D3D11**. "As
well" covers the capped default (720 rows, 60 FPS) and **uncapped** play
(`frameLimit: 0`), at 720 rows and at native resolution. "Par" is defined under
[Exit criteria](#exit-criteria).

## What the documentation already has

| Source | Backend | Mode | Figures |
|---|---|---|---|
| `evidence/2026-10-05-deps-latest.md` (`dl-final-hk`) | DXMT | 720/60, walk t = 60–100 s | 59.1 FPS; 72.1 Mi/f all threads, 23.0 main; CPU 118 % (P 86 / E 32), 630 mW; GPU 5.9–6.8 ms; hitches ≥25/50/100 ms 151/3/2 |
| `evidence/2026-09-29-hk-gameplay-baseline.md` | DXMT | 720, native, 900 free-running; 720/60, 900/60; 720 s roam | 720 free: walk 119.6, roam 103–104 FPS (P cores clamped to 1.31 GHz). Native free: 74–76 FPS, GPU 10 ms, every thread on E. One run each, on older IPAs (`a2f29a31`, `4c73e9c7`) |
| `evidence/2026-09-28-wine-proton-rebase.md` §8.1 | DXMT, DXVK, same IPA | menu | DXMT 101 FPS, GPU 6.01 ms. DXVK 99 FPS, GPU 5.64 ms |
| `evidence/2026-09-26-vulkan-d3d11-d3d12.md` | DXVK, vkd3d | menu, Dirtmouth | both 120 FPS in the menu (GPU 6.8 / 6.4 ms), 57 / 58 FPS in play on an earlier IPA |
| `evidence/2026-09-28-fex-band.md` §5 | DXVK | menu, Start Game | **four plays froze**, every thread in `os_sync_wait_on_address`. Not closed |
| `evidence/2026-09-30-d3d12-feature-level-12.md`, `2026-10-02-dx12-default.md` | vkd3d | starts | 3 of 5, then 2 of 3 starts reached the first frame (SIGBUS in UnityPlayer, `0xc0000005`) |
| `evidence/2026-10-05-portal2-cpu-spin.md` | DXVK (i386) | Portal 2 | `dxvk-cs` 9.5 Mi/f of 74.7 (16 % of a core) |

**What is missing:**

- a Vulkan run of the gameplay route;
- any uncapped Vulkan run;
- a DXMT and Vulkan A/B on one IPA, repeated;
- any vkd3d perf figure past the menu;
- a closed status for the freeze and the D3D12 start failures.

The uncapped DXMT figures are single runs on older IPAs, so step 1 measures DXMT
again as the control. The table above stays as the reference that step 1's DXMT
runs should reproduce.

## What "uncapped" means on this phone

On iOS a `CAMetalLayer` always presents at vsync. `displaySyncEnabled` exists only
on macOS: `patches/mesa` 0001, and `wsi_common_metal.c` line 62. Presents
therefore stop at the 120 Hz panel's rate on both backends, so an uncapped FPS
figure shows only what is below 120. The plan reads uncapped runs this way:

- **Native, free-running.** DXMT is GPU-bound at about 75 FPS, below the
  ceiling, so this mode ranks GPU cost.
- **720 rows, free-running, burst window** (the walk, t = 60–100 s). This mode
  reaches the ceiling (DXMT 119.6). A backend that holds 120 here has headroom.
  The per-frame cost columns rank the backends: Mi/f, GPU ms, and CPU mW and
  phone mW per frame.
- **720 rows, free-running, sustained window** (the roam, t = 300–600 s). The P
  cores clamp here (DXMT about 104 FPS at 1.31 GHz). FPS in this window measures
  work per frame under the thermal budget, which is the figure a player feels.
  It is the main uncapped criterion.
- In every mode, the frame-interval distribution (p50/p99/p99.9 and the
  ≥25/50/100 ms counts) next to FPS.

Pacing applies equally to both backends. KK's WSI takes its drawable from
`PacedMetalLayer.nextDrawable` (`HostIO.swift`), as DXMT does, so `frameLimit`
means the same on both, and at 0 it passes straight through. Two things differ
and are measured in step 3:

- the number of drawables (DXMT: 3; KK: the swap chain's image count, from DXVK);
- the thread that waits for a drawable.

## Measurement protocol (every step)

- **One IPA per comparison.** Every cell of a comparison runs on the same
  installed IPA, and the backend is chosen with `--settings`:

  ```
  DXMT     '{"screen":"720","frameLimit":F,"graphics":"dxmt"}'
  DXVK     '{"screen":"720","frameLimit":F,"graphics":"vulkan"}'
  vkd3d    '{"screen":"720","frameLimit":F,"graphics":"vulkan","arguments":"-force-d3d12"}'
  ```

  For native resolution, use `"screen":"native"`. F is 60 or 0.
- **Routes.** Fresh-game routes, so the save does not drift:
  - Burst or capped: `pp perf --secs 120 --cool 15 --pad first-frame+25:hk-new-game --pad first-frame+45:hk-walk`.
  - Sustained: `--secs 620` with `--pad first-frame+75:hk-walk --pad first-frame+106:hk-roam`,
    as the 09-29 baseline ran it.
- **Order.** ABBA (or ABCCBA for three backends), each run started at thermal
  `nominal` (`--cool`). All runs of a comparison are on battery and start above
  50 %. Note the charge in the record.
- **Repeats.**
  - Screening a lever: 2 runs each way at 720/60 and 2 burst runs at 720/free.
  - Baseline and exit: 3 runs of every cell, and sustained runs too.
  - A difference counts only when it lies outside both sides' run-to-run spread.
- **Same instrumentation everywhere:**
  - Metal HUD on (its logging costs the same on both backends);
  - counters on;
  - `--cpu-prof` only in runs whose figures are not used.
- **Records.** Each comparison gets one `docs/evidence/<date>-vulkan-perf-<topic>.md`
  with the IPA sha256 and `pp perf --compare` tables. Run directories stay under
  `$PLAYPORT_BUILD/perf-runs/vk-*`.
- **Per run:**
  - FPS per window;
  - frame intervals (p50/p99/p99.9, hitches);
  - GPU ms, and `gpu%`/`ren%`/`til%`;
  - Mi/f, all threads and per thread (`threads.txt`);
  - P/E %, P GHz, CPU mW and phone mW;
  - the CPMS budget;
  - srv/f;
  - Metal memory;
  - the FEX band (`band:`);
  - the time to the first frame.

## Steps

Each step is its own branch and commit(s) in this checkout (0028), with its
evidence record and any build records. Each code change also needs `./pp test`
and the gate: in one locked session, Hollow Knight and Portal 2 to
`first-frame+10` on the default backend, so DXMT and Portal 2 are not broken.
A lever is kept only if its A/B shows a gain outside the spread and no
regression in another column. Otherwise it is reverted, and its record says so.

### Step 0. Tooling the Vulkan route lacks

1. **Backend options from the game page** (needed for every configuration lever
   in step 3).
   - Today a game's options carry no environment variables
     (`DEVICE.md`, "A game's options have no environment variables").
     `runtime` takes only madeira.cfg keys.
   - Add a per-game **Graphics options** field to the app, as decision 0012
     requires. It writes an allowlisted set: `DXVK_CONFIG`, `VKD3D_CONFIG`,
     `MESA_KK_DEBUG`, `MESA_KK_EXPERIMENTAL` and `MESA_KK_DISABLE_WORKAROUNDS`.
     Its scope (dev only, or both variants) is question 3.
   - `pp ui --settings` then reaches it, for example
     `{"graphicsOptions":"dxvk.tilerMode=False"}`.
   - Write a decision record.
2. **Frames without the HUD on Vulkan.** `--no-hud` counts DXMT's `Present`
   lines only. Count presents in `PacedMetalLayer.nextDrawable`, which works for
   any backend and is app code, and log a line every N frames that
   `tools/perf.py` reads. This allows the HUD-off control run below.
3. **GPU time on KK.** Bring `pp gpu capture` and `pp perf --gpu-capture` to KK
   through Settings' Diagnostics (`MESA_KK_GPU_CAPTURE`,
   `MESA_KK_GPU_CAPTURE_DIRECTORY`; question 9 of the KosmicKrisp plan). Check
   that `pp gpu read` lists KK's passes, draws and pipelines next to a DXMT
   capture of the same scene. GPU time per pass, as DXMT's `--pass-prof` gives
   it, is in step 4 only if step 2 shows a GPU gap.
4. **Profiles of DXVK and KK.** Check that `--cpu-prof` (`tools/sampleprof.py`)
   gives symbols for DXVK's and vkd3d's ARM64EC PE code and for KK inside the
   app executable. If it does not, fix the symbol lookup.

- **On the phone:**
  - an `open:app-367520 --shot-each-action` run for the new field;
  - a DXVK play with `dxvk.hud` set through it, to show the option is taken;
  - one capture each from KK and DXMT;
  - one `--cpu-prof` DXVK play.
- **Done when** all four work on the phone and `pp test` passes.

### Step 1. The baseline matrix, and stability first

1. **Stability.** Uncapped numbers are worthless if plays freeze or crash.
   - DXVK: 10 plays to `first-frame+60` through Start Game, at 720/free and
     native/free, to reproduce 0024's freeze. If one freezes, pull
     `pp phone crashes` and the thread stacks.
   - vkd3d: 10 starts with `-force-d3d12` to `first-frame+60`.
   - One 10-minute human play on each Vulkan route.
2. **The matrix.**
   - Columns: {DXMT, DXVK, vkd3d} × {720/60, 720/free burst, 720/free sustained,
     native/free burst}.
   - 3 runs per cell, by the protocol above, so 36 runs. That is about 10 hours
     of phone time with cooling: the sustained runs are 9 of them, about 25
     minutes each.
   - One HUD-off run per backend (step 0.2) shows that the HUD's cost does not
     change the ranking.
3. **Attribution runs** (figures not used): one `--cpu-prof` run per backend at
   720/free, and one GPU capture per backend of the same Dirtmouth or King's
   Pass frame.

- **Done when** the evidence record has:
  - the matrix, with medians and spread;
  - the stability counts, with a cause for each failure;
  - a **gap table**: for each Vulkan route and mode, which of CPU per frame (and
    which thread), GPU per frame, present and latency, and hitches is behind
    DXMT, and by how much.

  The gap table ranks the levers within each layer. The layers are worked in
  the owner's order: KosmicKrisp (steps 3–6), then FEX (step 7), then Wine
  (step 8), and only then DXVK and vkd3d-proton (step 9). The levers below are
  the candidates known from reading the code, and step 1 may rank them
  otherwise.

### Step 2. Fix what step 1 found unstable

- Freeze: if it reproduces, find its cause (KK queue mutex, present-wait 0010,
  DXVK's submit thread, or a FEX futex). For vkd3d's start faults, start from
  the `UnityPlayer` fault addresses.
- Fix each in the layer it belongs to. KK and WSI fixes go in `patches/mesa`.
  vkd3d fixes go in `patches/vkd3d-proton`. Wine fixes go in the relevant series.
- **Done when** 10 of 10 starts and plays pass on both routes. No perf lever
  lands before this.

### Step 3. Configuration levers (no code, through step 0.1)

Each lever is screened alone, then the ones kept are combined, with an image
check (a screenshot at the same point) for anything that touches rendering:

| Lever | Why (code read) |
|---|---|
| `dxvk.tilerMode = False` | DXVK puts KK in tiler mode (`dxvk_device.cpp` 723–738), which records each render pass into a **secondary command buffer** (`dxvk_context.cpp` 6553). KK records every command buffer into `vk_cmd_queue` as well as into Metal (`kk_cmd_buffer.c` `needs_cmd_queue = true`) and replays secondaries at `vkCmdExecuteCommands`. So every draw may be recorded twice and replayed once on `dxvk-cs`. Also turns off `preferCachedMemory`. Watch for wrong load/store ops and clears |
| `dxgi.maxFrameLatency`, `dxgi.numBackBuffers` 2/3 | DXMT keeps 3 drawables. KK takes the image count from DXVK. Affects uncapped pacing and latency |
| `dxvk.numCompilerThreads` 2/4/6 | E-core contention against the game's threads (0024 left it at DXVK's 6) |
| `dxvk.enableGraphicsPipelineLibrary`, `dxvk.trackPipelineLifetime` | KK lacks GPL. Confirm that DXVK's fallback path is the one in use |
| `VKD3D_CONFIG` (vkd3d route) | descriptor and upload options vkd3d offers for a host without descriptor buffers. The list is read from `vkd3d_config_options` at the pin in step 3 |
| `MESA_KK_EXPERIMENTAL` (custom border colour, min LOD) | DXVK and vkd3d take a faster path when the extensions are present |

- **Done when** the record lists each lever's A/B and the combined default is
  set where the Vulkan backend sets its environment
  (`GraphicsBackend.runtimeEnvironment`). That function is empty today, by 0024.
  A setting changed there needs a decision record if it reverses 0024.

### Step 4. KosmicKrisp CPU cost (`patches/mesa`)

The pin is a Mesa `main` commit. Before writing a patch, check `main`'s newer
commits and open merge requests for the same work. Where it exists, move the
pin to a newer `main` commit (as the KosmicKrisp plan's step 2 says) instead of
carrying a Playport patch. Any pin move during this plan gets its own A/B.

1. **Skip the `vk_cmd_queue` copy for one-time-submit primaries.** DXVK and
   vkd3d submit each command buffer once. KK re-records from the queue only
   when a buffer is submitted again (`kk_queue.c` `rerecord_and_commit_cmd_buffer`).
   Secondaries still need it. *Hypothesis:* a real share of `dxvk-cs` time.
2. **Secondary replay cost**, if step 3 keeps tiler mode for correctness: replay
   into the primary's Metal encoder without a second copy.
3. **Per-submit work:** `kk_device_make_resources_resident` and the per-wait
   `mtl_wait_for_event` on every submit, the queue mutex, and allocation churn
   (commit data, command buffer pools).
4. Whatever else step 1's profile puts in KK, such as descriptor set writes to
   argument tables, or dynamic state emission.

- **On the phone:** per change, the screening A/B on the DXVK route, then the
  vkd3d route.

### Step 5. GPU cost (if step 1 shows Vulkan's GPU ms above DXMT's)

Compare KK's capture with DXMT's, frame for frame:

- passes and their load and store actions: whether DONT_CARE and LOAD_OP_NONE
  reach Metal;
- barriers: KK's Metal barriers for DXVK's `vkCmdPipelineBarrier2`;
- storage modes of render targets;
- the hot shaders' compiler statistics: KK's NIR to MSL, against DXMT's DXBC to AIR.

Fix in KK, then confirm at native/free, where GPU cost is what limits the
frame rate.

### Step 6. Present path, and hitches

1. **Present.** Check which thread waits in `nextDrawable` on the Vulkan route,
   and the cost of `mtl_command_queue_wait_for_drawable` and present-wait (0010).
   Compare the frame-interval distribution at 720/free against DXMT's.
2. **Hitches.** Cold and warm plays (KK's disk cache, 0015) at 720/60, counting
   ≥50 ms frames. If cold plays are behind DXMT, take the KosmicKrisp plan's
   Metal binary archive item (its step 2.3) here.

### Step 7. FEX

DXVK, vkd3d-proton and DXMT are all ARM64EC, so FEX runs only the game's x86-64
code and its calls into them. On the same scene, that work is the same for both
D3D11 backends unless the profile shows otherwise. It differs on the D3D12 route,
where Unity's D3D12 renderer runs other guest code.

1. From step 1's per-thread Mi/f and `--cpu-prof`, split each route's guest
   work (the main thread and `UnityGfxDeviceWorker`'s guest part) from its
   native work. The things to compare are the DX12 route against the DX11
   route, and DXVK against DXMT.
2. Where the guest share differs, look at the hot blocks and at the cost of each
   x86-64 call into ARM64EC: the entry and exit thunks per D3D call, and the
   calls per frame.
3. Look at the effect of the extra Vulkan threads on FEX: the band (`band:`),
   the JIT pool and lock contention, and their futex waits (`srv/f`, 0024's
   freeze signature).

- Changes go in `patches/fex` (decision 0018 applies only to the `fex` pin).
  The DXMT control must not regress.

### Step 8. Wine (winevulkan and the unix call path)

Every Vulkan command DXVK and vkd3d record is a Wine unix call. For example,
`vkCmdDraw` in `dlls/winevulkan/loader_thunks.c` fills a parameter block and
calls `UNIX_CALL`. The unix side then converts handles and calls KK. DXVK makes
several such calls per draw on `dxvk-cs`. *Hypothesis:* DXMT makes fewer
winemetal calls per draw, so this transition cost falls on Vulkan alone.

1. Measure the unix calls per frame and their cost per call in `--cpu-prof`
   (`__wine_unix_call`, the dispatcher, `wine_vk*` and the conversion code).
2. Possible levers, cheapest first:
   - the 64-bit thunks' handle unwrapping and struct conversion, where no
     conversion is needed;
   - a lighter transition for winevulkan's 64-bit calls in Madeira's
     one-process runtime, where PE and unix code share the address space.
     This is a `patches/madeira-unix` or `patches/wine-unix` change;
   - Valve's `win32u` semaphore and fence commits for vkd3d-proton, which the
     deps-latest record left out as "proton".

- **On the phone:** the screening A/B on both routes, and Portal 2 in the gate.
  Portal 2 uses the i386 WoW64 thunks, which must not regress.

### Step 9. DXVK and vkd3d-proton

These layers come last, for costs that KK, FEX and Wine cannot remove. A
Playport patch here (a new `patches/dxvk`, or `patches/vkd3d-proton`) needs its
own decision record, and should be one Valve or upstream would take.

### Step 10. Exit run

Repeat step 1's full matrix on the final IPA, with stability included. Write
the evidence record. Record the result in the KosmicKrisp-default plan's
step 1 (go or no-go), and in a decision record if the defaults changed.

## Exit criteria

These are the thresholds the owner accepted. Each holds for **both** Vulkan routes
(D3D11 on DXVK and D3D12 on vkd3d-proton) against DXMT D3D11, as the median of 3
runs on one IPA:

| Mode | Must hold |
|---|---|
| 720/60 | FPS ≥ DXMT − 0.5; all-thread Mi/f and CPU mW ≤ DXMT + 5 %; GPU ms ≤ + 5 %; ≥50 ms hitches within DXMT's spread |
| 720/free, burst | FPS ≥ DXMT − 1; p99 interval ≤ DXMT's; Mi/f ≤ + 5 %; GPU ms ≤ + 5 % |
| 720/free, sustained (t = 300–600 s) | FPS ≥ DXMT; phone mW per frame ≤ + 5 %; ≥50 ms hitches within DXMT's spread |
| native/free, burst | FPS ≥ DXMT; GPU ms ≤ DXMT |
| stability | 10/10 starts and plays to `first-frame+60` through Start Game; one 10-minute human play with no freeze or crash |

## Risks

- **The ceiling hides headroom.** At 720/free both backends may sit at 120 in
  the burst window. The per-frame cost columns and the sustained window decide
  then, not FPS.
- **Thermal noise.** Sustained runs vary with the phone's start temperature and
  charge. The ABBA order, `--cool`, 3 runs and recording the charge reduce this
  noise but do not remove it.
- **vkd3d may stay behind.** D3D12 adds its own CPU (descriptor emulation
  without descriptor buffers, root signature handling), and the owner holds it
  to the full bar. If it cannot reach the bar, the plan reports the gap. The
  threshold is not lowered.
- **Diverging from upstream.** Every `patches/mesa` performance patch is one more
  to carry over each Mesa move. Upstream equivalents are preferred, and each patch's
  evidence names its upstream status.
- **Image correctness.** `tilerMode = False` and KK load/store changes can draw
  wrongly without failing. Every lever that touches rendering needs a
  screenshot compared at the same pad point.
- **Phone time.** The baseline and exit matrices are about 10 hours each.
  Screening levers uses the 2+2 burst protocol to stay at about 1 hour per
  lever.

## Decisions taken

The owner answered on 2026-10-06:

1. **Thresholds.** The exit criteria above are accepted.
2. **Direct3D 12.** It is held to the same bar as Direct3D 11, in every mode.
3. **Graphics options field (step 0.1).** Dev build only (`app/Sources/S1Probe/Dev/`
   or `#if !PLAYPORT_RELEASE`), with an allowlist. The defaults that come out of
   step 3 go into `GraphicsBackend.runtimeEnvironment` for players.
4. **Where to change code.** Patches to DXVK and vkd3d-proton are not ruled out,
   but the first targets are KosmicKrisp, then FEX, then Wine (steps 3–8). DXVK
   and vkd3d-proton come last (step 9).
5. **Mesa.** The pin is already a `main` commit (b39d173, 2026-10-05), so
   there is no catch-up move before the baseline. The baseline runs at the pin.
   Later `main` commits are taken as levers in step 4, each with its own A/B.

# Plan: Vulkan at least on par with DXMT, on Hollow Knight in Direct3D 11 and 12

**Linear:** [PLA-72](https://linear.app/playportdev/issue/PLA-72).
**Date:** 2026-10-06, revised 2026-10-07. **Kind:** plan, in progress (see [How the work continues](#how-the-work-continues-owner-2026-10-07) and [Progress](#progress)). **Pins read:** as in the
[KosmicKrisp-default plan](2026-10-06-kosmickrisp-default.md): `mesa` b39d173 (a
Mesa `main` commit of 2026-10-05; `main` was 54 commits ahead on 2026-10-06, none
of them in `src/kosmickrisp` or the Metal WSI) + `patches/mesa` (16 then; 19 on 2026-10-08), `dxvk` e5ffd0f (+ `patches/dxvk` 0001), `vkd3d-proton` 31d1f89 +
`patches/vkd3d-proton` (4), `dxmt` 68af85e. **Relation:** this plan is the
detailed form of that plan's steps 1 and 2. Its step 4 (Vulkan by default) waits
for this plan's exit criteria. **Owner's answers** (2026-10-06) are under
[Decisions taken](#decisions-taken).

**Read [How the work continues](#how-the-work-continues-owner-2026-10-07) first:** since
2026-10-07 it replaces the measurement protocol, the matrices of steps 1 and 10 and the
order of steps 3–9. The rest of the plan stays as the background and the list of levers.

## How the work continues (owner, 2026-10-07)

The owner (2026-10-07): stop testing over and over. There is enough evidence; deliver
fixes for the issues found, retest each once, and if a fix does nothing or makes things
worse, think about why (read the code, profile) before running more.

**Where it stands (2026-10-08, end of session; paused by the owner):** the work of branch
`vulkan-performance-2` is merged to `main` (merge `99a38c3`); the next chunk branches from `main`. The phone runs
dev IPA `363c1234…` (HEAD's runtime). Kept on the branch, each checked on the phone:
`patches/wine-unix` 0020 (the D3D12 start fault) and 0021 (present-path window queries),
decision 0066 (DXVK tiler mode off), `patches/mesa` 0018 (no present wait on iOS: p99 at
DXMT's) and 0019 (texture usage that keeps lossless compression: native King's Pass held 60
FPS where it fell to 37–53), and the PLA-93 freeze deferral (`patches/madeira-unix` 0097,
diagnostics 0098 and `wine-unix` 0022). Tried and not kept: `one_time_submit`, the drawable
at present, the first usage rule, vkd3d-proton 0005 (decision 0067), private-storage memory,
the sample-mask lowering. The exit criteria are not met yet; the session handoff with the
numbers and the next chunks is the last entry of [Progress](#progress) (**Next**). The
earlier picture (720/free controls, step 0, step 2) is in the evidence records
[tooling](../evidence/2026-10-06-vulkan-perf-tooling.md),
[baseline](../evidence/2026-10-06-vulkan-perf-baseline.md) and
[controls](../evidence/2026-10-08-vulkan-perf-controls.md).

**Rules from here:**

1. **Fix, then one run.** Each change: `pp build`, `pp test`, install, the gate (Hollow
   Knight and Portal 2 to `first-frame+10`, one locked session), then **one** route-v2
   burst run (`.work/agent-notes/vulkan-perf/burst.sh NAME dxvk|vkd3d|dxmt [GRAPHICS
   OPTIONS]`: a new game, `hk-walk` at `first-frame+80`, cooled, window t = 85–125 s,
   `pp perf --compare … --window 85:125`) on the route it should help, compared with that
   route's existing run. A rendering change also gets one look at the end screenshot.
   Without the script (it lives in `.work`), the run is:
   `pp perf --out $PLAYPORT_BUILD/perf-runs/NAME --secs 130 --cool 15 --cool-max 25
   --settings '{"screen":"720","frameLimit":0,"graphics":"vulkan"}' --pad
   first-frame+25:hk-new-game --pad first-frame+80:hk-walk --shot first-frame+128`
   (D3D12: add `"arguments":"-force-d3d12"`; a lever: `"graphicsOptions":"…"`).
2. **No repeats by default.** Repeat a run only when its result is within noise and the
   decision hangs on it. No matrices, no 10-play stability series: a crash fix is checked
   by its trigger a few times, a perf change by one run.
3. **No gain or worse:** do not run it again unchanged. Look at the per-thread table, the
   profile or the code, change something, then run once.
4. **Keep** what helps (commit with its run in the evidence record); **revert** what does
   not (say so in the record). A config lever kept goes into
   `GraphicsBackend.runtimeEnvironment` with a decision record if it reverses 0024.
5. **Exit:** at the end, one native/free run and one 720/60 run per backend on the final
   IPA, plus the gate (owner, 2026-10-08; see [Exit criteria](#exit-criteria)). Not three
   of each.

**Owner's directions (2026-10-08), replacing route v2 at 720/free as the lever mode** (rule 1's
burst run and the controls below stay as history; no more 720/free burst runs):

- **Power counts as much as FPS.** Every table carries CPU and phone mW and mJ/f. Raw mW is
  not comparable at different FPS, so read mJ/f there.
- **The mode follows what the change targets.** Still one run per change, on route v2:
  - A GPU or throughput change gets a native/free run (`{"screen":"native","frameLimit":0}`),
    read as FPS, GPU ms and the energy a frame (sys and CPU mJ/f).
  - A CPU or power change (KosmicKrisp's per-draw cost, vkd3d's worker, FEX) gets a 720/60
    run (`{"screen":"720","frameLimit":60}`), read as CPU mW, phone mW and Mi/f at equal FPS.
- **A warm phone, paired runs.** From the next chunk, lever checks run without `--cool` or
  `--cool-max`, back to back in one locked session (`pp phone lock -- sh -c …`): a control
  run on the current IPA and settings, then at once the change's run in the same mode, so
  both share the warm state.
  - A cooled run is not compared with a warm one.
  - Each run's thermal state is recorded (`summary.json`: `thermal_start`,
    `first_pressure_s`, `max_pressure`). A pair whose thermal pressure differs is flagged.
  - Config levers (Graphics options) can go several to a session: control, lever A,
    lever B, control.
  - Exit runs stay cooled.
- **Cooled references** on IPA `b024e1f7…` ([profile](../evidence/2026-10-08-vulkan-perf-profile.md)):
  - native/free: `vk-nat-dxmt-1`, `vk-nat-dxvk-1`, `vk-nat-vkd3d-2` (`vk-nat-vkd3d-1` lost
    its HUD, PLA-82);
  - 720/60: `vk-60-dxmt-1`, `vk-60-dxvk-1`, `vk-60-vkd3d-1`.

  They are the baseline the exit runs are read against, not a lever's control.
- `--cpu-prof` runs are taken at native/free; their figures are not compared.
- **Exit:** power criteria first, one native/free and one 720/60 run per backend, cooled,
  plus the gate ([Exit criteria](#exit-criteria)).

**Controls on route v2** (IPA `0d4a0f1e…`, [controls](../evidence/2026-10-08-vulkan-perf-controls.md)):
`vk-v2-dxmt-2`, `vk-v2-dxvk-2` and `vk-v2-vkd3d-1`, window t = 85–125 s. A lever's run is
compared with its route's control (`vk-v2-dxvk-1` lost its HUD figures; do not use it).
Since `wine-unix` 0021 (item 1, kept), a Vulkan lever's run is compared with its route's
latest run on the 0021 IPA `baa20a27…`: `vk-v2-dxvk-presentfix-1` and
`vk-v2-vkd3d-presentfix-1` ([present path](../evidence/2026-10-08-vulkan-perf-present-path.md)).
Since tiler mode went off by default (item 3, kept, decision 0066; IPA `4349d6a2…`), a DXVK
lever's run is compared with `vk-v2-dxvk-notiler-1`, in the window 85–115 s unless its walk
reaches the lumafly room ([config levers](../evidence/2026-10-08-vulkan-perf-config-levers.md));
a Graphics option's DXVK item now follows the backend's `DXVK_CONFIG`, so tiler mode stays off
in it. Since `patches/mesa` 0018 (no present wait on iOS, item 5, kept; IPA `b024e1f7…`), a
lever's run is compared with `vk-v2-dxvk-p99-2` (window 85–115 s, the same pit scene) or
`vk-v2-vkd3d-p99-1` ([p99](../evidence/2026-10-08-vulkan-perf-p99.md)).

**Work queue, in this order** (each item names its evidence and its first move):

1. **Done (kept, `wine-unix` 0021):** Wine's Vulkan present path (both routes; step 8). Six more wineserver requests a
   frame than DXMT (18 against 12): `win32u_vkQueuePresentKHR` calls
   `client_surface_update` before the present and `client_surface_present` after it, and
   each runs `client_surface_update_locked` (`NtUserGetAncestor`, `get_client_surface_rects`:
   `get_window_parents`, `get_window_rectangles`, `get_windows_offset`). Move: a
   `patches/wine-unix` change that skips the window queries when the window has not
   changed (or does them once a present, not twice); measure srv/f, the wineserver
   thread's Mi/f and p99.
2. **Done (not kept):** `VKD3D_CONFIG=one_time_submit` took UnityGfxDeviceWorker 0.35 Mi/f
   down (−2 %), nothing else measurable, and would drop a re-executed command list's work
   on KosmicKrisp ([config levers](../evidence/2026-10-08-vulkan-perf-config-levers.md)).
   The worker's remaining time needs a D3D12 CPU profile. The original item:
   **vkd3d records every command twice** (D3D12 route; step 4.1 turned config).
   KosmicKrisp skips its `vk_cmd_queue` copy only for `ONE_TIME_SUBMIT` command buffers,
   and vkd3d-proton sets that flag only with `VKD3D_CONFIG=one_time_submit`. Move: one
   vkd3d run with `graphicsOptions` `VKD3D_CONFIG=one_time_submit`; watch
   UnityGfxDeviceWorker's Mi/f (twice DXMT's) and the screenshot.
3. **Done (kept, decision 0066):** `dxvk.tilerMode=False` is the Vulkan backend's default:
   Mi/f 60.5 → 57.5, CPU 1784 → 1675 mW, dxvk-cs down, GPU time unchanged. The original item:
   **DXVK tiler mode** (DXVK route; step 3). DXVK puts KosmicKrisp in tiler mode, which
   records each render pass into a secondary command buffer that KosmicKrisp queues and
   replays on `dxvk-cs`. Move: one DXVK run with `dxvk.tilerMode=False` (it ended in the
   video crash before `patches/dxvk` 0001; it runs now); watch dxvk-cs and the screenshot.
4. **Done (no change, no run):** the extra present pass is the Metal WSI's copy of the
   swap-chain image into the drawable (`vk_meta_blit_image2`); it cannot be removed safely,
   since KosmicKrisp fixes an image view's Metal texture at view creation and a drawable's
   texture changes with every acquire, and the drawable is `framebufferOnly`. The compute
   dispatch is a one-thread immediate write of the game's frame (an event or query), not a
   present pass. GPU time is already 6 % below DXMT's. The two safe CPU trims (one submit
   instead of two at present; the blit's re-recording at acquire) are below one run's
   resolution and go with item 6 ([present pass](../evidence/2026-10-08-vulkan-perf-present-pass.md)).
   The original item: **the extra present pass** (both routes; step 5). The Vulkan frame has a compute
   dispatch and one more full-screen pass at present: DXVK draws into its swap-chain
   image, then KosmicKrisp's WSI blits that into the drawable. Move: read
   `wsi_common_metal.c` and KosmicKrisp's `kk_wsi.c` for a way to render to the drawable
   (or skip DXVK's own blit); a `patches/mesa` change, one run.
5. **Done (kept, `patches/mesa` 0018):** p99 is 8.34 ms on both routes, DXMT's figure
   ([p99](../evidence/2026-10-08-vulkan-perf-p99.md)). The game ran one frame ahead of the
   screen, because DXVK and vkd3d-proton released its frame latency at the drawable's
   presented handler (present wait). Without present wait on iOS they release it when the
   GPU work is done, as DXMT does. Late frames went from 1.2–1.5 % to 0.19 % and FPS from
   118 to 119.5–119.8. GPU ms went 5.8 → 6.55 with the same work (not explained yet).
   Taking the drawable at present instead of at acquire did nothing and was reverted. The
   original item: **p99 16.7 ms** (both routes; step 6). Missed 120 Hz frames. Move: after
   1–4, look at the frame-interval trace of one run; then `dxgi.maxFrameLatency` /
   `dxgi.numBackBuffers` (DXMT keeps 3 drawables), one run each.
6. **Done (profiled; `patches/mesa` 0019 not kept)** ([profile](../evidence/2026-10-08-vulkan-perf-profile.md)).
   At native/free both Vulkan routes fall to about half DXMT's FPS once the thermal budget
   applies, because their GPU time a frame doubles. The phone's energy a frame is 40–100 %
   above DXMT's, and was already 30 % above at 720/free before 0018. At 720/60, DXVK uses
   +10 % CPU mW and +8 % phone mW, and vkd3d +45 % and +10 %. In the profiles, KosmicKrisp is
   0.6–1.0 % of samples, Apple's driver 2.2–3.6 % on the recording thread, and the WSI
   submit thread 0.4 % (its two trims are dropped). 0019 (Metal texture usage without
   shader write or pixel format view, so render targets could be compressed) left native/free
   unchanged and was reverted. The original item: **dxvk-cs time in Apple's driver** (step 4),
   one `--cpu-prof` run, KosmicKrisp's per-draw Metal calls, item 4's two present-path trims.
7. **GPU energy a frame at native** (step 5; the largest gap). In progress. The GPU time a
   frame doubles when King's Pass starts, not when thermal pressure arrives. A private-storage
   memory type with narrow texture usage (`patches/mesa` 0019 and 0020, behind
   `MESA_KK_EXPERIMENTAL`) left that doubling in place and was not kept
   ([private memory](../evidence/2026-10-08-vulkan-perf-private-memory.md)). King's Pass
   captures on both backends ([King's Pass capture](../evidence/2026-10-08-vulkan-perf-kings-pass-capture.md))
   show the same passes, with no extra split or forced load or store (H3 out), and pixel format
   view left on Unity's TYPELESS scene targets. **Kept:** `patches/mesa` 0019 (on by default,
   `MESA_KK_DEBUG=wide_usage` disables it) drops pixel format view for layout-preserving format
   lists (DXMT 0009's rule) and shader write for non-storage images. The scene targets are now `0x5`.
   In warm native/60 pairs it held 60 FPS through King's Pass on both routes, where the controls
   did not, at 21–33 % less phone energy a frame
   ([TYPELESS usage](../evidence/2026-10-08-vulkan-perf-typeless-usage.md)). Lowering DXVK's
   sample mask only when it clears a sample (`patches/mesa` 0020) saved no GPU time and was not
   kept ([sample mask](../evidence/2026-10-08-vulkan-perf-sample-mask.md)). What is left of the
   gap is measured by the cooled exit runs.
8. **FEX on the D3D12 route** (step 7). UnityGfxDeviceWorker's guest and xtajit64 time is
   13.5 % of samples on vkd3d against 7.6 % on DXVK, with 3× the ARM64EC transitions
   (`ios_ec_xlate_loop`, `ExitFunctionEC`), and it drives vkd3d's +45 % CPU mW at 720/60.
   Move: the hot guest blocks (`UnityPlayer.dll+941800`, `+958300`, `+494800`, `+916700`) and
   the transitions per frame; each change gets a warm 720/60 pair.
9. **Apple's driver on the recording thread** (step 4.4): dxvk-cs 2.2 %, vkd3d worker 3.6 %,
   against KosmicKrisp's 0.6–1.0 %. It needs symbolised AGX frames, or a count of the Metal
   calls per draw, before any change.

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

*Replaced on 2026-10-07 by [How the work continues](#how-the-work-continues-owner-2026-10-07)
(one run per change, no matrices). Kept as the definition of the runs' settings and
columns.*

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
     It is in the dev build only (decision taken 3).
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

*(2026-10-07: not completed and not to be; the burst set and the stability plays done
are enough to work from. See How the work continues.)*

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

*(2026-10-07: one run per mode and backend, not three; see How the work continues.)*
Repeat step 1's full matrix on the final IPA, with stability included. Write
the evidence record. Record the result in the KosmicKrisp-default plan's
step 1 (go or no-go), and in a decision record if the defaults changed.

## Exit criteria

*Rewritten on 2026-10-08 by the owner's direction (How the work continues): power first,
two modes, one run each.* Each holds for **both** Vulkan routes (D3D11 on DXVK and D3D12
on vkd3d-proton) against DXMT D3D11, on route v2, one run per backend on the final IPA:

| Mode | Must hold |
|---|---|
| 720/60 (the players' default) | CPU mW and phone mW ≤ DXMT + 5 %; FPS ≥ DXMT − 0.5; all-thread Mi/f ≤ DXMT + 5 %; ≥ 50 ms hitches not above DXMT's |
| native/free | FPS ≥ DXMT; GPU ms ≤ DXMT; phone mJ/f ≤ DXMT + 5 % |
| gate | Hollow Knight on Vulkan and on DXMT, and Portal 2, each to `first-frame+10` |
| stability | every exit run and gate play ends in play, with no freeze or crash |

The exit runs are therefore: one native/free run and one 720/60 run per backend on the
final IPA, plus the gate. The earlier thresholds (720/free burst and sustained, median of
3 runs, 10/10 stability plays) are retired.

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

## Progress

Run unattended on branch `vulkan-performance` from 2026-10-06; each decision taken
without the owner is recorded here with its reason.

- **`tools/perf.py`, from the supervising session (not this plan's work):** unattended,
  `pp perf` now shows the black screen during its cooling wait. It holds the lock from the HUD
  launch to the play, so the lock's own rest came only after each run and the Home Screen stayed
  lit through every 15-minute cool. Committed as `dcfcc86`.
- **Step 0: done** ([evidence](../evidence/2026-10-06-vulkan-perf-tooling.md)).
  Graphics options (decision 0060; 0059 is left to the Epic decision 0058 names),
  `[frames]` lines for `--no-hud`, `pp perf --compare --window`, KosmicKrisp one-frame
  capture (`patches/mesa` 0017) with `tools/gputrace.py` reading Metal 4, and the
  sampler's KosmicKrisp names and per-thread tables (`patches/madeira-unix` 0096).
  Decision: GPU time per pass on KK was not built (the plan makes it conditional on
  step 2 showing a GPU gap); the capture already shows one structural difference, an
  extra full-screen pass and a compute dispatch at present on the Vulkan route.
- **Step 1: partial** ([evidence](../evidence/2026-10-06-vulkan-perf-baseline.md)).
  The phone began the session at 71 % with no charger and nobody at it. Decision: one
  ABCCBA burst set at 720/free (two runs a backend, charge 57 → 36 %), then stability
  plays, and no phone work below about 15 %. The 720/60, sustained and native cells and
  the third repeats are not run. From the burst set, both Vulkan routes are behind DXMT
  on FPS (−2 to −4), p99 (16.7 against 8.3 ms) and work a frame (DXVK +14–18 %,
  vkd3d +26–31 %); GPU ms is within 3–6 %. The gap is in UnityGfxDeviceWorker
  (vkd3d: twice DXMT's), the wineserver (six more requests a frame from winevulkan's
  present: `client_surface_update` and `client_surface_present`), dxvk-cs's time in
  Apple's driver, and an extra full-screen pass at present.
- **Step 1 finding against step 4.1:** KosmicKrisp already skips the `vk_cmd_queue` copy
  for `ONE_TIME_SUBMIT` primaries, which DXVK uses; vkd3d-proton uses it only with
  `VKD3D_CONFIG=one_time_submit`, so that is a step-3 lever for the D3D12 route
  instead of a KosmicKrisp patch.
- **Step 2: started.** The D3D12 route reached `first-frame+60` 0 of 5 times, and DXVK
  without tiler mode 0 of 1: a NULL `vkGetMemoryWin32HandleKHR` call in DXVK when Media
  Foundation creates a shared texture. Decision 0061 (unattended, under answer 4): a
  `patches/dxvk` series with the one-line fix DXVK's code already implies, taken now
  because the stability bar blocks every lever and the bug is DXVK's, not KosmicKrisp's
  or Wine's. Built, **not yet run on the phone** (battery 10 %). Also open: the D3D12
  start fault 1 s in (`vk-st-vkd3d-720-2`, a wild INIT_ONCE pointer from the guest), and
  one DXVK launch that hung before the runtime started (`vk-st-dxvk-720-3`).
- **Tooling fixed on the way:** an unattended `pp perf` rest no longer undoes the run's
  HUD and settings; `pp ui` fails a play whose title ended with an error before
  `--until` (the app's restart had hidden it).
- **Next, in order, on a charged phone:** the gate plus 10 D3D12 and 10 DXVK plays on
  the `patches/dxvk` IPA; then the rest of the step-1 matrix (720/60, sustained, native,
  three runs each); then step 3's screening (`VKD3D_CONFIG=one_time_submit`,
  `dxvk.tilerMode=False`, frame latency and back buffers, compiler threads) and the Wine
  present-path lever (step 8, the six requests a frame).
- **2026-10-06 22:27 – 01:55, charged phone** ([evidence](../evidence/2026-10-06-vulkan-perf-baseline.md#2026-10-06-2227--2026-10-07-0155-on-a-charged-phone)).
  `patches/dxvk` 0001 works: the opening cinematic no longer ends the game (18 of 18
  started plays through it). The 60 s stability plays had ended in that cinematic, since
  profile 1 is empty now and `hk-walk` came too early: **route v2** pushes `hk-walk` at
  `first-frame+80`. Owner's direction (2026-10-07): cut testing to the minimum, the
  performance gaps are clear; no full matrix, one run each way per fix, three
  stability plays a route. On route v2: DXVK 3 of 3 in play, D3D12 2 of 3.
- **Step 2, D3D12 start fault:** 3 of 13 starts, a waiter's frame gone before its run-once
  release (`NtWaitForKeyedEvent` returning without one). Waiting again hung every D3D12
  start (7 of 7), so `patches/wine-pe` 0031 only logs the status for now; not run on the
  phone, which dropped off the network at 01:40 and needs a person.
- **Also:** `build/air-helpers/air-helper-port.sh` reuses the shared LLVM 15 tools when
  they are all there (another worktree had configured the shared cache from its own path,
  and CMake refused it, which failed the `dxmt` stage).
- **Next:** with the phone back, 10 D3D12 starts on the 0031 IPA for the status; fix the
  keyed wait; then three D3D12 plays on route v2. Then the performance levers, largest
  gap first, one run each way: winevulkan's present path (six wineserver requests a
  frame), `VKD3D_CONFIG=one_time_submit`, the extra present pass.
- **D3D12 start fault, cause found (not phone-checked):** the game's NULL keyed-event
  handle named another object (the session root's handle, in a table the game does not
  share), so keyed waits failed at once. `patches/wine-unix` 0020: one keyed event per
  pseudo-process. Built, IPA `5a206ea8…`; the phone was offline from 01:40. **Next on the
  phone:** install it, the gate, 10 D3D12 starts (expect no `keyed wait returned` lines
  and no 1-s fault), three D3D12 and three DXVK plays on route v2, then the levers.
- **2026-10-07 09:00:** wine-unix 0020 (then numbered 0018) works on the phone: 10/10 D3D12 starts, D3D12 3/3 and DXVK
  3/3 plays in King's Pass on route v2, gate passed. Step 2 closed for the known faults.
  Next: route-v2 burst runs (DXMT, DXVK, vkd3d, one each, cooled), then the levers.
- **Paused 2026-10-07 ~09:50 by the owner;** resumed 2026-10-08 on `vulkan-performance-2`:
  main `1e08fe3` plus the first branch's commits (dxvk 0001 and air-helpers were already
  on main), the branch's patches renumbered after main's series (`wine-unix` 0018 → 0020,
  `wine-pe` 0029 → 0031; main had used 0018 and 0029 for other patches). IPA `0d4a0f1e…`:
  the gate passed, one D3D12 start reached `first-frame+10`, and the route-v2 controls ran
  once each (`vk-v2-dxvk-1` lost its HUD to a settings undo, so DXVK ran once more as
  `vk-v2-dxvk-2`) ([controls](../evidence/2026-10-08-vulkan-perf-controls.md)).
- **Work-queue item 1, done, kept** ([present path](../evidence/2026-10-08-vulkan-perf-present-path.md)):
  the six requests a frame were not the window changing. The renderer's present thread never
  asked for its desktop window, so win32u took the desktop for another process's window and
  each walk up from the game's window (`NtUserGetAncestor`, `get_window_rects`,
  `get_windows_offset`) went to the server. Decision (unattended): `patches/wine-unix` 0021
  makes `client_surface_update_locked` call `get_desktop_window()` first, keeping upstream's
  refresh on every present, instead of caching the rects (which would miss changes made
  outside `apply_window_pos`) or updating once a present (which keeps three). IPA
  `baa20a27…`: gate passed; DXVK srv/f 17.8 → 12.1 (DXMT 12.0), vkd3d 23.2 → 17.0; the
  wineserver thread about 1.1 Mi/f less on each; Mi/f 61.5 → 60.8 and 66.6 → 65.1; FPS and
  GPU time unchanged; DXVK p99 12.5 → 16.67 ms, one 120-Hz step it also showed in step 1, read
  as run-to-run.
- **Work-queue items 2 and 3, done** ([config levers](../evidence/2026-10-08-vulkan-perf-config-levers.md)),
  one run each on the 0021 IPA. `VKD3D_CONFIG=one_time_submit` (`vk-v2-vkd3d-ots-1`): **not
  kept**. KosmicKrisp's skipped `vk_cmd_queue` copy was worth 0.35 Mi/f on UnityGfxDeviceWorker
  (17.9/19.8 → 17.6/19.5), nothing else moved, and with the flag a D3D12 command list
  executed twice would replay an empty queue on KosmicKrisp. `dxvk.tilerMode=False`
  (`vk-v2-dxvk-notiler-1`): **kept**. In the same scene (window 85–115 s; the Knight then
  missed the held jump out of the pit) Mi/f 60.5 → 57.5, CPU 1784 → 1675 mW, dxvk-cs
  4.3/5.8 → 3.8/4.0 Mi/f, 180 MiB less, GPU time 5.81 → 5.80 ms, p99 unchanged.
  Decisions (unattended): the lever is the Vulkan backend's default
  (`GraphicsBackend.runtimeEnvironment`, decision 0066, superseding 0024's empty
  `DXVK_CONFIG`); a dev build's DXVK Graphics options now follow that default after `;`
  instead of replacing it, so later DXVK lever runs keep tiler mode off; one run each, no
  repeat (the notiler run's late scene change was handled by the matched window, not a
  rerun). IPA `4349d6a2…`: `pp test`, `pp build`, install, the gate (Hollow Knight and
  Portal 2, both on DXVK on this phone) and one Hollow Knight Vulkan play, each log with
  `Found config env: dxvk.tilerMode = False`. Found on the way: the gate's Hollow Knight play
  runs on Vulkan on this phone, not DXMT; the controls and present-path records are corrected.
- **Work-queue item 4, done, no change** ([present pass](../evidence/2026-10-08-vulkan-perf-present-pass.md)).
  From the code and the step-0 capture `gpu-runs/vk-kk-cap1`: after the game's passes the
  Vulkan frame has DXVK's 3-vertex draw onto the swap-chain image (DXMT's present quad does
  the same job) and the Metal WSI's `meta:vkCmdBlitImage2`, a 6-vertex copy of that image
  into the drawable: the one extra full-screen pass. The compute dispatch is
  KosmicKrisp's one-thread immediate write (`kk_cmd_write`) at the end of the game's own
  command buffer, not a present pass. Decisions (unattended): no `patches/mesa` change and
  no phone run. Rendering straight into the drawable would mean re-creating every view of
  a swap-chain image at each acquire (KosmicKrisp fixes a view's Metal texture at creation
  and encodes at record time), and would break any application that records for an image
  before acquiring it. The drawable is `framebufferOnly`, so no cheaper blit-encoder copy
  is possible. The pass costs about 0.1–0.15 ms of GPU time, and Vulkan's GPU time is
  already 6 % under DXMT's. The safe trims (one submit instead of two, since
  `kk_get_blit_queue` makes the WSI submit an empty semaphore hop; the blit re-recorded at
  every acquire) are on threads with under 0.2 % of the profile's samples, so they go with
  item 6. The installed IPA stays `4349d6a2…`; nothing was reverted.
- **Work-queue item 5, done, kept** ([p99](../evidence/2026-10-08-vulkan-perf-p99.md)).
  The frame-interval traces showed no GPU, shader or thermal cause. Each late Vulkan frame
  carried two frames' GPU time, and the device log's present trace showed the game exactly
  one frame ahead of the screen on both routes: DXVK and vkd3d-proton released its frame
  latency at the presented handler (present wait), where DXMT releases at GPU completion.
  `dxgi.numBackBuffers` does not exist at DXVK's pin, `dxgi.maxFrameLatency` can only lower
  the latency, and the swap chain and the layer already have 3 drawables, so no config
  lever applied. Decisions (unattended): the first change (`patches/mesa`, the drawable
  taken at present rather than at acquire; `vk-v2-dxvk-p99-1`) did nothing and was reverted.
  It was not run on vkd3d, since its trace already showed it could not change the lockstep.
  The second change, `patches/mesa` 0018 (no `VK_KHR_present_wait`/`present_wait2` on iOS),
  is kept: DXVK p99 16.67 → 8.34 ms, FPS 118.2 → 119.5, CPU 1675 → 1500 mW; vkd3d p99
  16.67 → 8.34, FPS 118.0 → 119.8, ≥ 25 ms hitches 8 → 0. A patch, not a
  `runtimeEnvironment` setting, and no decision changed, so no decision record. The
  gate and the per-route runs on IPA `b024e1f7…` (commit `80d48bf`) are the confirming runs,
  not repeated. Open: GPU ms rose 5.8 → 6.55 on both routes (DXMT 6.1–6.2) with the same
  work and no more power a frame. It is either a lower GPU clock or Metal counting the
  blit's drawable wait, and the exit criterion (≤ DXMT + 5 %) now reads +7 %.
- **Work-queue item 6, done; `patches/mesa` 0019 not kept**
  ([profile](../evidence/2026-10-08-vulkan-perf-profile.md)). The owner set three directions
  mid-chunk: native/free and 720/60 as the modes, power in every table, warm paired runs
  (How the work continues). Decisions (unattended):
  - `vk-nat-vkd3d-1` was void (`Metal HUD off`, PLA-82) and was rerun once.
  - The `--cpu-prof` runs moved to native/free, per the owner.
  - The change taken was the GPU-side lead (Metal texture usage `0x17` against DXMT's `0x5`),
    not a CPU trim. The profile ranked no CPU change: KosmicKrisp 0.6–1.0 % and the WSI
    submit thread 0.4 % of samples.
  - 0019 was judged by one native/free DXVK run (`vk-nat-dxvk-0019-1`, IPA `f9a12132…`). The
    gate passed. FPS rose 57.7 → 59.2 and GPU ms fell 13.40 → 13.26 in the window, both within
    noise, so it was reverted (file and series line together).
  - The phone was put back on `b024e1f7…`.

  The answer to item 5's GPU-time question: 0018 does not cost frames. The Vulkan routes'
  energy a frame was already 30 % above DXMT's before it. At native, once the thermal budget
  applies, their GPU time doubles and FPS halves (DXVK 57.7, vkd3d 56.4, DXMT 108.9).
- **Exit readiness: not ready.** Against the rewritten [exit criteria](#exit-criteria):
  - native/free: FPS 57.7 / 56.4 against 108.9 and GPU ms 13.4 / 10.2 against 7.5 fail;
    sys mJ/f 90 / 125 against 61 fails.
  - 720/60: CPU mW +10 % (DXVK) and +45 % (vkd3d) fail; phone mW +8 % and +10 % fail.
  - FPS and hitches hold.

  The exit runs should not start.
- **vkd3d-proton's submission path, not kept (decision 0067):** ruled out for vkd3d's CPU power:
  `patches/vkd3d-proton` 0005 (KosmicKrisp syncs host readback, so no re-recorded barrier
  command buffer each submission) took effect, but in a warm 720/60 pair CPU stayed at 793
  against 792 mW and `vkd3d_queue` at 0.82 against 0.83 Mi/f. It was not kept (decision 0067,
  [evidence](../evidence/2026-10-08-vulkan-perf-vkd3d-kk-driver.md)). Next for vkd3d's CPU
  power is item 8 (FEX on the D3D12 route, plan step 7): UnityGfxDeviceWorker's guest and
  `xtajit64` time, with warm 720/60 pairs. A control IPA for a warm pair must still be in the
  build area: `pp build` keeps three outputs, so rebuild the control's commit if it was pruned.
- **Work-queue item 7, private-storage memory: not kept**
  ([private memory](../evidence/2026-10-08-vulkan-perf-private-memory.md)).
  - **What was tried.** Hypothesis H1(a): shared storage, or the whole-heap buffer alias, blocks
    lossless compression of KosmicKrisp's render targets. To test it, `patches/mesa` 0019
    (`narrow_usage`) and 0020 (`private_memory`) went behind `MESA_KK_EXPERIMENTAL`, giving a
    `DEVICE_LOCAL`-only memory type backed by a private Metal heap with no buffer over it.
  - **Gate** (IPA `55ca5c34…`, commit `c8c6016`): Hollow Knight on DXVK, D3D12 and DXMT and
    Portal 2 passed, with and without the flags. DXVK listed two memory types with them.
  - **The warm native/free DXVK pair.** With the flags, GPU ms still doubled in the first King's
    Pass bucket (6.35 → 13.42 ms; control 6.25 → 14.11). In the 85–125 s window it was 13.17
    against 13.00 ms, and CPU mJ/f 3.6 against 3.5. FPS was lower (45.7 against 58.5), but that
    run started at `serious`, where the control started at `nominal`. The pair is flagged for
    that, and was not rerun, because the doubling H1(a) predicted would vanish is still there.
  - Decision (unattended): both patches were reverted, file and series line in one commit. The
    phone keeps `55ca5c34…`, which with the flags off runs as HEAD does.
- **Work-queue item 7, King's Pass captures** (measurement only, IPA `55ca5c34…`,
  [evidence](../evidence/2026-10-08-vulkan-perf-kings-pass-capture.md)). Captured on DXMT
  (`vk-kp-dxmt-1`, with GPU time per pass), DXVK (`vk-kp-dxvk-3`) and DXVK with chunk 8's flags
  (`vk-kp-dxvk-pm-2`).
  - **Structure.** DXVK's frame has the same game passes, sizes, formats and actions as DXMT's.
    Its only extra full-res work is the WSI copy plus one depth store (about 45 MB a frame), and
    its attachment traffic is lower in that spot (504 against 639 MB). H3 is ruled out.
  - **Usage.** With `narrow_usage,private_memory`, the targets were private, but the TYPELESS
    scene targets kept pixel format view (`0x15`). DXVK lists the whole typeless family, and the
    chunk-8 rule accepted only the sRGB twin. The chunk-8 null result therefore did not test
    compression.
  - Top cause (inference): uncompressed TYPELESS render targets, as DXMT had before 0009.
  - Two DXVK captures were lost: one did not reach its frame on a `serious` phone, and one lost its
    capture switch to the settings undo (PLA-82). One more landed before King's Pass.
- **Work-queue item 7, TYPELESS texture usage: kept, on by default**
  ([TYPELESS usage](../evidence/2026-10-08-vulkan-perf-typeless-usage.md)).
  - **The change.** `patches/mesa` 0019 gives no pixel format view when every format in an image's
    format list keeps its component layout. The test is the same channel count, sizes, bit
    positions and order, the rule of Apple's `pixelFormatView` page and of `patches/dxmt` 0009.
    Images with no list, depth/stencil and non-plain formats keep it. Shader write goes only to
    storage images. A layout-changing view is logged as `[kk-pfv-view]`.
  - **Behind the flag** (IPA `8ea52bd9…`, commit `1545734`):
    - The gate passed with and without it, and no `[kk-pfv-view]` line came.
    - The King's Pass capture `vk-kp-dxvk-nu-1` shows the 7 full-res RGBA8 targets at `0x5` and the
      UAV target at `0x7`.
    - A warm native/free pair ran both at `serious`. GPU ms went 18.7 → 12.3 and FPS 40.4 → 49.9,
      but sys mJ/f only 76.5 → 74.1. The control ran under a 404 mW client-11 budget, so the pair
      is budget-confounded.
    - The supervisor's tie-break was a warm native/60 pair, flag first: the flag held 59.9 FPS
      against 37.5, at 68.5 against 102.7 sys mJ/f.
  - **Default** (IPA `4e6e930d…`, commit `ca12f08`):
    - The gate passed.
    - A warm vkd3d native/60 pair ran the control (`wide_usage`) first. The default held 59.7
      against 53.5 FPS, at 4299 against 4862 sys mW (72.0 against 90.9 mJ/f) and GPU 12.9 against
      15.2 ms.
  - **Caveat.** Every pair's control reached thermal pressure 20 where the change did not, in
    either order. The cooled exit runs confirm.
  - Decisions (supervisor): keep as the default with a disable switch. It is a patch, not a
    `runtimeEnvironment` setting, so there is no decision record.
- **Work-queue item 7, sample-mask lowering on DXVK: not kept**
  ([sample mask](../evidence/2026-10-08-vulkan-perf-sample-mask.md)).
  - **Sizing** (IPA `4e6e930d…`): the first pair was void (the control froze at
    `first-frame+37` with PLA-93's signature, on DXVK; the switch's run lost its HUD, PLA-82), and
    its one rerun gave `MESA_KK_DISABLE_WORKAROUNDS=7` (the discard only) 11.33 → 11.04 GPU ms,
    within the pair's thermal bias (the control ran under pressure 20 and a 404 mW budget).
  - Decision (unattended): build the change anyway, since the switch left the static
    `[[sample_mask]]` write in place and only the patch could size both, and take its pair on one IPA
    with a restore switch.
  - **The change**, `patches/mesa` 0020 (IPA `7d7c983b…`): no lowering when the mask covers every
    rasterized sample, `MESA_KK_DEBUG=any_sample_mask` to restore. The gate passed. In a warm
    native/free DXVK pair, GPU ms was 11.58 (upstream's lowering) against 11.71 (0020), and
    9.7–10.0 ms in every bucket from t = 85 in both; the control again ran under pressure 20, so its
    higher sys mJ/f is not read as a gain. Reverted, file and series line in one commit (`377e7cb`);
    the phone runs `e6bd82a4…` (HEAD, the same artifacts as `4e6e930d…`).
- **Stability, PLA-93** ([suspend in FEX](../evidence/2026-10-08-pla93-suspend-in-fex.md), IPA
  `363c1234…`, commits `59a107e`, `dedb498`).
  - The fix, `patches/madeira-unix` 0097: a real suspend's deferred hold is not taken while the
    thread is inside FEX, that is while `InSyscallCallback` or FEX's TEB lock stamps
    (+0x16f0, +0x16e8) are set.
  - The diagnostics, madeira-unix 0098 and wine-unix 0022: `[wpm-owner]` gives a stuck
    lock's write owner's Mach state, and the thread sampler prints each held thread with
    `susp=`.
  - The gate passed: Hollow Knight on DXVK, DXMT and D3D12, and Portal 2.
  - 10 Hollow Knight plays through `hk-new-game` to `first-frame+70` (5 DXVK, 5 D3D12) had no
    freeze. Against a baseline of 2 in about 20 that supports the fix but does not prove it,
    and the new deferral never fired (`in_fex=0`).
  - Residual: FEX's write holds outside a syscall callback (`HandleRWXAccessViolation`) have
    no TEB stamp and are not covered.
- **Next: session handoff (2026-10-08, paused by the owner)** (from the
  [standing](../evidence/2026-10-08-vulkan-perf-standing.md),
  [sample mask](../evidence/2026-10-08-vulkan-perf-sample-mask.md) and
  [suspend in FEX](../evidence/2026-10-08-pla93-suspend-in-fex.md) records):
  - **State.** Merged to `main` (`99a38c3`); continue on a new branch from `main`. Phone on IPA
    `363c1234…` (the merged runtime; the merge changed no build input). `pp build` keeps three outputs (PLA-92): rebuild a control's commit if its
    IPA was pruned.
  - **Where it stands** (warm standing on `4e6e930d…`, before the PLA-93 patches, which change
    no rendering). Not at exit; each route meets 2 of 9 criteria rows. At native/free DXVK's GPU
    ms is +29 % over DXMT's and vkd3d's +4 %; sys mJ/f +17 % and +12 %. At native/60 phone mW is
    +7.7 % and +6.4 %, Mi/f +11 % and +22 % (vkd3d's UnityGfxDeviceWorker +9 Mi/f). Not DXVK's
    GPU share: the sample-mask lowering, private storage, render-pass splits.
  - **Stability (PLA-93).** The freeze at about `first-frame+37` (Mono GC suspend held a thread
    inside FEX's CodeInvalidationMutex) hit both routes, 2 in about 20 plays. 0097 defers that
    hold; 10 plays since had no freeze, but the deferral never fired (`in_fex=0`), so the fix is
    not proven. If it freezes again, `[wpm-owner]` and the `susp=` sampler lines name the
    owner's state. Not covered: FEX's write holds outside a syscall callback
    (`HandleRWXAccessViolation`, the Mono back-patcher), which need a FEX TEB stamp (Linear
    follow-up of PLA-93).
  - **Lessons for the protocol.** Warm pairs often end with one run under a much tighter
    thermal budget than the other (pressure 20, a 404–667 mW client-11 budget), in either
    order, which swings FPS and sys mJ/f. GPU ms has been the column that holds; read the 5-s
    buckets and the budget columns before any other. Use a Graphics-options switch so a pair
    runs on one IPA (no reinstall between the runs). PLA-82 (a settings undo that turns the HUD
    or a GPU capture off) voided four runs; check each log for `Metal HUD off`.
  - **Next chunks, one change each:**
    1. `private_memory` (chunk 8's `patches/mesa` 0020, kept in
       `$PLAYPORT_BUILD/agent-notes/vulkan-perf/chunk8-patches/` and commit `c8c6016`) on top of
       0019, behind its flag, with one warm native/free vkd3d pair and one DXVK pair, for the
       residual both routes share.
    2. DXVK's own GPU time: first GPU time per pass on KosmicKrisp (or a capture with
       `--pass-prof`-style timing) to find where DXVK's extra ~2.5 ms go; candidates are the
       depth store in pass 20 of the King's Pass capture (17.2 MB a frame; DXMT stores none)
       and DXVK's render-pass store ops.
    3. Item 8 (FEX on the D3D12 route) for UnityGfxDeviceWorker's +9 Mi/f, with warm 720/60
       pairs.
    4. Proton's logging-off defaults for the release variant only (owner, 2026-10-08:
       `DXVK_LOG_LEVEL=none`, `VKD3D_DEBUG=none`, `VKD3D_SHADER_DEBUG=none`, `WINEDEBUG=-all`;
       dev keeps its logs), with a decision record. The research note behind it and other
       candidates (`dxvk.enableDescriptorUpdateTemplates`, `MESA_KK_EXPERIMENTAL=image_view_min_lod`)
       is left in the build area (`agent-notes/vulkan-perf/research-kk-defaults.md`).
    5. Then the cooled exit runs ([Exit criteria](#exit-criteria)), with the gate; stability
       counts every exit run and gate play.

# Vulkan performance: the two config levers (one-time submit, DXVK tiler mode)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue items 2 and 3. **Compared with:** the 0021 IPA's runs in
[present path](2026-10-08-vulkan-perf-present-path.md) (`vk-v2-dxvk-presentfix-1`,
`vk-v2-vkd3d-presentfix-1`). **Result:** `VKD3D_CONFIG=one_time_submit` not kept;
`dxvk.tilerMode=False` kept as the Vulkan backend's default
([decision 0066](../decisions/0066-dxvk-tiler-mode-off.md)).

Both lever runs were on the installed IPA dev
`baa20a273bfbc25cbfb3328bfc924c6abe87c11db4bbace99823106bc1504a96` (`977e26d`), with the
lever in the game's Graphics options (decision 0060). Phone: iPhone18,4, iOS 27.0, on
the charger at 100 %, unattended. Route v2, burst, 720/free (`burst.sh NAME dxvk|vkd3d
OPTION`: a new game, `hk-walk` at `first-frame+80`, 15-minute rest, 130 s), each started
at thermal `nominal`; neither log has a `ui: undo session` or `Metal HUD off` line
(PLA-82). Figures: `pp perf --compare … --window`. Run directories:
`$PLAYPORT_BUILD/perf-runs/vk-v2-*` and `$PLAYPORT_BUILD/ui-runs/20261008T043*`.

## Item 2: `VKD3D_CONFIG=one_time_submit` (D3D12 route)

**What it does (code read).** vkd3d-proton at its pin begins every command buffer it
records for a D3D12 command list (the list's own, its split iterations, the indirect and
render-pass suspend/resume fix-ups) with `VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT`
only under this flag (`command.c`, `d3d12_command_list_begin_command_buffer` and five
more); by default it passes 0, because D3D12 lets a closed command list be executed more
than once and vkd3d-proton then submits the same Vulkan command buffer again. Its only
built-in user is a workaround for Star Wars Outlaws (`device_workarounds.c`).
KosmicKrisp records every primary command both into Metal and, through its trampolines
(`kk_dispatch_cmd_gen.py`), into a `vk_cmd_queue` copy, so that a second submission can
re-record it into a new Metal command buffer (`kk_queue.c`,
`rerecord_and_commit_cmd_buffer`). With the flag the copy is skipped (`kk_cmd_buffer.c`
sets `one_time_submit` at `vkBeginCommandBuffer`).

**Correctness caveat.** If a game executes a command list twice with the flag on,
KosmicKrisp's resubmission replays an empty queue: the second execution draws nothing,
silently. Hollow Knight showed nothing wrong, but the flag is not safe as a default.

**Run** `vk-v2-vkd3d-ots-1` (`"graphicsOptions":"VKD3D_CONFIG=one_time_submit"`); the log
has `title: graphics options: VKD3D_CONFIG=one_time_submit` and vkd3d-proton's
`vkd3d_config_flags_init_once: VKD3D_CONFIG='one_time_submit'`.

| run (window 85–125 s) | FPS | p50 | p99 | p99.9 | ≥25/50/100 | GPU ms | Mi/f | CPU% | CPU mW | sys mW | srv/f | MiB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-v2-vkd3d-presentfix-1` | 118.0 | 8.34 | 16.67 | 29.18 | 8/0/0 | 5.86 | 65.1 | 119.8 | 2051 | 7663 | 17.00 | 3386 |
| `vk-v2-vkd3d-ots-1` | 117.9 | 8.34 | 16.67 | 25.01 | 6/0/0 | 5.85 | 64.8 | 119.5 | 2032 | 6393 | 17.05 | 3384 |

| thread Mi/f (t = 90, 105) | presentfix | one_time_submit |
|---|---|---|
| UnityGfxDeviceWorker | 17.91, 19.82 | 17.56, 19.47 |
| main (`002c`) | 20.81, 21.01 | 20.61, 20.90 |
| all threads | 63.0, 67.3 | 62.3, 67.1 |

**Why so little (investigated, no second run).** The copy is gone and UnityGfxDeviceWorker,
the thread that records the D3D12 lists, does 0.35 Mi/f less at both samples (−2 %): that
is what the skipped `vk_cmd_queue` appends cost. The rest of the worker's 18–20 Mi/f
(DXMT's is 9.4) is not the copy: it is the game's own render thread under FEX plus
vkd3d-proton's translation and KosmicKrisp's encoding into Metal, which the flag does not
touch. The plan's "vkd3d records every command twice" was right about the copy and wrong
about its weight. Total work, CPU power (−19 mW), p99 and GPU time are within one run's
noise. The end screenshot shows the Knight in the lumafly room of King's Pass with the HUD
on, drawn as in the control.

**Not kept** (rule 4): a 2 % saving on one thread does not pay for a default that drops
the work of any game that executes a command list twice. Where UnityGfxDeviceWorker's time
goes on vkd3d needs a CPU profile of the D3D12 route (none exists; `vk-prof-dxvk*` are
DXVK's).

## Item 3: `dxvk.tilerMode=False` (DXVK route)

**What it changes (code read).** DXVK at its pin turns tiler mode on for every
tile-based driver it knows, KosmicKrisp included (`dxvk_device.cpp`, `tilerMode`), which
sets `preferRenderPassOps` and `preferCachedMemory`. With `preferRenderPassOps`, each
render pass is recorded into a secondary command buffer (`dxvk_context.cpp`,
`beginSecondaryCommandBuffer`) so that later clears, discards and resolves can still change
its load and store ops; at the pass's end DXVK begins rendering on the primary and executes
the secondary into it. It also keeps image barriers in a batch and allocates new backing
storage for some resolves. KosmicKrisp has no native secondaries: its trampolines put every
secondary command into a `vk_cmd_queue` (`vk_cmd_enqueue_unless_primary`), and
`vkCmdExecuteCommands` (`vk_common_CmdExecuteCommands`) replays that queue into the primary,
all on `dxvk-cs`. Tiler mode off records the pass straight into the primary. Cached memory
changes nothing on KosmicKrisp, whose one memory type is cached and coherent
(`kk_physical_device.c`). The Graphics options field takes `dxvk.tilerMode=False` and passes
`DXVK_CONFIG=dxvk.tilerMode = False` (the log: `title: graphics options: DXVK_CONFIG=dxvk.tilerMode = False`,
DXVK: `Found config env: dxvk.tilerMode = False`).

**Run** `vk-v2-dxvk-notiler-1` (`"graphicsOptions":"dxvk.tilerMode=False"`). It went
through the opening cinematic (the video crash of the first branch, `vk-s3-dxvk-notiler1`,
is gone with `patches/dxvk` 0001). The Knight missed the held jump out of the pit (its end
screenshot shows him in the pit under the game's "HOLD A Jump" prompt; the controls end in
the lumafly room), so the scene differs from about t = 116 s, when `hk-walk` ended (step
86/86 at 116.2 s in the control, 121.3 s here). The window 85–115 s, in which both runs
are at the same place, is the like-for-like comparison; 85–125 s is given too.

| run | window | FPS | p50 | p99 | p99.9 | ≥25/50/100 | GPU ms | Mi/f | CPU% | CPU mW | sys mW | srv/f | MiB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-v2-dxvk-presentfix-1` | 85–115 | 118.0 | 8.34 | 16.67 | 33.35 | 7/0/0 | 5.81 | 60.5 | 129.7 | 1784 | 6208 | 11.98 | 3481 |
| `vk-v2-dxvk-notiler-1` | 85–115 | 118.2 | 8.34 | 16.67 | 33.35 | 7/0/0 | 5.80 | 57.5 | 127.0 | 1675 | 6316 | 12.38 | 3303 |
| `vk-v2-dxmt-2` | 85–115 | 119.4 | 8.34 | 8.34 | 16.67 | 1/0/0 | 6.10 | 51.8 | 152.2 | 1307 | 4936 | 11.78 | 2757 |
| `vk-v2-dxvk-presentfix-1` | 85–125 | 118.3 | 8.34 | 16.67 | 25.01 | 8/0/0 | 5.81 | 60.8 | 129.5 | 1805 | 6294 | 12.10 | 3498 |
| `vk-v2-dxvk-notiler-1` | 85–125 | 118.2 | 8.34 | 12.5 | 33.35 | 10/0/0 | 5.82 | 56.3 | 127.0 | 1633 | 6318 | 12.05 | 3305 |

| thread Mi/f (t = 90, 105) | tiler mode (presentfix) | tiler mode off |
|---|---|---|
| dxvk-cs | 4.30, 5.76 | 3.82, 3.96 |
| UnityGfxDeviceWorker | 11.48, 12.43 | 11.26, 11.96 |
| main (`002c`) | 20.22, 20.83 | 19.99, 20.26 |
| all threads | 57.9, 63.1 | 56.7, 58.2 |

**Result.** In the same scene, work a frame drops 3.0 Mi/f (−5 %, a third of the gap to
DXMT's 51.8 left after 0021: 8.7 → 5.7) and CPU power 109 mW (−6 %); dxvk-cs does 0.5 and
1.8 Mi/f less at the two samples, and the process holds 180 MiB less. GPU time, FPS, p50
and p99 do not move: the GPU cost a tile-based GPU could pay for load and store ops that
are now fixed at the pass's start did not show (5.81 against 5.80 ms). The end screenshot
is drawn correctly (King's Pass, the pit, the HUD on); no wrong clears or missing
attachments.

**Kept** (rule 4): it goes into `GraphicsBackend.runtimeEnvironment` for the Vulkan
backend, `DXVK_CONFIG=dxvk.tilerMode = False`. That reverses 0024's "no `DXVK_CONFIG`", so
it has [decision 0066](../decisions/0066-dxvk-tiler-mode-off.md). A dev build's Graphics
options used to replace the backend's `DXVK_CONFIG` wholesale, which would have turned tiler
mode back on in every later DXVK lever's run; they now follow it after `;`
(`GraphicsBackend.environment(graphicsOptions:)`, tested in PlayportKit), and DXVK takes the
last value of a key, so an option that names `dxvk.tilerMode` still wins.

## The kept default on the phone

**IPA:** dev `4349d6a269857544ffa2640053950f182e071ff8f21604b52b6e1ce930d3dccf`, built
from `vulkan-performance-2` at `79c081f` plus this change (Swift only; no build record
changed). `pp test` passed, `pp build` verified it (80 checks). One locked session:
`pp install --no-build` (upgrade in place, container kept), the gate, then one Hollow
Knight play with `{"graphics":"vulkan"}` and no Graphics options.

| play | run | first frame | result |
|---|---|---|---|
| Hollow Knight, the phone's default backend (Vulkan: DXVK) | `ui-runs/20261008T043115` | +9.69 s (JIT 2.50 s) | `first-frame+10`, title menu |
| Portal 2, default backend (Vulkan: DXVK, i386) | `ui-runs/20261008T043206` | +5.83 s (JIT 2.76 s) | `first-frame+10`, Source intro |
| Hollow Knight, `graphics: vulkan`, no options | `ui-runs/20261008T043251` | +9.91 s (JIT 2.69 s) | `first-frame+10` |

Each log has `title: environment: the backend's DXVK_CONFIG` and DXVK's
`Found config env: dxvk.tilerMode = False`, and no `title: graphics options` line: the
default carries it, in the 64-bit and the 32-bit DXVK. (These sessions log `hostio: Metal HUD
off` at the app's start, before the title: no HUD was asked for, and they are not perf
runs.) The Hollow Knight screenshot shows the title menu, Portal 2's the Source intro, both
drawn correctly.

**Correction to the earlier records:** the gate's Hollow Knight play on this phone runs on
Vulkan (DXVK), not DXMT: its log has `title: graphics: vulkan`, in this session and in the
[controls](2026-10-08-vulkan-perf-controls.md) and [present path](2026-10-08-vulkan-perf-present-path.md)
sessions. Both records are corrected.

## Games observed

- Hollow Knight (367520): route-v2 runs on vkd3d (`one_time_submit`) and DXVK (tiler mode
  off), both in play at the end; on `4349d6a2…` the gate and one Vulkan play, `first-frame+10`.
- Portal 2 (620): gate on `4349d6a2…` (DXVK, tiler mode off), `first-frame+10`.

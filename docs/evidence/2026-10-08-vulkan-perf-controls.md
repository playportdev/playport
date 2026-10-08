# Vulkan performance: route-v2 controls on one IPA

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), the controls the plan's rules compare every lever with. **IPA:** dev
`0d4a0f1e6c24a2548566894b4942231edf3e0e9f7413f0433464c9c60e68a929`, built from
`vulkan-performance-2` at `62427de` (main `1e08fe3` plus the first branch's work, with its
patches renumbered after main's series: `madeira-unix` 0096, `mesa` 0017, `wine-pe` 0031,
`wine-unix` 0020). Phone: iPhone18,4, iOS 27.0, on charge at 100 %, unattended (black
screen between runs). Run directories: `$PLAYPORT_BUILD/perf-runs/vk-v2-*` and
`$PLAYPORT_BUILD/ui-runs/20261008T01*`.

## The gate and one Direct3D 12 start

One locked session after `pp install --no-build` (default settings, `--shot`):

| play | run | first frame | result |
|---|---|---|---|
| Hollow Knight, the phone's default backend (Vulkan: DXVK; `title: graphics: vulkan`) | `ui-runs/20261008T014459` | +9.20 s | `first-frame+10`, title menu |
| Portal 2, default backend | `ui-runs/20261008T014550` | +5.38 s | `first-frame+10`, Source intro |
| Hollow Knight, `graphics: vulkan`, `-force-d3d12` (vkd3d) | `ui-runs/20261008T014633` | +8.37 s | `first-frame+10`, title menu; no `keyed wait returned` line (`wine-pe` 0031), no fault |

JIT came in 2.39–2.44 s on each. `wine-unix` 0020 holds on this base.

## Route v2, burst, 720 rows, free-running

Each run: `burst.sh NAME dxmt|dxvk|vkd3d`, that is `pp perf --secs 130 --cool 15
--cool-max 25 --settings '{"screen":"720","frameLimit":0,"graphics":…}' --pad
first-frame+25:hk-new-game --pad first-frame+80:hk-walk --shot first-frame+128` (vkd3d: plus
`"arguments":"-force-d3d12"`). Every run started at thermal `nominal`, 100 % on the charger,
after a 15-minute rest. Figures: `pp perf --compare vk-v2-dxmt-2 vk-v2-dxvk-2 vk-v2-vkd3d-1
--window 85:125`.

| run | FPS | p50 | p99 | p99.9 | ≥25/50/100 | GPU ms | gpu% | til% | Mi/f | CPU% | CPU mW | sys mW | sys mJ/f | srv/f | MiB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-v2-dxmt-2` | 119.5 | 8.34 | 8.34 | 16.67 | 1/0/0 | 6.19 | 82.6 | 65.8 | 51.7 | 151.5 | 1288 | 4909 | 41.1 | 12.0 | 2760 |
| `vk-v2-dxvk-2` | 118.5 | 8.34 | 12.5 | 25.01 | 7/0/0 | 5.81 | 78.5 | 76.3 | 61.5 | 132.3 | 1858 | 6090 | 51.4 | 17.8 | 3468 |
| `vk-v2-vkd3d-1` | 118.0 | 8.34 | 16.67 | 20.84 | 4/0/0 | 5.85 | 78.8 | 76.3 | 66.6 | 122.5 | 2060 | 6877 | 58.3 | 23.2 | 3369 |

The DXMT control is stable across the two IPAs: `vk-v2-dxmt-1` (IPA `bf3d38f0…`) gave 119.7
FPS, p99 8.34, GPU 6.18 ms, 52.9 Mi/f, 11.6 srv/f in the same window. The three end
screenshots show the Knight in King's Pass with the HUD on.

**`vk-v2-dxvk-1` lost its HUD figures** (FPS 118.1, Mi/f 57.6, srv/f 18.2 from the `[frames]`
lines; no frame interval, GPU ms or memory). Its play launch logged `ui: undo session
f0df58e972eb: restored … metalHUD …` (its own session) and `hostio: Metal HUD off`,
though the play's `launched` event names `UI_SESSION=f0df58e972eb`; its pulled log has the
app's start-up `memory:` line twice, as if a start without the session came first. The
cause is not known (a tooling follow-up). It was taken again once as `vk-v2-dxvk-2`,
unchanged, for the missing figures.

### The gap

| | DXMT | DXVK | vkd3d |
|---|---|---|---|
| FPS (window) | 119.5 | 118.5 (−1.0) | 118.0 (−1.5) |
| p99 frame interval | 8.34 ms | 12.5 ms | 16.67 ms |
| hitches ≥25 ms | 1 | 7 | 4 |
| Mi/f, all threads | 51.7 | 61.5 (+19 %) | 66.6 (+29 %) |
| Mi/f, main thread `002c` | 19.8 | 20.5 | 20.8 |
| Mi/f, UnityGfxDeviceWorker | 9.4 | 11.7 | 18.9 |
| Mi/f, the backend's submit thread | 4.2 (`dxmt-encode-thr`) | 5.0 (`dxvk-cs`) | – (none in the top six) |
| Mi/f, the largest host thread | 3.2 | 4.5 | 5.7 |
| srv/f (wineserver requests a frame) | 12.0 | 17.8 (+5.8) | 23.2 (+11.2) |
| GPU ms | 6.19 | 5.81 | 5.85 |
| CPU mW | 1288 | 1858 | 2060 |

Thread figures are the mean of `threads.txt`'s t = 90 and t = 105 tables (90–120 s), top
six a table. The window sits at the 120-Hz ceiling on all three, so FPS hides the gap; it
shows as p99, Mi/f and power. GPU time is 6 % lower on Vulkan; the gap is CPU.

**Wineserver requests.** Both Vulkan routes add `get_window_parents`, `get_window_rectangles`
and `get_windows_offset` at 2.0 a frame each (server request numbers 151, 157, 160 in the
unix tree's `server_protocol.h`), the six a frame of the plan's work-queue item 1 (Wine's
Vulkan present path). vkd3d adds about 1 `event_op`, 1 `release_semaphore`, 1
`set_queue_mask`, 1 `get_message` and 1 `select` a frame on top.

## Games observed

- Hollow Knight (367520): gate on the default backend (Vulkan: DXVK), one D3D12 start, three route-v2 runs (DXMT, DXVK
  twice, vkd3d), all in play at the end.
- Portal 2 (620): gate, `first-frame+10`.

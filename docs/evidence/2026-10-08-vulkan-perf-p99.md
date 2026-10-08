# Vulkan performance: the missed 120-Hz frames (p99)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 5. **Compared with:** `vk-v2-dxvk-notiler-1`
([config levers](2026-10-08-vulkan-perf-config-levers.md)), `vk-v2-vkd3d-presentfix-1`
([present path](2026-10-08-vulkan-perf-present-path.md)) and the DXMT control `vk-v2-dxmt-2`
([controls](2026-10-08-vulkan-perf-controls.md)). **Result:** `patches/mesa` 0018 (no present
wait on iOS) kept. On both Vulkan routes p99 is now 8.34 ms, DXMT's figure, and FPS is
at or above DXMT's. A first change, taking the drawable at present, did nothing and was
reverted.

Phone: iPhone18,4, iOS 27.0, on the charger at 100 %, unattended. Route v2, burst, 720/free
(`burst.sh NAME dxvk|vkd3d`: a new game, `hk-walk` at `first-frame+80`, a 15-minute rest,
130 s, `--shot first-frame+128`). Every run started at thermal `nominal` and logged no
thermal pressure change in its window. No run log has a `ui: undo session` or
`Metal HUD off` line (PLA-82), so no reruns were needed. Run directories:
`$PLAYPORT_BUILD/perf-runs/vk-v2-*`. Figures come from `pp perf --compare … --window`. The
per-frame analysis reads the Metal HUD's lines, which give each frame's (interval, GPU
time).

## The frame-interval traces (no phone time)

In the window t = 85–125 s, an interval above 8.34 ms is a "late" frame. At 120 Hz a p99 of
16.67 ms means at least 1 % of frames missed one refresh.

| run | frames | late | missed refreshes | GPU ms p50 / p99 | late frames with ≥ 1.5× median GPU time | of those, next to a frame under 1.5 ms | frames under 1.5 ms GPU |
|---|---|---|---|---|---|---|---|
| `vk-v2-dxmt-2` | 4802 | 19 (0.40 %) | 15 | 6.56 / 7.44 | 0 | 0 | 0 |
| `vk-v2-dxvk-notiler-1` | 4699 | 55 (1.17 %) | 61 | 5.86 / 10.47 | 40 | 35 | 163 |
| `vk-v2-vkd3d-presentfix-1` | 4700 | 68 (1.45 %) | 69 | 5.81 / 9.94 | 47 | 45 | 64 |

- **Not periodic.** The Vulkan runs' late frames are spaced irregularly, 1 to 540 frames
  apart, and half to 60 % of them come within five frames of another. DXMT's late frames
  are fewer and mostly in a few clusters (t = 100, 112–115 and 120 s).
- **Not shader compiles or thermal.** The ≥ 25 ms hitches (7 to 10 a run) line up with FEX
  JIT bursts (`hitches.txt`'s jit/mprot columns). The 16.67 ms frames do not. No run's
  thermal pressure changed in the window.
- **Not GPU cost.** On Vulkan, a late frame's HUD GPU time is about twice the median
  (10–13 ms), and the frame next to it shows only the present blit (0.3–0.9 ms). That is
  two frames' GPU work counted between one pair of presents: the next frame was rendered
  before the late one reached the screen. The late frame's own GPU work was done in time.
  DXMT's late frames carry normal GPU times (4–9 ms), and DXMT never shows a frame under
  1.5 ms.

**What decides the drawable count and who waits (code read).** The Metal WSI asks for
`minImageCount = maxImageCount = 3`, so DXVK's swap chain has 3 images ("Image count: 3"
in the log). The layer's `maximumDrawableCount` is the image count, 3, the same as DXMT's.
`dxgi.numBackBuffers` no longer exists at DXVK's pin. `dxgi.maxFrameLatency` can only
lower the latency, never raise it. DXVK takes its next image right after each present,
on `dxvk-submit` (`Presenter::presentImage`). KosmicKrisp's acquire is
`PacedMetalLayer.nextDrawable`, and the WSI blit waits for the drawable on the Metal 4
queue (`waitForDrawable`). DXMT calls `nextDrawable` only when it encodes the present
pass, after the frame's work: its `[FRAME_STATS]` lines show `drawable_block` 7.2 ms a
frame, so a finished frame is always waiting for the display.

**Frame latency.** DXVK and vkd3d-proton release the game's frame latency
(`D3D11SwapChain::SyncFrameLatency`; vkd3d-proton's latency handle, which the D3D12 game
waits on) from their present-wait thread. With `VK_KHR_present_wait` that happens once
the previous frame is on the screen, from the drawable's presented handler (`patches/mesa`
0010). DXMT releases its latency when the previous frame's command buffer completes
(`CommandQueue::PresentBoundary`, `frame_latency_fence_`). The device log's `[kk-wsi]`
trace shows the result on both Vulkan routes: each present N+1 is issued after
`presented N-1` and before `presented N`, every time. The game runs exactly one frame
ahead of the screen, with a frame latency of one. A frame then has one refresh, less
the presented handler's delay, for Unity's render thread, `dxvk-cs`, the submit and
about 6 ms of GPU work. Any delay in that chain misses a refresh, and the GPU then
renders the next frame before the late one is shown, which is the doubled GPU time
above.

**Hypothesis (the second one; the first is below):** the present-wait release is the
cause. Without present wait, DXVK (`m_hasPresentWait`) and vkd3d-proton
(`chain->present.wait`) release the latency when the present's GPU work is done, as DXMT
does.

## Change 1, not kept: the drawable at present (`vk-v2-dxvk-p99-1`)

The first hypothesis was that the drawable held the work back. The WSI took its
drawable in `vkAcquireNextImageKHR`, and DXVK acquires right after each present, on the
thread that submits everything. So the next frame's work could reach the GPU only once
the display freed a drawable. Change: a Metal-only `prepare_present` hook in
`wsi_common_queue_present` took the drawable and recorded the blit at present. Acquire
waited only for the image's throttle fence. Commit `989a891`, IPA dev
`7de81c1c99e681e46ca2873ad839662ec16699f92c6f20f9967dcf91f66ba903`. The gate passed:
Hollow Knight on Vulkan (`ui-runs/20261008T045747`, first frame +9.58 s) and on DXMT
(`…T045923`, +9.34 s), and Portal 2 (`…T045838`, +5.61 s).

| run | window | FPS | p50 | p99 | p99.9 | ≥25/50/100 | GPU ms | Mi/f | CPU mW | sys mW |
|---|---|---|---|---|---|---|---|---|---|---|
| `vk-v2-dxvk-notiler-1` | 85–115 | 118.2 | 8.34 | 16.67 | 33.35 | 7/0/0 | 5.80 | 57.5 | 1675 | 6316 |
| `vk-v2-dxvk-p99-1` | 85–115 | 117.3 | 8.34 | 16.67 | 33.35 | 10/1/0 | 5.80 | 59.0 | 1684 | 6096 |

No gain: 73 late frames instead of 55, with the same doubled-GPU pattern. The run's
`[kk-wsi]` trace still shows the present N+1 / presented N-1 lockstep with the drawable no
longer taken at acquire. That ruled the drawable out and pointed to the frame latency.
**Not kept.** It was reverted in `aef9f57` and never run on the D3D12 route, since the
trace already showed it could not change the lockstep there either.

## Change 2, kept: no present wait on iOS (`patches/mesa` 0018)

On iOS, KosmicKrisp no longer advertises `VK_KHR_present_wait` or `VK_KHR_present_wait2`.
The Metal WSI reports `presentWait2Supported` only when the device has the extension.
`present_id` and `present_id2` stay. The logs show the effect: `[kk-wsi] present … wait=0`,
and vkd3d-proton's `Implementation supports neither present_wait1 or present_wait2`.
Commit `80d48bf`. **IPA:** dev
`b024e1f756b9520af7253bd5eed3e7d476908c60c555bd39e56d698722e57b1a`, built from that commit.
`pp test` passed, and `pp build` verified the IPA (80 checks). One locked session:
`pp install --no-build`, then the gate.

| play | run | first frame | result |
|---|---|---|---|
| Hollow Knight, default backend (`title: graphics: vulkan`, DXVK) | `ui-runs/20261008T052535` | +9.67 s (JIT 2.54 s) | `first-frame+10`, title menu |
| Portal 2, default backend (DXVK, i386) | `ui-runs/20261008T052626` | +5.59 s (JIT 2.53 s) | `first-frame+10`, Source intro |
| Hollow Knight, `{"graphics":"dxmt"}` | `ui-runs/20261008T052710` | +8.55 s (JIT 2.52 s) | `first-frame+10`, title menu |

Then one route-v2 run per Vulkan route on the default settings, which are the
confirming runs as well. Nothing changed between them and the commit.

**DXVK** (`vk-v2-dxvk-p99-2`, against `vk-v2-dxvk-notiler-1`; its Knight missed the held jump out of
the pit as the control's did, so 85–115 s is like for like):

| run | window | FPS | p50 | p99 | p99.9 | ≥25/50/100 | GPU ms | gpu% | Mi/f | CPU% | CPU mW | sys mW | sys mJ/f | srv/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-v2-dxvk-notiler-1` | 85–115 | 118.2 | 8.34 | 16.67 | 33.35 | 7/0/0 | 5.80 | 78.8 | 57.5 | 127.0 | 1675 | 6316 | 53.4 | 12.38 |
| `vk-v2-dxvk-p99-2` | 85–115 | 119.5 | 8.34 | 8.34 | 25.01 | 4/0/0 | 6.55 | 86.8 | 57.1 | 145.5 | 1500 | 6408 | 53.6 | 11.70 |
| `vk-v2-dxmt-2` | 85–115 | 119.4 | 8.34 | 8.34 | 16.67 | 1/0/0 | 6.10 | 81.7 | 51.8 | 152.2 | 1307 | 4936 | 41.3 | 11.78 |
| `vk-v2-dxvk-notiler-1` | 85–125 | 118.2 | 8.34 | 12.5 | 33.35 | 10/0/0 | 5.82 | 79.1 | 56.3 | 127.0 | 1633 | 6318 | 53.4 | 12.05 |
| `vk-v2-dxvk-p99-2` | 85–125 | 119.6 | 8.34 | 8.34 | 16.67 | 4/0/0 | 6.53 | 86.6 | 56.1 | 146.3 | 1467 | 6456 | 54.0 | 11.84 |

**vkd3d-proton** (`vk-v2-vkd3d-p99-1`, against `vk-v2-vkd3d-presentfix-1`; both end in the lumafly
room):

| run | window | FPS | p50 | p99 | p99.9 | ≥25/50/100 | GPU ms | gpu% | Mi/f | CPU% | CPU mW | sys mW | sys mJ/f | srv/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-v2-vkd3d-presentfix-1` | 85–125 | 118.0 | 8.34 | 16.67 | 29.18 | 8/0/0 | 5.86 | 79.0 | 65.1 | 119.8 | 2051 | 7663 | 64.9 | 17.00 |
| `vk-v2-vkd3d-p99-1` | 85–125 | 119.8 | 8.34 | 8.34 | 16.67 | 0/0/0 | 6.53 | 84.5 | 65.1 | 113.9 | 2115 | 7410 | 61.9 | 16.91 |
| `vk-v2-dxmt-2` | 85–125 | 119.5 | 8.34 | 8.34 | 16.67 | 1/0/0 | 6.19 | 82.6 | 51.7 | 151.5 | 1288 | 4909 | 41.1 | 12.01 |

The intervals, with the same analysis as above:

| run | frames | late | missed refreshes | GPU ms p50 / p99 | late with ≥ 1.5× GPU | frames under 1.5 ms GPU |
|---|---|---|---|---|---|---|
| `vk-v2-dxvk-p99-2` | 4802 | 9 (0.19 %) | 14 | 6.64 / 7.55 | 5 | 17 |
| `vk-v2-vkd3d-p99-1` | 4801 | 9 (0.19 %) | 7 | 6.66 / 7.64 | 7 | 37 |

| thread Mi/f (t = 90, 105) | DXVK before | DXVK after | vkd3d before | vkd3d after |
|---|---|---|---|---|
| main (`002c`) | 19.99, 20.26 | 20.73, 19.41 | 20.81, 21.01 | 19.90, 20.83 |
| UnityGfxDeviceWorker | 11.26, 11.96 | 11.57, 11.44 | 17.91, 19.82 | 17.04, 19.59 |
| dxvk-cs | 3.82, 3.96 | 4.05, 3.92 | – | – |
| all threads | 56.7, 58.2 | 58.5, 55.8 | 63.0, 67.3 | 60.6, 67.6 |

**Result.** On both routes, late frames fall from 1.2–1.5 % to 0.19 %, half of DXMT's 0.40 %.
p99 is 8.34 ms (DXMT's), p99.9 is 16.67 ms on the full window, and FPS is 119.5–119.8
(DXMT 119.4–119.5). On vkd3d the ≥ 25 ms hitches go from 8 to 0. Work a frame does not
move. On DXVK, CPU power falls 175 mW (−10 %), and the P cores run at 3.40 GHz instead of
3.58 GHz. On vkd3d it rises 64 mW at 1.5 % more frames, and the
phone's power a frame falls 5 % (64.9 → 61.9 mJ/f). The end screenshots are drawn
correctly: King's Pass with the HUD on, the Knight in the pit (DXVK) and in the lumafly
room (vkd3d), each as in its control.

**GPU ms rose on both routes, 5.8 → 6.55 ms (+13 %; DXMT 6.1–6.2).** The work did not
change: same passes, same Mi/f. GPU utilization rose with it, 79 → 85–87 %. Two readings
fit, and this record measures neither:

- The GPU now has a frame queued at all times, so it may run at a lower clock.
- Metal's per-frame GPU time may now count a blit's wait for its drawable
  (`waitForDrawable`).

The phone's power a frame did not rise (DXVK 53.4 → 53.6 mJ/f, vkd3d 64.9 → 61.9), which
fits a lower clock. The exit criterion "GPU ms ≤ DXMT + 5 %" (720/free burst) now reads
+7 % on both routes. The native/free run, where GPU time limits FPS, will show whether
this costs frames.

**Kept** (rule 4). The lever is a `patches/mesa` patch, not a `GraphicsBackend.runtimeEnvironment`
setting, and it reverses no decision (0024 and 0066 are about `DXVK_CONFIG`), so no decision
record. Present wait was what `patches/mesa` 0010 made safe. That code stays for macOS and
is no longer reached on iOS.

## Games observed

- Hollow Knight (367520): on `7de81c1c…` the gate (Vulkan and DXMT) and one DXVK route-v2
  run, in play at the end; on `b024e1f7…` the gate (Vulkan and DXMT) and one route-v2 run each on DXVK and
  vkd3d, in play at the end.
- Portal 2 (620): gate on `7de81c1c…` and on `b024e1f7…` (DXVK, i386), `first-frame+10`.

# Vulkan performance: native resolution, 720/60, CPU profiles, and texture usage (not kept)

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 6 and the GPU-time question item 5 left open. **IPA** for the
comparison and profile runs: dev
`b024e1f756b9520af7253bd5eed3e7d476908c60c555bd39e56d698722e57b1a` (commit `80d48bf`).
**Result:**

- At native/free the Vulkan routes reach about half DXMT's FPS once the phone's thermal
  budget applies (DXVK 57.7, vkd3d 56.4, DXMT 108.9). Their GPU time a frame doubles, and the
  phone's energy a frame is 40–100 % higher. `patches/mesa` 0018 is not the cause.
- At 720/60 DXVK uses 10 % more CPU power than DXMT and 8 % more phone power. vkd3d-proton
  uses 45 % and 10 % more.
- In the CPU profiles, KosmicKrisp and the WSI submit thread are each under 1 % of samples, so
  no safe CPU change ranks.
- `patches/mesa` 0019 (Metal texture usage without shader write or pixel format view) did not
  move native/free and is **not kept**.

Phone: iPhone18,4, iOS 27.0, on the charger at 100 %, unattended. Every run uses route v2:
a new game, `hk-walk` at `first-frame+80`, 130 s, `--shot first-frame+128`. Each run is cooled
(`--cool 15 --cool-max 25`) and started at thermal `nominal`. Run directories are
`$PLAYPORT_BUILD/perf-runs/<name>`, and the figures come from `pp perf --compare … --window`.
`vk-nat-vkd3d-1` logged `hostio: Metal HUD off` (PLA-82) and has no HUD figures, so it is
void. It was rerun once as `vk-nat-vkd3d-2`. No other run has an `ui: undo session` or
`Metal HUD off` line. CPU mJ/f is CPU mW / FPS. The phone's mW comes from the battery gauge
(one sample every 5 s, and not reliable within one 25-s window: see sys mW at t = 15–40).

## Native resolution, free-running (2736×1260)

| run | window | FPS | p99 | ≥25/50/100 | GPU ms | gpu% | Mi/f | P% | CPU mW | CPU mJ/f | sys mW | sys mJ/f | srv/f |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-nat-dxmt-1` | 15–40 | 118.5 | 8.34 | 8/4/0 | 6.64 | – | 34.4 | 83 | 698 | 5.9 | 6203 | 52.3 | 11.7 |
| `vk-nat-dxvk-1` | 15–40 | 116.8 | 8.34 | 14/8/1 | 7.10 | 88.6 | 42.5 | 92 | 745 | 6.4 | 6977 | 59.7 | 11.8 |
| `vk-nat-vkd3d-2` | 15–40 | 117.0 | 8.34 | 15/6/1 | 6.76 | 85.8 | 42.3 | 97 | 798 | 6.8 | 12713 | 108.7 | 17.4 |
| `vk-nat-dxmt-1` | 85–125 | 108.9 | 20.84 | 9/1/1 | 7.46 | – | 53.1 | 75 | 900 | 8.3 | 6660 | 61.2 | 12.4 |
| `vk-nat-dxvk-1` | 85–125 | 57.7 | 37.51 | 280/8/3 | 13.40 | 86.0 | 76.6 | 0 | 200 | 3.5 | 5201 | 90.1 | 18.8 |
| `vk-nat-vkd3d-2` | 85–125 | 56.4 | 41.68 | 396/12/4 | 10.18 | 68.4 | 80.4 | 0 | 210 | 3.7 | 7053 | 125.0 | 23.9 |
| `vk-nat-dxmt-1` | 110–135 | 91.4 | 25.01 | 26/1/1 | 8.15 | – | 55.1 | 8 | 289 | 3.2 | 5130 | 56.1 | 13.8 |
| `vk-nat-dxvk-1` | 110–135 | 52.1 | 41.68 | 203/7/2 | 16.15 | 91.2 | 76.6 | 0 | 182 | 3.5 | 4567 | 87.7 | 20.2 |
| `vk-nat-vkd3d-2` | 110–135 | 48.9 | 45.85 | 368/8/5 | 12.31 | 73.6 | 82.1 | 0 | 187 | 3.8 | 4402 | 90.0 | 26.3 |

(`vk-nat-dxmt-1`'s `dvt graphics` sampler returned nothing, so its gpu% is missing.)

- **While the phone is cool** (15–40 s), all three hold the 120-Hz ceiling. GPU time is
  within 7 % of DXMT's.
- **Thermal pressure** reached level 10 (`summary.json` `first_pressure_s`) at about 45 s on
  DXVK, 40 s on vkd3d and 105 s on DXMT. From then on all three park the P cores (P% 0–8).
  DXMT keeps 91–109 FPS with 7.5–8.2 ms of GPU time a frame. On both Vulkan routes the GPU
  time a frame doubles (DXVK 13–16 ms, 86–91 % busy) and FPS halves. The same work taking
  twice as long points to a GPU clock held down by the power budget; no tool here reads the
  GPU clock. DXVK's run logs a CPMS budget of 2874 mW (client 11), and DXMT's logs none.
- **This is not `patches/mesa` 0018.** At 720/free the phone's energy a frame was 53.4 mJ
  before 0018 (`vk-v2-dxvk-notiler-1`) and 53.6 after (`vk-v2-dxvk-p99-2`), against DXMT's
  41.3 ([p99](2026-10-08-vulkan-perf-p99.md)). The Vulkan route has drawn about 30 % more a
  frame all along, and CPU power accounts for about 200 mW of the 1.5 W. GPU ms at 720 rose
  with 0018 because the GPU now always has a frame queued. At native, where the GPU sets the
  pace, the cost is the energy a frame, and the Vulkan routes reach the budget sooner and
  get less from it.

## 720 rows, 60 FPS (the players' default)

| run (window 85–125) | FPS | p99 | ≥25/50 | GPU ms | gpu% | Mi/f | CPU mW | CPU mJ/f | sys mW | sys mJ/f | srv/f | MiB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-60-dxmt-1` | 59.9 | 29.18 | 131/1 | 6.45 | 49.0 | 67.3 | 559 | 9.3 | 2888 | 48.2 | 18.8 | 2788 |
| `vk-60-dxvk-1` | 59.9 | 25.01 | 28/3 | 10.65 | 73.3 | 73.9 | 616 | 10.3 | 3132 | 52.3 | 18.9 | 3281 |
| `vk-60-vkd3d-1` | 59.7 | 25.01 | 176/2 | 9.51 | 71.5 | 82.5 | 808 | 13.5 | 3182 | 53.3 | 24.5 | 3361 |

No run changed thermal pressure. Against DXMT, DXVK uses +10 % CPU mW, +8 % phone mW and
+10 % Mi/f. vkd3d uses +45 % CPU mW, +10 % phone mW and +23 % Mi/f. The GPU is busy 71–73 %
of the time on Vulkan against 49 % on DXMT. At this load its clock is low, so GPU ms at
60 FPS is not comparable with the free-running figures.

## CPU profiles at native/free (`--cpu-prof`; figures not compared)

`vk-prof-dxvk-4` (10 294 running samples) and `vk-prof-vkd3d-1` (11 336). Each table gives
the thread's modules as % of **all** samples (`profile.txt`'s `thread-module`).

**DXVK (`vk-prof-dxvk-4`)**

| thread (share) | split |
|---|---|
| main `w…150` (55.0) | guest x64-JIT 41.1, xtajit64 (FEX) 7.4, kernel 4.8, S1Probe 0.8, ntdll 0.6 |
| wineserver `m…135` (14.0) | kernel 13.0, S1Probe 0.9 |
| UnityGfxDeviceWorker (10.2) | guest 6.7, kernel 2.0, xtajit64 0.9, d3d11 0.4 |
| dxvk-cs (6.1) | AGX 1.4, kernel 1.4 (`kevent_id` 0.9), KosmicKrisp 0.6, d3d11 0.5, objc 0.4, libsystem_platform 0.3, Metal 0.2, malloc 0.2, IOGPU 0.2 |
| dxvk-submit (0.4) | AGX 0.1, kernel 0.1 |

On dxvk-cs, Apple's driver (AGX, IOGPU, Metal, objc) has 2.2 against KosmicKrisp's 0.6 and
DXVK's 0.5: the same ratio as `vk-prof-dxvk3`, at half the share (dxvk-cs went from 10.6 to
6.1 % with tiler mode off). No single KosmicKrisp function reaches the sampler's table.
**The WSI submit thread (`dxvk-submit`) is 0.4 % in all**, so item 4's two trims (one submit
instead of two, the blit's re-recording at acquire) cannot show in a run. They are dropped
from the queue.

**vkd3d-proton (`vk-prof-vkd3d-1`)**

| thread (share) | split |
|---|---|
| main `w…999` (48.5) | guest 36.2, xtajit64 7.4, kernel 3.4, ntdll 0.6, S1Probe 0.5 |
| UnityGfxDeviceWorker (24.5) | guest 10.4, xtajit64 3.1 (`ios_ec_xlate_loop` 1.6, `ExitFunctionEC` 1.1), kernel 3.0 (`kevent_id` 1.2), AGX 2.0, KosmicKrisp 1.0, d3d12core 0.8, objc 0.9, libsystem_platform 0.5, IOGPU 0.4, Metal 0.3, malloc 0.3, S1Probe 0.3 |
| wineserver `m…978` (13.3) | kernel (`read` 8.9, `semaphore_timedwait_trap` 2.0) |
| `w…058` (7.0) | guest 6.8 (`UnityPlayer.dll+1747900` 5.7) |
| vkd3d_queue (0.5) | kernel 0.2 |

UnityGfxDeviceWorker's guest blocks: `UnityPlayer.dll+941800` 1.5, `+958300` 1.3,
`+15a400` 0.8, `+494800` 0.7, `+916700` 0.7. vkd3d-proton records on the game's render
thread, so the Metal encoding that DXVK does on dxvk-cs lands there. The worker is split
into FEX (guest and xtajit64) 13.5, Apple's driver 3.6, KosmicKrisp 1.0 and vkd3d-proton
0.8. Against DXVK's worker (guest 6.7, xtajit64 0.9), Unity's D3D12 renderer runs about
1.5× the guest code, with 3× the ARM64EC transitions. That is FEX's and Unity's work, not
vkd3d-proton's or KosmicKrisp's.

## Change, not kept: Metal texture usage (`patches/mesa` 0019, `vk-nat-dxvk-0019-1`)

**Lead.** In the step-0 captures (`gpu-runs/vk-kk-cap1`, `gpu-runs/vk-dxmt-cap1`), DXMT's
1564×720 RGBA8 render target has Metal usage `0x5` (shader read, render target). KosmicKrisp
creates the same target, and every DXVK texture, as `0x17`, which adds **shader write** and
**pixel format view**. Neither usage is needed for what KosmicKrisp does:

- `kk_image_layout.c` sets shader write for `VK_IMAGE_USAGE_TRANSFER_DST_BIT`, which DXVK gives
  every texture. KosmicKrisp writes into images only with Metal copies and render passes.
- It sets pixel format view for `MUTABLE_FORMAT`, and DXVK marks typed colour textures
  mutable with a format list of the format and its sRGB twin.

Metal turns lossless compression off for either usage.

**Change.** Commit `f54a36e`: shader write only for storage images, and no pixel format view
when the format list names only sRGB or linear twins. IPA dev
`f9a12132d796230a64a1912e3d82bf7064961857d07cc451aa7707d63d16ddee`. `pp test` passed, and
`pp build` verified the IPA (80 checks). One locked session ran `pp install --no-build`, the
gate and the run:

| play | run | first frame | result |
|---|---|---|---|
| Hollow Knight, default (Vulkan, DXVK) | `ui-runs/20261008T091014` | +8.86 s (JIT 2.60 s) | `first-frame+10` |
| Hollow Knight, `{"graphics":"dxmt"}` | `ui-runs/20261008T091105` | +9.72 s (JIT 2.48 s) | `first-frame+10` |
| Portal 2, default (DXVK, i386) | `ui-runs/20261008T091202` | +5.64 s (JIT 2.47 s) | `first-frame+10` |

| run | window | FPS | p99 | ≥25/50/100 | GPU ms | gpu% | Mi/f | CPU mW | CPU mJ/f | sys mW | sys mJ/f |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-nat-dxvk-1` | 15–40 | 116.8 | 8.34 | 14/8/1 | 7.10 | 88.6 | 42.5 | 745 | 6.4 | 6977 | 59.7 |
| `vk-nat-dxvk-0019-1` | 15–40 | 117.5 | 8.34 | 12/6/0 | 6.75 | 85.8 | 42.2 | 739 | 6.3 | 10990 | 93.5 |
| `vk-nat-dxvk-1` | 85–125 | 57.7 | 37.51 | 280/8/3 | 13.40 | 86.0 | 76.6 | 200 | 3.5 | 5201 | 90.1 |
| `vk-nat-dxvk-0019-1` | 85–125 | 59.2 | 33.35 | 225/8/4 | 13.26 | 86.5 | 76.2 | 204 | 3.5 | 4992 | 84.3 |
| `vk-nat-dxvk-1` | 110–135 | 52.1 | 41.68 | 203/7/2 | 16.15 | 91.2 | 76.6 | 182 | 3.5 | 4567 | 87.7 |
| `vk-nat-dxvk-0019-1` | 110–135 | 53.5 | 37.51 | 177/6/3 | 15.85 | 91.6 | 76.1 | 187 | 3.5 | 4639 | 86.7 |

Thermal pressure 10 came at 75 s (control: 45 s). After it, FPS rose by 1.4 and GPU ms fell
by 1–2 %, both within noise. In the cool window GPU ms fell 7.10 → 6.75 (DXMT 6.64), but one
run cannot separate that from noise either. The end screenshot is drawn correctly: King's
Pass at 2736×1260, with the HUD, the Knight in play. **Not kept** (rule 4):
the energy a frame and the throttled GPU time did not move. Reverted in the commit that adds
this record. Whether Metal now compressed the targets is not measured: Metal reports only
the compression type it was asked for. So this rules out the usage flags as the cause, not
compression itself.

## The queue this ranks (not implemented in this chunk)

1. **GPU energy a frame at native** (DXVK and vkd3d +40–100 % mJ/f; half DXMT's FPS under the
   budget). The largest gap. First move: a gameplay GPU capture of King's Pass on both
   backends (`pp gpu capture`), compared pass by pass: storage modes (KosmicKrisp places every
   texture in a shared-storage placement heap; DXMT creates its own with
   `newTextureWithDescriptor`, storage mode not yet read from the capture), load and store actions,
   and the WSI's extra full-screen copy at 2736×1260. Then one native/free run per change.
2. **FEX on the D3D12 route (plan step 7):** UnityGfxDeviceWorker's guest and xtajit64 time is
   13.5 % of samples against DXVK's 7.6, and that gap drives vkd3d's +45 % CPU mW at 720/60.
3. **Apple's driver on the recording thread:** dxvk-cs 2.2 % and the vkd3d worker 3.6 %,
   against KosmicKrisp's 0.6–1.0 %. This needs symbolised AGX frames or a per-draw count of
   the Metal calls KosmicKrisp makes, which today's sampler does not give.
4. Dropped: the WSI's two submit trims (`dxvk-submit` 0.4 % of samples).

## Games observed

- Hollow Knight (367520): on `b024e1f7…`, native/free runs on DXMT, DXVK and vkd3d (two;
  `vk-nat-vkd3d-1` void, HUD off), 720/60 runs on all three, and `--cpu-prof` runs on DXVK
  and vkd3d. On `f9a12132…`, the gate on Vulkan and on DXMT, and one DXVK native/free run.
  Every one ended in play.
- Portal 2 (620): gate on `f9a12132…` (DXVK, i386), `first-frame+10`.

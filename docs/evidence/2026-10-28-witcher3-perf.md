# The Witcher 3 4.x: PAUSE as WFE raises the mean frame rate 4–9 % but multiplies long frames; resolution is the lever on a hot phone (PLA-455)

**Linear:** [PLA-455](https://linear.app/playportdev/issue/PLA-455) (this work);
[PLA-43](https://linear.app/playportdev/issue/PLA-43) (the title); [PLA-452](https://linear.app/playportdev/issue/PLA-452)
(the short reservations that let the 4.x build reach gameplay).
**Question:** what limits The Witcher 3's 4.x build (D3D12 through vkd3d-proton and KosmicKrisp) in sustained
play, and what can Playport change to raise its frame rate?
**Result:**
- **The clamp.** After about 55 s of play the SoC's power clamp parks the P cores, and the game runs on E cores
  at 1.2–1.3 GHz.
- **The spinning thread.** The busiest thread waits for work with `pause` and QueryPerformanceCounter.
- **WFE raises the mean, not the tail.** `patches/fex` 0083 adds `MADEIRA_FEX_PAUSE=wfe`, which compiles x86
  PAUSE to WFE rather than YIELD.
  - Rested: the steady mean rises from 22.4 to 24.4 fps (+8.7 %).
  - Hot: +4 % at 1564x720 and +9 % at 1302x600.
  - But frames over 150 ms rise about five-fold, and p99 from 100–117 to 150–183 ms on a hot phone
    ([§ 6](#6-hitches-wfe-trades-them-for-frame-rate)).
  - Decision [0162](../decisions/0162-the-witcher-3-pause-as-wfe.md) made WFE the default on the mean.
    [0163](../decisions/0163-the-witcher-3-keeps-yield.md) withdrew it the same day on the tail.
- **Resolution helps on a hot phone.** 1302x600 against 1564x720 gives +15 % fps (GPU 44 → 32 ms), but no fewer
  hitches ([§ 7](#7-a-hot-phone-and-the-games-resolution)).

**Resolution caveat.** From the `w3-s600` experiment on, the game kept the 1302x600 it chose under Playport's
600-row screen: it saves its own resolution (`dx12user.settings`). So every run in §§ 3–4 rendered at 1302x600,
not 1564x720 (`[kk-wsi] create chain` in each run's `this-launch.log`). Comparisons within a table hold; the
screen-600 arm of § 4 is void.

Phone: iPhone18,4, iOS 27.0.1, `dev.playport.app`, unattended. Nobody played; every run is `pp perf`:

```sh
pp perf --title app-292030 --secs 150 --cool 8 --cool-max 20 \
  --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk \
  --shot first-frame+60 --shot first-frame+140 --settings JSON
```

The pad scripts load the Kaer Morhen save (Geralt's bedroom, the "Welcome to the tutorial" panel up) and walk.
The game's own settings are already its low preset (`dx12user.settings`: `LockhartPerformanceMode=true`,
`TextureDownscale=2`, SSAO, SSR, bloom and shafts off, `LimitFPS=0`). Every window is +60 to +150 s after the
first frame. Run directories are `.work/perf/w3-*`, `w3x-*` and `w3y-*`. Screenshots stay there (the game's
artwork is not ours to publish). Analysis scripts are in `.work/agent-notes/w3-perf/`.

## 1. What limits it

- **The power clamp.** At first the game runs at 33–35 fps with both clusters on, GPU-bound (29 ms GPU,
  96 % busy). After +55 s the lowest CPMS budget drops to 404–1,180 mW and the P cores park (P% 0).
  Every window below is in that regime.
- **A spinning render thread.** In a `--cpu-prof` run on the defaults (`w3-prof1`), RenderThread (`00f4`) is 39 %
  of all CPU samples, 26 % of them in `ntdll!RtlQueryPerformanceCounter`. Its code is the game's
  command-ring consumer at `witcher3.exe+0x1c69ae0`:
  - It reads the ring head with `lock cmpxchg`.
  - When the ring is empty, it calls QueryPerformanceCounter and `pause`, and loops.
  - It spins for up to 5 ms of the timer (`0.005 × frequency`, constant `0x143ab7ca8`).
  - It reads QPC 1.8–2.7 M times a second.
  - The same pattern shows up elsewhere. RenderDispatcher1/2 poll `ID3D12Fence::GetCompletedValue` at
    `+0x4f0f30`, and ModioThread (mod.io's asio loop) takes 16 % of samples.
- **FEX's PAUSE.** FEX compiles PAUSE to YIELD (`OpcodeDispatcher.cpp`), and Apple's cores treat YIELD as a NOP.
  So under the clamp, these spins take E-core time and power that the main thread and the GPU could use.

## 2. The change

`patches/fex` 0083: `MADEIRA_FEX_PAUSE=wfe` compiles PAUSE to WFE, and `=isb` compiles it to ISB. Unset keeps
YIELD.
- The frontend sets `IosPauseMode` before any code is compiled and logs `FEX: pause mode=`.
- `IosCodegenSwitches.h` keys the disk cache on the variable.

Each WFE returns within microseconds: under it, RenderThread's QPC gaps are 1–10 µs (95 %), not under
1 µs. So iOS's generic-timer event stream (or the cache-line monitor) wakes the core quickly, and no wait
stalls.

## 3. Runs

All on battery (it stopped charging at 80 % before `w3x-*`). Two earlier runs while charging
(`w3-base1`, `w3-prof1`, about 18 fps, budget 404 mW) are not compared.

| Arm | Runs (IPA) | fps (60–150 s) | p10 fps (whole run) | GPU ms | E GHz | CPU mW | RenderThread QPC/s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| YIELD (FEX's) | A2 22.45, A3 22.01, A4 22.48 (`5f7962d6`); Y2 22.36, Y3 22.76, YC1 22.49 (`dd35dc62`) | **22.43** | 21.6 | 28.1 | 1.23 | 276 | 1.8–2.7 M |
| WFE | W1 24.58, W2 24.02, W3 24.48, W4 24.52 (`5f7962d6`); D1 23.63, D2 24.40, D3 24.51, DC1 24.94 (`dd35dc62`) | **24.38** | 23.2 | 29.8 | 1.56 | 316 | 0.21–0.31 M |
| WFE + `MESA_KK_BATCH2=1` | WK3 24.63, WK4 24.24 | 24.44 | 23.3 | 29.7 | 1.62 | 323 | 0.24–0.34 M |
| ISB | I1 22.65, I2 22.78 | 22.72 | 22.2 | 28.5 | 1.23 | 280 | 1.7–2.1 M |
| `MESA_KK_BATCH2=1` alone | K1 22.25, K2 22.69 | 22.47 | 21.6 | 27.9 | 1.25 | 277 | 1.4–2.6 M |

IPAs (dev):
- `5f7962d6ab1f4968c7e326ed0012d1e76603261f636fa9e8a79a4543f291668b` (commit 99b330d, fex 0083 off by default);
- `dd35dc62b84b600e5d79f11aee1635ed3bd692c071c579c9ed59c15f020a14ea` (the compatibility default sets `wfe`).

Notes on the runs:
- **D runs** pass no settings, so they show the compatibility default reaching the game (`FEX: pause mode=1 (wfe)`).
- **Y runs** set `env.MADEIRA_FEX_PAUSE=yield`.
- **YC1 and DC1** run with the disk cache off. They match their arms, so the cache bucket the variable keys does
  not explain the gain.

**Excluded:**
- **A1** stopped at CD PROJEKT's account QR screen: the pad script never reached the save.
- **Y1** (YIELD, `dd35dc62`) gave 22.1–23.2 fps until +85 s and 26.5–27.8 fps after it, in the same view.
  - From +90 s the main thread did about 8 % fewer instructions a frame, and thread `0024` (6–7 % CPU in
    the other runs) dropped out of the top threads.
  - The cause is not known. The game did less work, which no setting changes.
  - With Y1, YIELD's mean is 22.89, and the gain is +6.5 %.
- **Hollow Knight** reaches its first frame with fex 0083 in the IPA (`.work/perf/w3x-hk-smoke`, IPA `5f7962d6`; the
  switch is off for it).

**Counted as CPU.** Under WFE, the threads that wait report more CPU time: RenderDispatcher1/2 went from 25 % to 78 %
each, and total CPU% from 290 to 350. WFE time counts as running, so those threads hold their cores while they
wait. Even so:
- the clamp lets the E cluster run 27 % faster;
- the GPU is busier (83–84 % against 77–79 %).

## 4. GPU levers under WFE (no gain)

Same method, IPA `dd35dc62` (WFE by default), interleaved S, N, D twice, all at the game's saved 1302x600:

| Arm | Runs | fps | GPU ms |
| --- | --- | --- | --- |
| Defaults (WFE) | D1 23.93, D2 24.57 | 24.25 | 29.7 |
| Screen 600 rows (`{"screen":"600"}`, drawable 1302x600) | S1 23.44, S2 24.22 | 23.83 | 30.0 |
| `MESA_KK_EXPERIMENTAL=no_fp_preserve` | N1 23.64, N2 24.59 | 24.12 | 29.9 |

**`no_fp_preserve` moves nothing.** The screen arm compares 1302x600 with 1302x600 (the caveat above), so it
says nothing about resolution: § 7 measures that.

**Where the CPU time goes now.** A `--cpu-prof` run under WFE (`w3y-D2prof`) shows where the threads spend it:
- RenderDispatcher1/2 spend about 21 % of all samples each waiting on D3D12 fences (WFE time counts as samples);
- their own command recording is 6–9 % each;
- the main thread is 12 %.

With the GPU 83 % busy at about 30 ms of a 41 ms frame, the frame is now mostly the throttled GPU's.

## 5. A capture of the frame

`pp gpu capture --frame 3600` (`.work/perf/w3-capture`, 3.5 GB, IPA `dd35dc62`) shows the frame's shape:
- 20 command buffers, 200 passes and 1,822 draws.
- In the main 1300x600 pass, about 40 render passes of one draw each are split by 15 KB buffer copies.
  `CopyBufferRegion` ends the Vulkan rendering, so each split stores and reloads colour and depth.
- The copies cycle through an 8-slot ring.

Filed as PLA-456, which has research on what could merge them. The pass costs need a Mac replay (PLA-457).

## 6. Hitches: WFE trades them for frame rate

Frame intervals from `hitches.txt`, +60 to +150 s. The hot runs are back to back with no rest
(`w3h-*`, `w3h6-*`), the arms alternating after one unscored warm-up run, on external power at 80 % (not charging):

| Condition | Arm | Runs | fps | > 100 ms | > 150 ms | p99 ms | max ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Rested, battery, 1302x600 | YIELD | A2–A4, Y2, Y3, YC1 | 22.43 | 17–24 | 1–6 | | |
| | WFE | W1–W4, D1, D3, DC1 | 24.38 | 45–73 | 6–16 | | |
| Hot, 1564x720 | YIELD | w3h-Y1–Y3 | 17.07 | 34–99 | 3–4 | 108–117 | 167–325 |
| | WFE | w3h-D1–D3 | 17.76 | 105–128 | 18–26 | 158–175 | 367–600 |
| Hot, 1302x600 | YIELD | w3h6-Y1, Y2 | 18.78 | 52–149 | 4–8 | 100–117 | 183–450 |
| | WFE | w3h6-D1, D2 | 20.45 | 124–145 | 23–27 | 150–183 | 417–458 |

**What it shows.**
- **WFE multiplies the worst frames.** It gives about five times the frames over 150 ms in every condition, and
  a p99 about 50 ms longer.
- **A likely cause, not confirmed.** A thread waiting in WFE counts as running: RenderDispatcher1/2 go from 25 %
  to 78 % CPU. With the P cores parked, the main thread probably waits for one of the four E cores. A
  thread-placement trace in Instruments (PLA-457) would show it.
- **YIELD's own tail is poor too.** On a hot phone it is still 34–149 frames over 100 ms per 90 s.

## 7. A hot phone and the game's resolution

Hot, back to back, WFE (the default then), IPA `dd35dc62`:

| Resolution | Runs | fps | GPU ms | > 100 ms | > 150 ms |
| --- | --- | --- | --- | --- | --- |
| 1564x720 | w3h-D1–D3 | 17.76 | 44 | 105–128 | 18–26 |
| 1302x600 (`{"screen":"600"}`, then the game keeps it) | w3h-S1–S3, D4 | 20.47 | 32–33 | 109–143 | 9–27 |

- **Resolution is a real lever on a hot phone:** +15 % fps and 12 ms less GPU time a frame.
- **It does not reduce the hitches.** So the long frames are not the GPU's.
- **Not ordered.** The 1302x600 runs came after the 1564x720 ones, not interleaved; the phone was already hot for
  both.

## 8. What this does not show

- **Other places.** It was measured only in the Kaer Morhen bedroom, about 150 s a run, with no fights and no
  outdoor scenes.
- **Other titles.** Every other title keeps YIELD. RDR2, Hollow Knight and the DXMT titles are not measured
  with WFE.
- **ISB.** It does not help: it keeps the core awake.
- **Hitches by eye.** The interval counts are the app's present intervals; nobody judged the stutter in play.
- **Graphics memory.** The owner's earlier play ended at +128 s with vkd3d-proton
  `Committed resource failed` (E_OUTOFMEMORY) and the game's own fatal exit (`.work/agent-notes/pla-452/owner-log2`).
  None of these stationary runs hit it. `patches/mesa` 0127 logs its cause the next time.
- **Not checked:** input latency, and a person's play.

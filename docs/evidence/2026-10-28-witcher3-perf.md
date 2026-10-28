# The Witcher 3 4.x: PAUSE as WFE gives about 9 % more frames once the phone is warm (PLA-455)

**Linear:** [PLA-455](https://linear.app/playportdev/issue/PLA-455) (this work);
[PLA-43](https://linear.app/playportdev/issue/PLA-43) (the title); [PLA-452](https://linear.app/playportdev/issue/PLA-452)
(the short reservations that let the 4.x build reach gameplay).
**Question:** what limits The Witcher 3's 4.x build (D3D12 through vkd3d-proton and KosmicKrisp) in sustained
play, and what can Playport change to raise its frame rate?
**Result:** after about 55 s of play the SoC's power clamp parks the P cores, and the game runs on E cores at
1.2–1.3 GHz. The busiest thread spins: it waits for work with `pause` and QueryPerformanceCounter. `patches/fex`
0083 adds `MADEIRA_FEX_PAUSE=wfe`, which compiles x86 PAUSE to WFE rather than YIELD. With it the steady frame rate
rises from **22.4 to 24.4 fps (+8.7 %)**, and the whole run's p10 from 21.6 to 23.2 fps. It comes with a higher E-core
clock: 1.23 → 1.56 GHz. It is now The Witcher 3's compatibility default (decision
[0162](../decisions/0162-the-witcher-3-pause-as-wfe.md)).

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

## 4. What this does not show

- **Other places.** It was measured only in the Kaer Morhen bedroom, about 150 s a run, with no fights and no
  outdoor scenes.
- **Other titles.** Every other title keeps YIELD. RDR2, Hollow Knight and the DXMT titles are not measured
  with WFE.
- **ISB.** It does not help: it keeps the core awake.
- **Graphics memory.** The owner's earlier play ended at +128 s with vkd3d-proton
  `Committed resource failed` (E_OUTOFMEMORY) and the game's own fatal exit (`.work/agent-notes/pla-452/owner-log2`).
  None of these stationary runs hit it. `patches/mesa` 0127 logs its cause the next time.
- **Not checked:** input latency, and a person's play.

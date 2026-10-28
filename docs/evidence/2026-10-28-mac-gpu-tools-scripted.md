# Apple's GPU tools scripted from `pp gpu` on the Mac; The Witcher 3's frame profiled with every counter (PLA-458)

**Linear:** [PLA-458](https://linear.app/playportdev/issue/PLA-458) (this work);
[PLA-457](https://linear.app/playportdev/issue/PLA-457) (the Mac session);
[PLA-455](https://linear.app/playportdev/issue/PLA-455) (The Witcher 3's frame rate).
**Question:** can capture, replay, profiling and Instruments run from the Mac with no manual Xcode
step, and what limits The Witcher 3's (app-292030) GPU frame per pass?
**Result:**
- **Yes, all four.** `pp gpu live --capture … --profile` captured a running frame (gpucapture),
  replayed and profiled it on the phone (gpudebug), and read it back into a table. `pp gpu live --trace`
  recorded a Metal System Trace (xctrace). Xcode ran hidden, with no window or click
  ([decision 0165](../decisions/0165-pp-drives-apples-gpu-tools-on-a-mac.md)).
- **Why the capture button was grey:** Metal's capture layer loads only from the **launch**
  environment (`MTL_CAPTURE_ENABLED=1`). Settings' GPU capture `setenv()`s the variable in the process,
  which is too late. With `pp ui --capture-layer`, `gpucapture list` shows `S1Probe`.
- **Full counters, all encoders:** a serial replay timed all 215 encoders, 29.6 ms of GPU work. An
  overlapping replay left the 161 encoders of the main command buffer untimed.
- **One dispatch is 23 % of the frame and is limited by compute shader launch.** Encoder `asc60`
  (cb16/ce6) is one `dispatchThreads` 1312x608 at 16x16, 6.70 ms, with the compute shader launch
  limiter at **98.9 %**, 24 % occupancy and ALU 35 %: the GPU starts that kernel's threadgroups no
  faster. It is the first session's "pass 55", the tiled deferred lighting (7.9 ms then, in Lite mode).
- **The shadow map is vertex-launch bound.** `asc48` (cb11/re24), 2048x2048 Depth16, 732 draws:
  3.17 ms (10.7 %), vertex shader launch limiter 51 %, occupancy 8 %.

Results from Apple's tools cannot be rerun on the workstation (decision
[0031](../decisions/0031-a-mac-for-analysis-only.md)).

## Setup

- **Mac:** Apple silicon, macOS 27.2, Xcode 27.1 (`gpucapture`, `gpudebug` in `/usr/bin`).
- **Phone:** iPhone Air (iPhone18,4), iOS 27.0.1, cabled, Developer Mode on.
- **IPA:** the installed dev build (`dev.playport.app`, version 0.4.0). Its sha256 is not recorded:
  the Mac's `.work` has no install record, so the runs used `--any-build`, as in
  [2026-10-28-mac-tools-and-w3-frame](2026-10-28-mac-tools-and-w3-frame.md).
- **Game:** Kaer Morhen save, swap chain 1564x720 (`[kk-wsi] create chain`). The pads
  `witcher3-continue` (now with two A presses that dismiss the "Welcome to the tutorial" panel) and
  `witcher3-walk` at first frame +60.

## Commands

```sh
./pp gpu live --any-build --title app-292030 --secs 110 \
  --pad first-frame+10:witcher3-continue --pad first-frame+60:witcher3-walk \
  --capture first-frame+85 --profile                       # run live3 (then overlapping)
./pp gpu profile live3/serial.gputrace --exec serial         # the same frame, serial (APFS clone)
./pp gpu live --any-build --title app-292030 --secs 100 ... \
  --trace 'Metal System Trace' --trace-at first-frame+70 --trace-secs 15   # run mst1
```

## What failed on the way

| Try | Result | Now |
| --- | --- | --- |
| `pymobiledevice3 dvt launch --env MTL_CAPTURE_ENABLED=1` with Settings' capture off | `gpucapture list` shows S1Probe | `pp ui --capture-layer` |
| `gpucapture start` on W3 | `error: Capturing Metal 4 Counter Heap is not supported` | `live` arms Settings' GPU capture at frame 999999: KosmicKrisp then makes no counter heap (`patches/mesa` 0044) |
| `gpucapture start` recording every resource | downloaded about 10 GB of GPU data, then `process crashed or disconnected`, and the game exited | `-du` (only the resources the frame uses) by default: 4.1 GB in 72 s, the game kept running |
| `profile run --embed`, then reading in the same session | tables empty | read back in a fresh `gpudebug --oneshot` session |
| `profile run` (overlapping) | 55 of 217 encoders timed, 12.8 ms; cb16's 161 encoders each report the whole frame | `--exec serial` (default): 215 timed, span 32.6 ms, busy 29.6 ms |

## The frame (serial profile, run `live3/serial`)

Whole frame (gpudebug's averages): occupancy 32 %, ALU 21 %, F32 18 %, F16 0 %, instruction throughput
37 %, compute shader launch 29 %, LLC 16 %, bandwidth 19.5 GB/s (17 % of peak). Compute encoders are
11.5 ms of the 29.6 ms.

| Encoder | Where | ms | % | Top limiters | Occupancy |
| --- | --- | ---: | ---: | --- | ---: |
| asc60 | cb16/ce6, 1312x608 dispatch, 16x16 groups | 6.70 | 22.6 | compute launch 99, instruction 66, control flow 60 | 24 |
| asc48 | cb11/re24, shadow map 2048² D16, 732 draws | 3.17 | 10.7 | vertex launch 51, instruction 20 | 8 |
| asc40 | compute | 1.19 | 4.0 | instruction 69, compute launch 62 | 36 |
| asc36 | render | 1.00 | 3.4 | instruction 38, F32 25 | 24 |
| asc28 | render | 0.89 | 3.0 | instruction 44, F32 41 | 42 |
| asc21 | render | 0.88 | 3.0 | vertex launch 33 | 9 |
| asc82 | compute | 0.87 | 3.0 | compute launch 77, instruction 69 | 50 |

**Not answered:** why asc60's threadgroups launch slowly. The candidates are its threadgroup memory
and registers (KosmicKrisp's translation: 10k lines of MSL, 64-bit `no_crash` loop guards), which limit
the threadgroups resident per core. The profile's shader cost ranking is empty, so this needs the
pipeline's compiler statistics or an MSL experiment. Bandwidth is not the limit anywhere in the top ten.

## Raw data

Under `$PLAYPORT_BUILD/mac/auto/`: `live3/` (the capture, `profile.txt`, `profile.json`, `profile/`,
`serial/` with the serial profile), `mst1/` (`metal-system-trace.trace`, 344 MB, and its TOC), and
the failed run `live2`.

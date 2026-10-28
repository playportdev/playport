# A Mac's tools on the phone; The Witcher 3's frame 3600 replayed and timed (PLA-457)

**Linear:** [PLA-457](https://linear.app/playportdev/issue/PLA-457) (the Mac session);
[PLA-456](https://linear.app/playportdev/issue/PLA-456) (the copy splits);
[PLA-455](https://linear.app/playportdev/issue/PLA-455) (the frame rate).
**Question:** what can Apple's tools on a borrowed Mac reach on the phone (agenda item 0 of
[GPU-DEBUGGING.md](../GPU-DEBUGGING.md#on-a-mac)), and where do the ~28 ms of GPU time in The Witcher 3's
Kaer Morhen frame go, in particular PLA-456's copy-split passes (items 3 and 4 of PLA-457)?
**Result:**
- **Recording works system-wide, attaching does not.** `xctrace record --all-processes` records Time
  Profiler and Metal System Trace with Playport's threads and GPU work; `xctrace --attach` cannot find the
  process. Xcode's Attach to Process attaches (it stops the app until Continue), but its GPU capture stays
  unavailable: setting `MTL_CAPTURE_ENABLED` inside the app is not enough for Xcode.
- **Replay and profiling work on the phone.** Xcode replays a `pp gpu capture` trace on the phone and
  profiles it, in *Lite* mode only (the frame is too large for full counters): per-encoder GPU times, no
  limiters. `gpudebug` reads the exported profile on the Mac.
- **The copy splits are 4 % of the frame.** Passes 118–194 (39 one-draw passes and 38 copy encoders) take
  1.1 ms of 26.9 ms of GPU work. Hoisting the copies (PLA-456) can save at most about 1 ms.
- **One compute dispatch is 29 % of the frame.** Pass 55, a full-screen 1312x608 dispatch with the shape
  of tiled deferred lighting, takes 7.9 ms.

Results from Apple's tools cannot be rerun on the workstation (decision
[0031](../decisions/0031-a-mac-for-analysis-only.md)).

## Setup

- **Mac:** Apple silicon, macOS 27.2, Xcode 27.1; `gpucapture`, `gpudebug`, `metalperftrace` present.
- **Phone:** iPhone Air (iPhone18,4), iOS 27.0.1, cabled; Developer Mode on; Xcode's developer disk
  image mounted (`devicectl device info ddiServices`: `isUsable: true`).
- **Installed IPA (item 0):** presumed `94917fa7ac4128e51f08fd89e47d525b1fa196f797929f1ea1ad625a5a3edfc0`
  (dev, built at `e3423b3`; the Mac checkout has no install record, so `pp ui --any-build`).
- **The capture (items 3, 4):** `.work/perf/w3-capture/kk-frame3600-1793164852.gputrace`, taken on
  2026-10-28 by `pp gpu capture --frame 3600 --title app-292030` with the `witcher3-continue` and
  `witcher3-walk` pads, IPA `dd35dc62b84b600e5d79f11aee1635ed3bd692c071c579c9ed59c15f020a14ea`. It renders
  at **1300x600** (the game's saved resolution then, see
  [2026-10-28-witcher3-perf.md](2026-10-28-witcher3-perf.md)), presented at 1564x720.
- **`pp` on the Mac** (decision [0164](../decisions/0164-pp-ui-from-the-mac.md)): `pymobiledevice3` through
  pipx, `PLAYPORT_USBMUX_SOCKET=/var/run/usbmuxd` in `.work/inputs.local`. Two `tools/phonelib.py` fixes
  were needed: macOS's usbmuxd lists a cabled phone twice (USB and network), and pipx's launcher under
  `Application Support` is a `/bin/sh` trampoline, not a `#!python` line.

## 0. What reaches the process

Hollow Knight (`app-367520`) played with `pp ui --play … --until first-frame+10 --leave-running`, then:

| Tool | Result |
| --- | --- |
| `xctrace record --device "<name>"` | "Waiting for device to boot", times out: `--device` wants the identifier; use `--device-name` |
| `xctrace record --template 'Time Profiler' --device-name … --attach S1Probe` (or its pid) | "Cannot find process", although `devicectl device info processes` lists it |
| `xctrace record --template 'Time Profiler' --all-processes --time-limit 10s` | Works: S1Probe 9,953 of ~14k samples, threads named (`UnityGfxDeviceWorker`, `dxvk-cs`, `dxvk-submit`) |
| `xctrace record --template 'Metal System Trace' --all-processes --time-limit 10s` | Works, 145 MB: 37,765 GPU intervals of S1Probe, GPU counters, display, driver; the app-side tables (`metal-application-*`) one row each; no thread-state table |
| Xcode › Debug › Attach to Process › S1Probe | Lists it and attaches; the app **stops** until Continue (the game's log stalled 2 min). Running, the gauges are CPU, Memory, Energy, Disk, Network: no GPU/FPS gauge, Capture GPU Workload greyed out |
| `gpucapture list` | "no capturable processes", with or without Xcode attached, with GPU capture armed |
| `gpudebug --list-devices` | Only the Mac, until Xcode has a capture replaying on the phone; then the phone too |

GPU capture was armed for the attach test with `set:gpuCaptureFrame=999999` (a frame never reached), the
log then saying `gpu capture: frame 999999 of hollow_knight on vulkan … Metal allows a trace document`.

**Answered:** the debugger attaches but takes the process stopped; Instruments records the phone only
system-wide (`--all-processes`), not attached; Settings' GPU capture does not enable Xcode's capture button
or `gpucapture` in an attached process. Per-thread run states (needed for PLA-457 item 1's starvation
question) were not checked: Metal System Trace has no thread-state table; the System Trace template is
untried.

**`set:` then relaunch loses the value.** A `pp ui --action set:gpuCaptureFrame=…` run reported `ok`, but
the next launch read 0: the driver kills the app about 3 s after the action, before the default reached
disk. With `--action wait:5` after the `set:` the value held.

## 3. The copy splits (PLA-456)

The capture opened in Xcode replays on the phone (Summary: Apple A19 Pro GPU, iOS 27.0.1; 20 command
buffers, 118 render and 82 compute encoders, 1,749 draws, 73 dispatches). Performance profiled it in Lite mode
("the Metal workload exceeds the maximum size supported for full profiling information"; performance state
medium, overlapping): **effective GPU time 28.20 ms**, 200 encoders, 166 pipeline states. Xcode's export put
the profile in the bundle (`*.gputrace.gpuprofiler_raw`); `gpudebug --oneshot … -c "profile load" -c "go
/performance/timeline/encoders" -c "list --all"` lists each encoder's start, end and duration. Its `ascN`
is `capture.txt`'s pass N. The Counters export is empty in Lite mode.

- **Serial.** The union of the encoders' intervals is 26.87 ms, equal to the sum of their durations:
  nothing overlaps. Three empty encoders (passes 14, 33, 196) report the whole 0–28.2 ms span and are left out.
- **Per command buffer:** cb 17 (passes 49–197) 16.72 ms, cb 12 (shadows and the first scene passes) 6.79 ms,
  cb 10 (1024x1024 depth) 2.85 ms; the rest under 0.4 ms.

| Passes 118–194 | n | Sum | Each |
| --- | ---: | ---: | --- |
| render, 1300x600 RGBA8 + D32FS8 load/store, one draw | 39 | 482 µs | median 10.2 µs, 25th pct 9.7, max 55 (pass 118, a colour clear) |
| compute, the 15 KB copies | 38 | 134 µs | median 3.1 µs |
| gaps between them | | 488 µs | ~6 µs per encoder switch |
| **span** | | **1,105 µs** | **4.1 % of the frame's GPU time, 6.6 % of cb 17** |

**Answer:** the attachment load/store of the splits is at most about 0.4 ms (39 passes at the ~10 µs
floor); with the copies and the switches the whole stretch is 1.1 ms. PLA-456's hoisting (39 boundaries
down to about 6) would save under 1 ms of ~27–28 ms, about 3 %. On a TBDR GPU at 1300x600 a load/store pass
costs ~10 µs, not the full-surface reload the PLA-456 estimate feared.

## 4. Where the rest goes (partial)

Largest passes (µs): **55 compute 7,883**; 41 render 2048x2048 D16 (604 draws, the shadow map) 2,294; 34
compute 1,036; 18 compute 1,028; 50 render 897; 17 render 822; 23 render 796 (the 1300x600 scene, 218
draws); then nine passes of 400–700.

**Pass 55** (Xcode: cb16/ce6, "MTL4ComputeCommandEncoder 27"): one `dispatchThreads` of 1312x608x1 at
16x16x1, pipeline `cps8`, three buffers, MSL of 10,108 lines (KosmicKrisp's translation; fetched to
`.work/mac/item3/cs-pass55.metal`). Its structure is tiled deferred lighting:
- per-tile depth min/max with threadgroup `atomic_fetch_min/max`;
- light culling into threadgroup lists with `atomic_fetch_add`;
- per-pixel loops, with 15 `sample` and 10 `read` calls.

Each loop carries KosmicKrisp's `for (uint64_t no_crash …)` guard.

**Not answered:** its limiter (ALU, bandwidth, occupancy, the 64-bit loop counters) and whether resolution
matters. Lite mode has no counters. Full profiling needs a smaller workload, e.g. a capture of cb 17 alone or
a replay restricted to that dispatch.

## Raw data

- Under `$PLAYPORT_BUILD/mac/`: item 0's traces (`item0-hk-tp-all.trace`, `item0-hk-mst.trace`) and the
  `pp ui` runs.
- `item3/`: the profiled capture, `timeline.json` (pass, label, start, end, duration in ns),
  `analysis1.txt`, `analysis2.txt` and the shader.

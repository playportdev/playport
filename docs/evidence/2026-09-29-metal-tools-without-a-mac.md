# Apple's Metal tools with only a Linux workstation and the phone

**Date:** 2026-09-29. **Question:** which of Apple's Metal debugging and
profiling tools, including the command-line tools for agents
(`gpucapture`, `gpudebug`, `metalperftrace`), can this project use when it has
no Mac. **Result:**

- The three command-line tools, Xcode, Instruments and the Game Porting
  Toolkit's agent skills need macOS 27 on Apple silicon. None of them runs here.
- The phone's own look-back performance trace (Developer settings, Performance
  Trace, Lookback Collection) fails on iOS 27.0 before it writes a file.
- **A Metal frame capture works without a Mac.** Settings' Diagnostics has
  DXMT capture frame N as a `.gputrace` on the phone. `pp phone pull` fetches
  it, and `tools/gputrace.py` reads it here: every call by name, each pass's
  targets, pipelines and draws, and Apple's compiler statistics for every
  shader. It has no timings, because nothing here replays a capture.
- GPU time per pass comes from the runtime's own timestamps: Diagnostics' GPU
  time per pass, which `pp perf --pass-prof` tables. Together with the capture,
  it covers most of what the Metal debugger's frame view gives.

Phone iPhone18,4 (A19 Pro), iOS 27.0 (24A437). Dev IPAs
`Playport-26.5-2af2841a.ipa` (sha256
`2af2841a948ef12365c69b784ab1b680907492f840106374753c4f55c9f79578`, the first
capture) and `Playport-26.5-a82400a7.ipa` (sha256
`a82400a7dd1e0400f4b9b66ae637c401c1f4160444686c8e10ba88539465807d`, the
gameplay run).

## What was tried

| Tool | Result here |
| --- | --- |
| `gpucapture`, `gpudebug`, `metalperftrace`, Xcode, Instruments | macOS 27 only (Apple's tools page; the Game Porting Toolkit's prerequisites). Not available |
| Look-back performance trace | Enabled on the phone, then the Control Center button pressed after a play, three times. Each time the collector (`ptpassivecollectiond`) failed within 3 s: `PerformanceTraceError Code=2 "Failed to collect any trace files due to unknown error"`, after a sandbox denial of `hw.uuid`. No file was written. Reading one would need `metalperftrace` anyway |
| Instruments services over the tunnel (pymobiledevice3) | The phone serves the full list (`dtservicehub`). `pp perf` already uses graphics and energy. GPU counters (`services.gpu`) answer with profiles 13 and 14 for the A19 Pro, but every `configureCounters` shape tried returned "Selected counter profile is not supported on target device". Kernel tracing (`coreprofilesessiontap`) gave an empty stream. Neither was pursued further |
| Metal frame capture (`MTLCaptureManager` in DXMT) | Works: below |

## Frame capture

- **Setting:** Settings, Diagnostics, GPU capture: `Diagnostics.swift`, dev
  builds only.
- **Environment:** Metal allows a trace document only in a process that
  starts with `MTL_CAPTURE_ENABLED=1`. The setting therefore takes effect from
  Playport's next start. The launch then passes `MTL_CAPTURE_ENABLED`,
  `DXMT_CAPTURE_EXECUTABLE` (the exe without `.exe`) and `DXMT_CAPTURE_FRAME`
  to the game, as DXMT's `dxmt_capture.cpp` and `dxmt_command_queue.cpp`
  require.
- **Output:** DXMT writes `<exe>_F.<N>_<time>.gputrace` into the game's
  folder.
- **In a measured run:** `pp perf --gpu-capture N` does all of this, pulls the
  bundle into the run directory and writes `capture.txt`.

| Run | Frame | Bundle | Pull |
| --- | --- | --- | --- |
| `pp ui --play`, first frame +30 s | 600 (title screen) | 694 MB, 253 textures, 21 buffers | 26 s |
| `pp perf --out metal-capture-hk --secs 150 --pad first-frame+35:hk-new-game --pad first-frame+90:hk-walk --pass-prof --gpu-capture 9000` | 9000 (King's Pass) | 443 MB | in the run |

That run's frame figures are not a baseline:
- capturing is on for the whole process;
- the global settings had the 720-row screen (1564×720) and a 60 FPS limit;
- the result was 58.7 FPS mean with 6.16 ms of GPU time.

### Reading a capture without Xcode

`tools/gputrace.py` reads the bundle. Its docstring has the layout, which was
reverse engineered from these captures.

- **Call names:** the capture numbers every call with GPUToolsCapture's
  enumeration. The phone's shared cache carries the names in that order
  (`kDYFE…`, 2026 of them on iOS 27.0).
  - `pymobiledevice3 developer fetch-symbols download DIR` fetches the cache
    (7.5 GB, about 3 minutes).
  - `gputrace.py names DIR` writes `$PLAYPORT_BUILD/cache/gputrace-names.txt`.
  - The table is Apple's and stays out of the repository.
  - It was checked against the calls' own signatures, for example
    `setVertexBuffer:offset:atIndex:` recorded as receiver, object, two
    unsigned longs.
- **Descriptors:** render pass and texture descriptors are in `store0`,
  under the keys the calls carry.
  - Each pass's attachments, load and store actions and size matched the same
    frame's `[pass-prof]` lines exactly.
  - Each pipeline's descriptor names its vertex and fragment functions.
  - A keyed plist holds Apple's compiler statistics for each pipeline:
    instructions, ALU, FP16, registers, spills, texture reads, compile time.
- **`tmc/gputrace`** (a Go tool) opens these bundles but decodes only compute
  work; for this render frame it found two commits.

## What Hollow Knight's King's Pass frame asks of the GPU

Frame 9000 is one command buffer of 28 passes, plus the present:
- 23 render passes;
- 5 blits;
- 97 draws;
- 168 fence waits;
- 57 fence updates.

The same run's `passes.txt` puts its GPU time at about 6.0 ms a frame.

- **Grab-pass copies split the scene.** Four times in the frame a blit copies
  the whole 1564×720 colour target to another texture. This is Unity's
  screen grab for its distortion effects. Each copy ends one render pass and
  starts another.
  - Every pass after a copy loads and stores both colour (RGBA8) and the
    D32FS8 depth-stencil.
  - The copies alone are 0.89 ms a frame (15 % of the GPU time).
  - The full-size passes that load and store colour and depth (about 5.4 a
    frame) are 2.48 ms (41 %).
- **Two clear-only passes:** passes 5 and 25 are DXMT's `ClearPass`. Each
  clears and stores a 1564×720 D32FS8 depth-stencil with no draw.
  - Nothing later in the frame names either texture: no pass, copy or
    `useResource` call.
  - Pass 25 clears the depth that pass 24 has just discarded (`L/x`).
  - Whether the next frame reads them is not in one frame's capture.
- **Shaders:**
  - No spills, and no FP16 instructions in any of the 30 pipelines: DXMT's
    shaders are all 32-bit.
  - The heaviest are the 384-388 instruction vertex shaders `vs_b5d96184_*`
    and the 319-instruction fragment shader `ps_1be85dea_*`.

These are leads for a GPU-time change, not measured causes.

## Pass profile table

`tools/passprof.py` (and `pp perf`, into `passes.txt`) tables the
`[pass-prof]` lines:
- the sampled frames;
- alike passes, grouped by size and attachments, by their GPU time a frame.

A frame's `span` column covers all its command buffers. When the frame's
presents are paced, it includes the time between them, so it can be far
longer than the frame's GPU time.

## Metal validation on the phone

With Settings' Diagnostics, Metal validation on (`pp gpu validate`,
[GPU-DEBUGGING.md](../GPU-DEBUGGING.md#metal-validation)), Metal's validation
layer is active in the app's process (`MTLDebugDevice`). Its findings reach
`s1-host.log`. From a play of Hollow Knight to King's Pass with shader
validation on (dev IPA sha256
`8d094fd8b3e75c0468decfb26ec91bdfe33d4b5bf39e3bdd9446c320e730faad`, 164 s):

- **Shader validation:** 52,970 `INF or NAN detected in interpolant`
  findings, in 8,842 frames, from 12 vertex shaders. Most came from
  `vs_87a79b60_*` (`reg1_0`) and `vs_756ae290_*` (`reg2_0`).
  - A NaN interpolant is either DXMT's translation or the game's own
    shader's.
  - It affects the picture only if the fragment stage uses it.
  - Not yet checked against the Proton reference.
- **API validation:** no error. About 1.8 million performance findings:
  - redundant state setting: stencil reference, blend colour, depth-stencil
    state, fill mode, cull mode, depth clip and bias, pipeline state;
  - vertex and fragment buffers bound but unused. DXMT encodes all of these
    per draw.
- **A capture in the same play was never written**, although DXMT logged the
  start of it. Captures and validation are separate plays.

## What a Mac would add

Per-pass limiters, a hitch timeline and replay between draws, including for
the Vulkan backend. The plan for a borrowed Mac is [GPU-DEBUGGING.md](../GPU-DEBUGGING.md#on-a-mac), and
[decision 0031](../decisions/0031-a-mac-for-analysis-only.md) (proposed)
bounds it.

# GPU debugging

This page covers finding out why a game renders wrong or renders slowly on the
phone, from this Linux workstation and, for what only Apple's tools do, a
borrowed Mac.

A step that needs the person, such as a
reference capture on this PC or a Mac session, is announced with its steps
before it is needed.

- **On the phone:** the tools read what the phone and the runtime can report.
  Every play still goes through the app's UI (decision 0012), under the
  device lock.
- **Results:** a finding others rely on becomes an evidence note, as in
  [DEVICE.md](DEVICE.md).
- **Findings so far:** [metal-tools-without-a-mac](evidence/2026-09-29-metal-tools-without-a-mac.md).
- **Leads to hunt:** [Hollow Knight's](plans/finished.md#hollow-knight-leads-from-the-first-gpu-captures).

## Which tool answers which question

| Question | Tool | Where |
| --- | --- | --- |
| How fast, how hot, over a play | `pp perf` | [DEVICE.md](DEVICE.md#measuring-a-title) |
| Which passes cost the GPU time (DXMT only) | GPU time per pass: `pp perf --pass-prof`, `pp gpu passes` | [below](#gpu-time-per-pass) |
| What one frame asks of the GPU: passes, targets, load/store, pipelines, draws, shader statistics | GPU capture: `pp gpu capture`, `pp gpu read` | [below](#a-frames-capture) |
| Does the runtime misuse Metal, or does a shader read or write out of bounds or produce NaN | Metal validation: `pp gpu validate` | [below](#metal-validation) |
| What the right picture is (D3D12, D3D11, Vulkan games) | the same game under Proton on this PC, captured with RenderDoc | [below](#the-reference-on-this-pc) |
| Why a pass is slow (bandwidth, ALU, occupancy) | a Mac: Xcode's replay with counters | [On a Mac](#on-a-mac) |
| Where a hitch comes from (compiles, driver, CPU and GPU overlap) | our logs (`hitches.txt`); a Mac: Metal System Trace | [On a Mac](#on-a-mac) |
| Which draw makes the picture wrong | a Mac: replay between draws, the shader debugger | [On a Mac](#on-a-mac) |
| Is a Vulkan game's world stretched by its viewport or its camera, and what display values did it read | a dev build's game Graphics options `MESA_KK_FRAME_PROBE_S=N`: every N s after the first draw, ten times at most, the next 2500 draws' `[kk-draw]` lines and a scan of host-visible memory for view-projection matrices, `[kk-proj] P00 P11 aspect hits` (`patches/mesa` 0063); runtime key `env.MADEIRA_DISPLAY_QUERY_LOG=1`: each distinct answer of the display queries (metrics, monitor, modes, display config, device caps) per process as `[disp-q]` lines and the Vulkan surface extents as `[vk-surf]` (`patches/madeira-unix` 0178, `patches/wine-unix` 0044) | [rdr2-aspect](evidence/2026-10-20-rdr2-aspect.md) |
| What KosmicKrisp's memory is: the game's own, KosmicKrisp's buffers, its Metal command allocators, the shaders' source | a dev build's `[kk-mem]` lines, at most one every 10 s (`MESA_KK_DEBUG=memory`, set with `compile` by `WineHostRuntime.swift`; `patches/mesa` 0046, 0047) | [rdr2-kk-memory](evidence/2026-10-20-rdr2-kk-memory.md) |
| What KosmicKrisp's Metal builds cost and which fail: each step (vertex, fragment library, pipeline), the MSL's source and size, the calling thread | a dev build's `[kk-compile]` lines (`MESA_KK_DEBUG=compile`, on by default): builds over 20 ms and every `FAIL` (`step=`, `err=DOMAIN:CODE`, `interrupted=1` when iOS ended MTLCompilerService); experiments, all off by default, through the game's Graphics options `MESA_KK_EXPERIMENTAL=`: `compile_retry` (an interrupted build again, twice at most, 200 ms apart; `retry` lines), `parallel_stages` (vertex and fragment libraries at once; `par=1`), `library_size_opt` (`MTLLibraryOptimizationLevelSize`) (`patches/mesa` 0052, 0053) | [kk-compile-levers](evidence/2026-10-20-kk-compile-levers.md) |
| Which shaders are behind a slow or failed Metal build, and why they are large | a dev build's game Graphics options `MESA_KK_DUMP_MSL_MIN_KB=N`: each build over N KB of MSL writes its MSL, SPIR-V and specialization into `Library/Caches/kk-dump` (`MSL.STAGE.metal`, `MSL.STAGE.spv`, `MSL.txt`, MSL the `msl=` of `[kk-compile]`; 200 MB cap; `[kk-dump]` lines), pulled with `pp phone ls`/`pp phone pull`; replay captured pipelines on the host mock (`build/mesa-host-test/run-replay.sh`, `KK_MOCK_MSL_DIR`). Costly SPIR-V unroll hints are dropped and twice-interrupted MSL skipped by default (`MESA_KK_DEBUG=unroll_hints`, `no_known_fail` undo them; `patches/mesa` 0060–0062, decision 0139) | [kk-msl-size](evidence/2026-10-20-kk-msl-size.md) |
| Is a Vulkan picture wrong because of a KosmicKrisp workaround that OS version 27 turns off | the game's Graphics options: `MESA_KK_DEBUG=os26_workarounds` (all of them back on), then `MESA_KK_DISABLE_WORKAROUNDS=N` beside it to find which one (`patches/mesa` 0029) | [unity-urp-vulkan](evidence/2026-10-11-unity-urp-vulkan.md), [kk-ios27-workarounds](evidence/2026-10-11-kk-ios27-workarounds.md) |

## Diagnostics in Settings

Settings › Developer (dev builds, `app/Sources/S1Probe/Dev/Diagnostics.swift`,
`DeveloperSettings.swift`) holds each switch (`open:settings#developer`); a person sets them there, the workstation through
the same keys:

| Switch | Key | What it does | Takes effect |
| --- | --- | --- | --- |
| GPU capture | `gpuCaptureFrame` (a frame, 0 off) | DXMT or, on Vulkan, KosmicKrisp writes that frame as a Metal `.gputrace` into the game's folder | Playport's next start: Metal allows captures only in a process that starts with `MTL_CAPTURE_ENABLED=1` |
| GPU time per pass | `passProfile` | winemetal times every encoder of two frames in every 1200 presents (`[pass-prof]` lines; `patches/dxmt` 0008) | the next game |
| CPU sampling | `cpuProfile` | the busiest threads sampled at about 1 kHz, 3 s in every 15 s (`[wprof]` lines; `patches/madeira-unix` 0028) | the next game |
| Metal validation | `metalValidation` (`api`, `shaders`, `stop`) | Metal's API validation layer; with `shaders` also shader validation; with `stop` the process ends at the first API error | Playport's next start |

Notes:
- **What a run touches:** `pp gpu` and `pp perf` set these keys in a launch
  of their own, then play in the next.
  - Like every driven setting, they last for that one hold of the device lock
    and are undone at the app's next launch outside it.
  - GPU capture and validation cost every frame: such a run's frame figures
    are not a measurement.
- **The Vulkan backend:** KosmicKrisp's single-frame trigger
  (`MESA_KK_GPU_CAPTURE_FRAME`, `patches/mesa` 0017) uses the same capture
  setting and Linux pull/read tools as DXMT; no Mac is needed to collect it.
  Metal validation works on both backends: API findings reach stderr, but
  shader findings through command buffer logs are reported by DXMT only.
  GPU time per pass is also DXMT-only (winemetal's Metal layer).

## On the phone, from Linux

### A frame's capture

```sh
./pp gpu capture --frame 600                         # default title: Hollow Knight
./pp gpu capture --frame 600 --settings '{"graphics":"vulkan"}'
./pp gpu read BUNDLE [--calls | --json]
```

- **The run:**
  1. `capture` sets GPU capture at frame N in one launch, then plays in the
     next until first frame + `--secs` (default N/50 + 20).
  2. It pulls the bundle into the run directory
     (`$PLAYPORT_BUILD/gpu-runs/<time>`).
  3. It deletes the bundle on the phone (the capture is written into the game's
     folder) once the phone's tree has the files, bytes and links of the pulled
     copy (`afc.py rm-bundle`, a `Documents/…/NAME.gputrace` only); the `bundle`
     event says so, with the free space after. A bundle left there fails the run.
  4. It writes `capture.txt`, plus `passes.txt` with `--pass-prof`.
- **Space:** before the play the phone must have `--expect-gb` (default 1)
  free above a 3.5 GB reserve, or the run is refused (the `space` event).
- **Timestamp queries:** Metal refuses to capture a device with a counter heap, so while a
  KosmicKrisp capture is armed a timestamp query pool makes none and its timestamps all read
  `0xffffffff00000000` (`patches/mesa` 0044, `[kk-query]` lines). GPU timings a game measures with
  them are 0 in such a play.
- **Recorded phone evidence:** a DXMT title-screen capture (frame 1200)
  returned its report and pass table (2026-09-29); frame 600 captures on
  [both backends](evidence/2026-10-06-vulkan-perf-tooling.md#03-gpu-capture-on-kosmickrisp)
  returned readable bundles (2026-10-06).
- **Frame numbers:** N counts presents from the game's first, not elapsed
  time. Use `--secs` and `--pad` for a checked route to the intended scene
  ([DEVICE.md](DEVICE.md#measuring-a-title)); do not infer gameplay from N alone.
  The October 6 menu bundles were about 700–800 MB.
- **Call names:** `pp gpu read` needs them, from the phone's shared cache:
  `./pp gpu names --fetch` downloads it (7.5 GB, about 3 minutes, once per
  iOS version) into `$PLAYPORT_BUILD/cache` and builds the table. The table
  is Apple's and stays there.
- **What `read` gives:**
  - each pass's command buffer, size, colour and depth targets with their
    formats and load/store actions, draws and elements, `useResource` calls
    and fence waits;
  - DXMT pipeline shaders with Apple's compiler statistics: instructions,
    ALU, FP16, registers, spills, texture reads, compile time;
    Metal 4 (KosmicKrisp) pipeline statistics are not yet resolved by the reader;
  - `--calls` lists every call by name.
- **What it cannot give:**
  - timings: nothing here replays a capture;
  - resource contents after a draw: the bundle holds each resource as it was
    when the frame began (`MTLTexture-*`, `MTLBuffer-*`), which is enough to
    check a frame's inputs.
- **Format:** the bundle layout, reverse engineered from iOS 27.0 captures,
  is in `tools/gputrace.py`'s docstring.

### GPU time per pass

```sh
./pp perf --pass-prof ...        # passes.txt with the run's other figures
./pp gpu passes RUN_DIR          # the table of any run with the switch on
```

- **DXMT only:** the table lists the sampled frames (passes, draws, vertex
  and fragment time, span), then alike passes grouped by size and attachments,
  ranked by GPU time a frame. `--pass-prof` does not time Vulkan passes.
- A pass's cost is vertex plus fragment time; the two overlap on the GPU.
- A frame's span covers all its command buffers, so it includes paced gaps.
- Timestamps are Metal's stage-boundary counters. On this phone they are in
  nanoseconds, while `sampleTimestamps` returns mach ticks
  ([hk-gpu-passes](evidence/2026-09-26-hk-gpu-passes.md)).

### Metal validation

```sh
./pp gpu validate [--secs S] [--pad ...]              # API validation
./pp gpu validate --shaders ...                       # and shader validation
./pp gpu validate --stop ...                          # end at the first API error, quote it
```

- **Proof it is on:** the log shows `diagnostics: Metal validation (…);
  device class MTLDebugDevice`.
- **Where the findings arrive:** in the play's `s1-host.log`, from two
  sources. `validation.txt` groups them by message.
  - **The API layer** writes each finding with NSLog to stderr, as
    `<Check> Validation` and then the message.
    - `OS_ACTIVITY_DT_MODE` must stay unset: it sends NSLog to the device
      log, where the phone redacts the text.
    - Metal's errors also go to the device log as `<private>`;
      `validation.txt` counts those lines.
  - **Shader validation** reports through the command buffer's logs, which
    DXMT writes out: `err: Frame N: …`, then the vertex or fragment function
    and the call. `validation.txt` names the function each came from.
- **`--stop`** ends the process at the first API error. `validation.txt`
  quotes the message from the crash report.
- **Findings in Hollow Knight** (2026-09-29, 164 s from the title screen to
  King's Pass):
  - **Shader validation:** 52,970 `INF or NAN detected in interpolant`
    findings, in 8,842 frames, from 12 vertex shaders. The largest are
    `vs_87a79b60_*` (`reg1_0`, 19,705) and `vs_756ae290_*` (`reg2_0`, 11,475).
  - **The API layer** raised no error, only performance findings, in about
    1.8 million messages:
    - redundant state: `setStencilReferenceValue` 394,539 times,
      `setBlendColor` 119,068, `setDepthStencilState` 95,361;
    - vertex and fragment buffers bound but unused by the pipeline.
    - These are CPU work DXMT could skip.
  - **Frame rate:** GPU time rose from about 6 ms to 15 ms a frame with
    shader validation on.
- **Validation and capture do not mix:** in the same play, the capture was
  never written. `pp gpu capture` therefore takes no validation; run them in
  separate plays.

### The reference on this PC

- **Why:** for a game that renders wrong on the phone, the right picture comes
  from the same game at the same spot under Proton on this PC. It runs the
  same translation layers the phone does: DXVK for D3D8 to D3D11,
  vkd3d-proton for D3D12. Captured with RenderDoc, which is installed
  (`qrenderdoc`, `renderdoccmd`), it shows every draw's inputs and outputs.
- **On the phone:** i386 titles and detected or requested D3D12 default to
  Vulkan; other titles default to DXMT. Explicit game/global graphics choices
  take precedence (`LaunchSettings.resolve`). DXMT runs D3D10/11 on Metal,
  not DXVK: a Proton capture is then a reference picture, not the same translation.
- **Before a reference is needed, tell the person these steps.** They need
  the person at this PC and Steam's UI:
  1. The game installed in Steam on this PC, the Windows build (Hollow Knight
     is), with the phone's save copied over if the spot needs one.
  2. Proton Experimental (closest to the pinned DXVK and vkd3d-proton, which
     follow their `master`). Its version goes in the evidence note.
  3. The game's launch options: `ENABLE_VULKAN_RENDERDOC_CAPTURE=1 %command%`.
     For the phone's settings, add the game's own arguments, such as
     `-screen-width 1564 -screen-height 720` for Unity. The Vulkan layer is
     RenderDoc's.
  4. In `qrenderdoc`, set Tools, Settings, capture directory to
     `$PLAYPORT_BUILD/gpu-reference/<game>/`, never `/tmp` (a small tmpfs).
  5. Play to the spot, then capture with F12, or with File, Attach to Running
     Instance, then Capture.
  6. Remove the launch option afterwards.
- **Comparing:** open the capture in `qrenderdoc`. In the event browser, find
  the pass that corresponds to the phone's (`pp gpu read` lists the phone's
  passes by size and targets) and compare its outputs with what the phone's
  frame shows. Finding the first wrong draw on the phone needs a Mac
  ([below](#on-a-mac)).
- **Status:** these steps are untested here. The first use records what
  worked in this section.

## On a Mac

**Status:** plan; nothing here has been tried on a Mac.
[Decision 0031](decisions/0031-a-mac-for-analysis-only.md) (proposed) bounds
it and must be accepted first. When the person says "we are on a Mac", start
with [Arrival checks](#arrival-checks). Then offer the [agenda](#agenda) in
order, skipping what [Open questions](#open-questions) already answers.

### What only a Mac adds

- **Per-pass and per-draw limiters:** Xcode's replay with performance
  counters, performance heatmaps and the shader cost graph (the A19 Pro
  qualifies). The phone's GPU counter service rejected every configuration
  tried from Linux.
- **A hitch timeline:** Instruments' Metal System Trace, with CPU, GPU,
  driver and compiler on one timeline.
- **Replay between draws:** any texture or buffer after any draw, the shader
  debugger, the dependency viewer.
- **Validation messages** unredacted, at the call.

Apple's command-line tools need macOS 27:
- `gpucapture`, `gpudebug` and `metalperftrace`;
- their man pages (`man gpudebug | col -b`) are the reference;
- the Game Porting Toolkit's agent skills describe driving them
  (`using-gpucapture`, `using-gpudebug`, `using-metal-validation` in
  `apple/game-porting-toolkit`);
- drive `gpudebug` non-interactively with `-q`, browsing before `fetch`.

### Prepare on Linux first

1. Validation findings from `pp gpu validate --shaders` for the titles in
   question, each already with the function it came from: the Mac session
   then only has to explain them. Hollow Knight's NaN interpolants are one
   such lead.
2. A reference capture per rendering bug ([above](#the-reference-on-this-pc)).
3. The questions written down: title, save, route (a `tools/pad/` script),
   settings and frame.
4. Fresh captures, taken the day before (`pp gpu capture`).
5. About 1 GB per capture and 1 to 5 GB per Instruments trace. The phone
   charged and on its known-good iOS
   ([DEVICE.md](DEVICE.md#known-good-ios-versions)); the Mac must not update
   it.

### Arrival checks

- **The Mac:** Apple silicon, macOS 27, Xcode 27 (`xcodebuild -version`;
  `which gpucapture gpudebug metalperftrace`).
- **The phone:** cabled and trusted (`xcrun devicectl list devices`).
  Xcode may mount its own developer disk image; the phone stays on its iOS.
- **Playport:** the build `pp phone status` reports on Linux. The phone keeps
  its network connection to the workstation, so `pp ui` can still drive Play
  (untested with a cable to the Mac); otherwise the person taps Play.
- **Never Run, Install, Profile-from-scheme or Uninstall Playport from
  Xcode.** They replace the app or delete its container: the Wine prefix,
  the Steam session and the games. Only attach, record and replay; launches
  stay the app's Play button.
- **No secrets leave the Mac.** No UDID, team ID or pairing file goes into
  the repository or the evidence. Copy results to the workstation and run
  `pp secrets`.

### Agenda

**0. Can the Mac's tools reach our process? (10 minutes, first)** The JIT
helper takes its debugger turn at every launch.
1. With Hollow Knight at its first frame, attach Time Profiler for 10 s:
   `xcrun xctrace record --template 'Time Profiler' --device <phone> --attach
   <process> --time-limit 10s --output hk-tp.trace`. The process is the
   game's (`hollow_knight`) or Playport's executable (`S1Probe`): the game
   runs inside it.
2. Then try Xcode's Debug, Attach to Process with GPU capture on. If Xcode
   cannot attach, try `gpucapture`.
3. If nothing attaches, items 1 and 3 fall back to replaying captures taken
   with `pp gpu capture`.

**1. Hollow Knight's first-use hitches (performance).**
- **Record:** Metal System Trace of the launch through the first minute of
  play, with the `hk-new-game` and `hk-walk` pads:
  `xcrun xctrace record --template 'Metal System Trace' --device <phone>
  --attach <process> --time-limit 90s --output hk-mst.trace`. Try the Game
  Performance Overview template too.
- **Read:** `xcrun xctrace export --input hk-mst.trace --toc`, then
  `--xpath`, so an agent can parse it.
- **Questions:**
  - Is each hitch a shader or pipeline compile, and in Apple's compiler or
    DXMT's translation (`[shader-time]`)?
  - Does the GPU idle between command buffers?
  - How does DXMT's encode time compare with GPU time?
- This serves [the performance plan](plans/finished.md#performance-follow-up-after-the-runtime-audit)'s
  first-use-hitch items.

**2. Is King's Pass bandwidth-bound? (performance)** Replay a King's Pass
capture in Xcode with the phone as the replay device (replay needs the GPU
the capture was taken on), or `gpudebug -q -d <phone> <bundle>`, and profile
it. The questions come from
[the evidence](evidence/2026-09-29-metal-tools-without-a-mac.md):
- **The grab-pass copies:** four full-screen copies split the scene, and each
  following pass loads and stores colour and depth.
  - Do those passes show bandwidth limiters?
  - Would one uncut pass save the copies' ~15 % and the reloads?
- **Unused clears:** do the two clear-only depth passes cost anything?
- **Precision:** is any shader limited by 32-bit ALU work that FP16 could
  halve?
- **Resolution:** what share of the frame is resolution-bound (1564×720
  against native)?

Record each pass's time, limiter, bandwidth and occupancy, and compare with
`passes.txt` of the same run, to check our pass timer against Apple's.

**3. Find the draw that goes wrong (correctness, the Vulkan backend and
DXMT).**
1. Start Playport with GPU capture on (any frame: it makes Metal allow
   captures) and play to the bad spot.
2. Capture with Xcode or `gpucapture`.
3. Step the draws until the picture diverges from the Proton reference.
4. At that draw, inspect bindings, textures before and after, and debug the
   shader.

For a Vulkan-backend game, the shader is KosmicKrisp's translation of
vkd3d-proton's or DXVK's SPIR-V, which translates the game's DXBC or DXIL.
Name the layer that is wrong before patching. Validation findings from
Linux say where to look first.

**4. Optional: `metalperftrace`.** The phone's look-back trace fails on
iOS 27.0. If Instruments' Game Performance Overview recorded a play, try
`metalperftrace overview --json` on it.

### What comes back

- **Evidence:** a note per item in `docs/evidence/`, with the IPA's sha256,
  the phone's OS, the commands and each question answered or not.
- **Raw data:** traces and captures stay in `$PLAYPORT_BUILD`.
- **Code:** a fix is a patch in `patches/<target>/`, checked by a Hollow
  Knight play; the Mac only analyses.

### Open questions

Answer these in the session and record the answers here:
- Can Xcode, Instruments or `gpucapture` attach to Playport after the JIT
  helper's turn?
- Can the workstation drive `pp ui` while the phone is cabled to the Mac?
- Does `gpudebug -d` replay on the phone, or only Xcode?
- Does Settings' GPU capture (`MTL_CAPTURE_ENABLED` at start) suffice for
  Xcode's capture button?

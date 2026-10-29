# KosmicKrisp encoder timing from Linux (PLA-466)

**Linear:** [PLA-466](https://linear.app/playportdev/issue/PLA-466).
**Outcome:** Linux `pp perf --pass-prof` now reports KosmicKrisp render/dispatch
elapsed times and cap-aware pipeline limits. Final host/build/phone gates pass.
Copies are explicitly unavailable and totals partial (owner-approved scope,
[PLA-474](https://linear.app/playportdev/issue/PLA-474)); no spill-count or
calibrated match to Apple's profiler is claimed.

## Implementation

Mesa patch 0130 adds opt-in `MESA_KK_PASS_PROF=1`, set by Settings › Developer's
Diagnostics › GPU time per pass alongside DXMT's existing variable. The queue
samples the submissions ending in presents 600/601, then 1800/1801, etc. It
replays those submissions with encoder-boundary Metal 4 timestamps (precise
compute samples; relaxed render-stage boundaries); one-shot
command buffers keep their commands for replay only while profiling is enabled.
The WSI present blit also goes through the recording trampoline so replay does
not omit the final copy. Ordinary, profiling-off one-shot recording is unchanged.

Each selected frame owns one 4096-entry heap (2048 encoders maximum). The queue
holds a reference until present, each submitted replay until completion. The last
reference resolves on the CPU after all sampled GPU work finishes, with no GPU
wait added to submission. An incomplete frame, overflow, GPU error or invalid
counter resolve is discarded, not counted as a cheap frame. Capture disables
profiling before heap allocation, with a second guard at the allocation site.

`[pass-prof]` reports encoder elapsed **milliseconds**, not DXMT's overlapping
vertex/fragment times. Render attachments are actual Metal format/load:store
numbers, including store overrides on the encoder. The tables retain that
distinction. Sampled passes identify a pipeline by its MSL hash when known;
multiple pipeline binds are labelled `mixed`. Native-copy work may share an
encoder with a dispatch; that whole encoder is conservatively untimed.

**Owner-approved scope:** native-copy/empty compute encoders, including mixed
native-copy + dispatch encoders, report `gpu=NA` with a reason. `passes.txt`
counts these as untimed, lists them separately and labels totals **PARTIAL**;
no unknown interval is silently summed as zero. Accurate copy timing is
[PLA-474](https://linear.app/playportdev/issue/PLA-474). The span is the extent
of valid sampled timestamps, not total GPU busy time. Each pass line is assembled
before one bounded fd write, so Wine's direct log writes cannot splice it between
multiple `fprintf` calls.

Pipeline creation logs Metal's maximum threads and static threadgroup bytes,
with the MSL hash and the **requested thread cap**. These are not register or
spill counts. KosmicKrisp compiles compute pipelines capped at their workgroup
size: a returned cap of 256 for a requested 256 does not prove a register limit.
A render pipeline may report 0 (unavailable). No compilation hint is changed and
no extra diagnostic pipeline is built to manufacture an uncapped proxy.

## Host checks

- `python3 -m unittest discover -s tools/tests -p test_passprof.py`: eleven tests
  pass: DXMT retained, encoder elapsed times/limits, mixed pipelines, pointer
  reuse, multiple reports, exclusion of truncated/discarded frames, unavailable
  costs/partial totals and two complete recorded phone frames
  (`tools/tests/fixtures/passprof-kosmickrisp*.log`, Hollow Knight and W3).
- `build/mesa-host-test/run.sh .work/scratch/pla466-mesa .work/run/mesa/host
  .work/run/mesa/hosttest`: exit 0. Includes existing Mesa/Zink regressions and
  `kk-pass-prof-test.c` against the actual driver's archives. The new checks
  cover first-submit and reusable replay, one-shot replay, deferred completion
  after present, the two-frame schedule, overflow, unfinished tails, resolve
  failure, profiling off, and capture armed with a mock that aborts on any heap
  allocation. Its 10 µs timestamps are **synthetic**, not GPU evidence.

- Focused cross-syntax checks of the initial C/Objective-C changes and profiler
  against the installed iOS SDK pass using the production compile flags.
  Subsequent full iOS builds compile the final changed sources.
  A first attempt added blanket `-Werror` and stopped on the existing
  `kk_shader.c` rasterization-mask narrowing warning; the warning remains,
  unrelated to this change. No Mac was needed for these API checks.

- `./pp test --quick` and `./pp test`: exit 0, including name/secret/patch-series
  gates, tools and C tests, and Swift packages. The full suite was repeated
  after the precise-compute correction, and again after unavailable/partial-total
  handling and the recorded W3 fixture: exit 0. The final mock-Metal Mesa/Zink
  suite also passes, including copy/mixed/empty classification and the known
  mocked dispatch interval.
- `./pp build`: exit 0; `verify-ipa` 90 passed, 0 failed. Dev IPA
  `.work/out/20261029-100846-a13eeb0b/Playport-26.5-a13eeb0b.ipa`, SHA-256
  `a13eeb0b704ea82980bc97807b353d8460068f3dd75f978db7ed154602a6cf5d`.

## Initial phone check (relaxed compute timestamps)

IPA `a13eeb0b…` above, upgraded in place. iPhone18,4, iOS 27.0.1, 80% charge,
external power. Vulkan (DXVK/KosmicKrisp), scripted pad connected before Play.

- `.work/pla466/hk-off`: profiling and capture off. First frame +11.47 s,
  completed first-frame+30; screenshot shows the normal title menu. **Zero**
  `[pass-prof]` log lines.
- `.work/pla466/hk-on`: profiling on, capture off. First frame +10.08 s,
  completed first-frame+40; screenshot shows the normal title menu. Six valid
  reports: presents 600/601 (5 encoders), 1800/1801 and 3000/3001 (34 encoders).
  Metal reports 24 MHz. The menu's four later sampled frames sum to 6.78–7.01 ms
  of encoder time, spans 8.21–10.57 ms. Render pipeline limits report 0 (not
  available for these non-tile pipelines).

**Not accepted as complete timing validation:** pipeline-less compute encoders
reported zero elapsed time. The SDK documents that relaxed compute sampling
may group all timestamps of a pass together. A precise compute-only profiling
path is added without changing Vulkan query timestamps' existing relaxed path.
The mock now models the documented grouping: with the profiler still calling
relaxed sampling, `run-pass-prof-test.py` failed its 10 µs interval assertion
(all three sampled intervals were 0). An earlier setup attempt stopped before
the regression because the newly named mock function had no bridge stub yet;
that was not accepted as a reproduction. The real red is retained in the task
log `be9567036`. With only the profiler calls switched to precise compute
sampling, the full mock-Metal Mesa/Zink suite then passed (task `b2639954e`),
including the same interval assertion and off/capture/resolve-failure cases.

## Second IPA: Hollow Knight gates

Second Linux build: `./pp build` exit 0, 90 IPA checks passed. Installed in place:
`.work/out/20261029-102605-0ba964b3/Playport-26.5-0ba964b3.ipa`, SHA-256
`0ba964b30475d83c4db7d01bc46b2f33046a4a60f29bb28ad027303d82c48956`.

- `.work/pla466/hk-off-final`: Vulkan, profiling/capture off, pad connected.
  First frame +11.00 s, completed first-frame+30. Normal title menu, no profiler
  lines.
- `.work/pla466/hk-on-final`: same, profiling on. First frame +10.18 s,
  completed first-frame+40. Normal title menu (notification overlay), six valid
  reports at 600/601, 1800/1801, 3000/3001; no discarded frames. The pipeline-less
  compute encoders **still report zero**, so the precise-path change is not
  evidence that their timing was fixed. The known driver compute dispatch has
  nonzero elapsed times. Whether native-copy work is represented by those zero
  intervals remains unvalidated; do not interpret them as proof copies are free.

Both results are successful, on the exact SHA above. These are smoke
checks, not new gameplay or performance results. PLA-42's latest check is updated;
the site's existing `works` status still agrees.

## First Witcher 3 timing run

`.work/perf/pla466-w3-pass-prof`, same `0ba964b3…` IPA. `pp perf --title
app-292030 --secs 150 --cool 3 --cool-max 10 --pass-prof`, Vulkan, runtime
`short-reserve-mb=6144 env.MADEIRA_FEX_PAUSE=yield`, pads Continue at first-frame+10,
Walk at +50, screenshots at +60/+140. First frame +21.74 s; completed
first-frame+150. Both screenshots show Kaer Morhen gameplay. The scene renders
at 1300x600, presented at 1564x720. Nominal → Fair, battery 80 → 78%, no charger
according to the run's battery samples. Not a controlled performance comparison.

`passes.txt` is generated by `pp perf` on Linux. Eight frame reports were emitted;
one (present 4200) is excluded by the parser because Wine's direct stderr write
spliced an error into pass 201. The stream lock did not prevent that; the final
implementation assembles each pass before one fd write. The parser correctly refused to
silently count the damaged frame as cheaper.

| Present (complete gameplay frames only) | Lighting-shaped dispatch, ms | Matching one-draw render split median, µs |
| --- | ---: | ---: |
| 1800 | 5.293 | 6.854 |
| 1801 | 5.267 | 6.917 |
| 3000 | 4.746 | 9.771 |
| 3001 | 4.807 | 9.834 |
| 4201 | 5.703 | 12.334 |

The largest compute pass is p55 in the first gameplay sample, as in the Mac
capture. Its MSL hash is `98cdc0471b1365e7`, max threads 256, requested cap 256,
static threadgroup memory 2064 bytes. This **does not** reproduce the Mac's
uncapped 384-thread register-pressure proxy. Timing is in the same order as
that profile, not a calibrated 6.3–7 ms match (camera, clocks, thermal state,
replay and measurement differ).

Every pipeline-less compute interval is still zero (61–66 per gameplay frame).
The native-copy timing limitation is real enough that it must not be called
validated per-encoder timing at that stage. This motivated the native Mac
probe below and the unavailable-cost handling in the final version.
PLA-43's latest check is updated; the site's existing `issues` status agrees.

## Native Mac probe: why copies are unavailable (PLA-474)

M1 Pro, 24 MHz counter, native Metal 4, no Playport build/install or phone input.
`build/mesa-host-test/metal-copy-timestamps.m` is the retained standalone probe;
its header has the compile/run command. Each trial copies and verifies the data,
waits on a shared event after the GPU work, then resolves the counter heap.

For both 15,360 bytes and 1 MiB, **12/12 intervals are zero** with each of:
relaxed sampling, precise sampling, precise plus intra-encoder dispatch/blit
barriers. Separate queue-ordered timestamp encoders give nonzero intervals,
but include marker/encoder overhead:

| Copy | Mean µs | Min–max µs (12 trials) |
| --- | ---: | ---: |
| 15,360 B | 170.003 | 47.208–1236.000 |
| 1 MiB | 41.087 | 27.375–49.083 |

Raw results: `$PLAYPORT_BUILD/pla466/copy-timestamps-mac.log` and
`copy-timestamps-boundaries-mac.log`. These are not credible measurements of the
Mac replay's ~3 µs native copies. The owner chose to ship valid render/dispatch
timing, mark copies unavailable and track accurate copy timing separately in
PLA-474. No guessed marker-floor subtraction or intrusive marker encoders ship.

## Final scoped IPA: accepted gates

Final Linux build: exit 0, 90 IPA checks passed. Upgraded in place:
`.work/out/20261029-110215-d4c896f8/Playport-26.5-d4c896f8.ipa`, SHA-256
`d4c896f8eeb260aed7ef4f93e0d149c8602dc83e9edd434de3de5a6192b8a3a0`.

One locked session (`.work/pla466/validate-scoped.sh`), stopped successfully and
released the lock before analysis:

| Run | Result |
| --- | --- |
| `.work/pla466/hk-off-scoped` | Vulkan, pad connected; first frame +11.99 s, completed +20. Title menu visible, zero profiler lines. |
| `.work/pla466/hk-on-scoped` | Same, profiling on; first frame +10.72 s, completed +30. Title menu visible (logo edge clipped in the stop shot); four complete sampled frames. Later frames explicitly count seven untimed native-copy encoders. |
| `.work/perf/pla466-w3-scoped` | `pp perf --pass-prof --secs 100`, same Vulkan/runtime/pads as the first W3 run, shots +60/+90. First frame +20.79 s, completed +100; both screenshots show Kaer Morhen gameplay. |

Final W3 reports: **6 emitted, 6 summaries, 6 parsed, none discarded**. The actual
`passes.txt` marks **PARTIAL**, lists **161 unavailable intervals** separately,
and retains pipeline limits. Mixed copy+dispatch encoders are unavailable too.
This verifies the partial-total protocol and the one-write records in a real
Wine log, not just a synthetic fixture. Its complete present-3000 frame is the
retained W3 parser regression.

The two gameplay samples (3000/3001) contain 200/211 encoders, 65/64 untimed. The
same lighting hash reports **10.213/10.234 ms**; matching one-draw render split
medians **15.855/14.042 µs** (42 each). Earlier 1800/1801 samples are transitional
(52 encoders, 14 draws, lighting 1.44 ms), not scored as the gameplay scene.
Pipeline limits remain 256 max / 256 requested / 2064 static threadgroup bytes.

This final run started **Fair**, reached **Serious**, and was on a charger
(80% throughout). It is not comparable to the earlier Nominal → Fair run,
Apple's serial profile, or a profiling-off performance control. In particular,
the proposed 6.3–7 ms lighting value was **not reproduced as a calibrated gate**.
The runs prove usable shader/render timing and identity, not an FPS improvement,
exclusive GPU cycles, spill counts or a new best-known game result. Elapsed pass
sums can overlap and exceed the sampled span; neither is whole-frame GPU busy time.

No automated release-variant phone test, cold/warm performance matrix, or accurate
native-copy measurement was performed. Copies remain PLA-474. Compatibility
statuses remain Hollow Knight **Works**, Witcher 3 **Playable with issues**;
`site/compatibility/games.json` already matches, so its rows are unchanged.

# A0 descriptor decision input: owner-played Hollow Knight

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**Plan:** [Proton parity, A0](../plans/2026-10-22-kk-proton-parity.md).
**Verdict: covered native cost looks small; total opportunity is NOT DECISIVE.
A0 does not authorize A2; A2–A4 remain unstarted/gated.**

Host-only analysis of one completed owner-operated run; no device command,
implementation, retry, save interaction or compatibility verdict in this chunk.
The measurement-design report
`.work/agent-notes/kk-parity/reports/a0-measurement-design.md` governs interpretation:
elapsed is not CPU time; large envelopes do not prove benefit, and incomplete
coverage cannot provide a complete negative bound.

## Run identity, exact historical command and phone state

- Hollow Knight (`app-367520`), owner playing from their own save throughout the
  run (owner/supervisor handoff, not an inference from counters). No scripted pad.
- Run: `.work/perf-runs/a0-descriptor-human-dxvk-20261024-r2/` (here **run**).
- Dev IPA: `.work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa`,
  **SHA256 `31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122`**.
  Independently rehashed the retained 559,143,632-byte archive. Measured launch's
  `installed` and final result events agree. These are install-record/expected-IPA
  checks, not a fresh install or an on-device binary rehash.
- Host argv HEAD and analysis starting HEAD: `be6fdc7`, branch
  `dev/kk-proton-parity`, initially clean. Install-record HEAD is `1c8534e`;
  archive provenance says `f27ed5b… (with local changes)`. No clean-source build
  at either run HEAD is certified; same retained IPA as the prior emission gate.
- Vulkan, 720p, 60 limit, DXVK/D3D11 (`-force-d3d11`), legacy sets
  (`descriptorBuffer : 0` at raw L15787/L19977). Graphics options exactly
  `MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1`.
- `run.json`: HUD off, CPU/pass profiling off, no GPU capture/energy run, runtime
  counters on, no pad script. HUD preparation is a separate tiny launch; **its
  1,080-byte `hud/pull/s1-host.log` is NOT the measurement input**.
- Recorded phone state: thermal **nominal**, no pressure recorded; battery
  **29→28%, external power false** (`summary.json`, corroborated by `power.txt`).
  No new status query; free space/unattended state and post-run restoration are
  not established here. Session-scoped settings, no `--keep-settings`.
- Measured launch pid/nonce `33930/66aad315`, session `b5770af6b957`.
  UI final result: `ok:true, exit:0, until_reached:true`,
  `why:"until first-frame+300"`; outer perf final result also `ok:true, exit:0`.
  First frame **+12.52 s**, JIT acquisition **3.34 s**; stop +319.0 s after app
  launch, followed by kill of the measured pid. No currently running game is
  inferred from this historical record.

Exact argv from **run**'s `argv.txt` (historical, **not executed by this writer**):

```sh
./pp perf --title app-367520 --secs 300 --no-hud \
  --settings '{"graphics":"vulkan","screen":"720","frameLimit":60,"arguments":"-force-d3d11","graphicsOptions":"MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1"}' \
  --out .work/perf-runs/a0-descriptor-human-dxvk-20261024-r2 \
  --shot first-frame+290 \
  --expect-ipa .work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa
```

### Recorded `pp perf` summary, not descriptor attribution

| Field | Recorded value |
| --- | --- |
| buckets / width | **62 × 5 s** (boundary buckets need not be full) |
| FPS mean / median / p10 / minimum | **59.4 / 60.0 / 58.9 / 44.4** |
| first_drop_s | **5** |
| hitches ≥25 / ≥50 / ≥100 ms | **0 / 0 / 0** |
| thermal / battery / charger | **nominal / 29→28% / false** |
| server frames / seconds | **17,877 / 302.6 s** |
| wineserver requests/frame | **13.51** (not DXVK submission requests) |
| first frame from title launch | **12.52 s** |
| ft_avg_ms / gpu_avg_ms | **null / null**, not zero |

The final perf event and saved summary agree. Its `log_bytes=14,892,836` matches
`this-launch.log`; the complete pulled raw is **14,893,006 bytes**. Only the latter
was parsed. `shot-ff290.png` was inspected: knight, health/currency and a room with
platforms/enemies, not a menu. The image stays in **run**, not `docs/`. This one
still corroborates gameplay at that instant, not an exact room/load boundary or
every intervening frame. The owner's handoff supplies the whole-run play claim.

## Whole-input strict parse: both modes exactly once

Read `python3 tools/descriptorprof.py --help` first. Only input:
`.work/perf-runs/a0-descriptor-human-dxvk-20261024-r2/run/pull/s1-host.log`,
all **53,546 lines**,
SHA256 **`5af8ec1a44e196ce91c2dddb96baff5a3f12295458367630f8370333fe325763`**.
Direct full-raw counts: **enabled 4, calibration 64, snapshot 14,122,
`emission failed` 0**. No filtering, subsetting, reconstruction or hand editing
of parser input; no earlier saved raw consumed.

```sh
python3 tools/descriptorprof.py .work/perf-runs/a0-descriptor-human-dxvk-20261024-r2/run/pull/s1-host.log
python3 tools/descriptorprof.py --json .work/perf-runs/a0-descriptor-human-dxvk-20261024-r2/run/pull/s1-host.log
```

Scratch: `.work/agent-notes/kk-parity/a0-human/` (**scratch** below), with `TMPDIR`
its `tmp/` subdirectory and `PYTHONDONTWRITEBYTECODE=1`. Foreground subprocesses
had a 600 s timeout; `cli-invocations.json` retains exact argv and producer exits.
`strict.text`, `strict.json` and their separate `.stderr` files retained; both
stderr files empty. Both modes **exit 2**, exact summary:

```text
Descriptor diagnostics: mixed; usable intervals=612
```

**612 usable / 0 rejected intervals; 0 source/stream issues, 0 invalid captures,
0 invalid calibration samples.** All 614 observed captures are complete and valid.
The unchanged consumer SHA256 is
`c84a1d72b26d2237c4ccedd16925c6b419cdb4f4803e9d53281f4db01a3a3b11`.
No schema relaxation; reviewed admission rules from the
[parser evidence](2026-10-23-descriptor-prof-parser-host.md) still apply.

Identity is `(component, pid, module, device, init_ticks)`. Raw line numbers:

| Identity | Banner; calibration lines | Complete captures; boundary lines | Admitted / rejected; reason |
| --- | --- | --- | --- |
| `kk,33930,absent,1,338366622980000` | L15910; L15911–15926 | **307 × 10**, serials 1–307; L21892–21901 → L53535–53544 | **306 / 0**; consecutive complete, quiescent, clock/history/count/timing-valid boundaries |
| `dxvk,100,4532407656,1,3383756274579` | L15928; L15929–15944 | **307 × 36**, serials 1–307; L21852–21891 → L53470–53505 | **306 / 0**; same strict checks, including nesting identities |
| `kk,33930,absent,2,338368012005000` | L20100; L20101–20116 | **none** | **0 / 0**, insufficient: two consecutive complete snapshots required; no zero baseline |
| `dxvk,100,4532407656,3,3383770102701` | L20122; L20123–20138 | **none** | **0 / 0**, same insufficiency, not observed zero work |

Each has one banner and all **16 calibration samples 0–15**. **Mixed** comes
solely from the two no-interval streams, not a concealed rejection. All four
lack an orderly final: **later work unknown**. Missing tails are reported but
are not themselves the parser's mixed predicate. Native module is absent, not
zero; native pid differs from client pid. Equal device IDs/serials/frequencies
prove neither correspondence nor aligned workload boundaries. There is **no
vkd3d stream** in this D3D11 run: D3D12 execute/copy costs are unmeasured, not zero.
The prior [phone gate/review](2026-10-24-descriptor-gate-phone.md) cautions remain.

## Played interior: denominators and derivation

After the whole-input parse, `scratch/analyze.py` aggregates **saved admitted
JSON deltas**, never re-parses raw excerpts. Fixed interior rule: each active
stream's **snapshots 31→290**, all **259 consecutive admitted intervals**;
discard the first 30 captures and last 17 captures from the *cost calculation*,
not from strict admission. This excludes launch/loading and termination margins
without selecting cheap/busy intervals. Full observed 1→307 accounting also
remains in `accounting.json`/`accounting.txt`. No other identity is silently
folded in. Every summed row delta is checked against its own saved endpoints.

| Stream-local window | Counter endpoints / actual denominator | Observation separation |
| --- | --- | --- |
| KK device 1, L26848–26857 → L51820–51829 | `frames` **1,604→17,173**, delta **15,569 successful-submit drawable signals** | **260.790434–260.790435 s** |
| DXVK device 1, L26858–26893 → L51765–51800 | requests **5,579→67,695**, delta **62,116 client submission requests** | **260.1281858–260.1281876 s** |

Coarse played-stretch context, **not an alignment/denominator conversion**:
KK's boundaries fall in raw order between `[frames] n=1600/1616` at
23:22:33.132/.399 and `n=17168/17184` at 23:26:53.907–54.173. DXVK's start has
the same surrounding frame-log rows; its end is between `n=17120/17136` at
23:26:53.106/.373. Against the first-frame host event at 23:22:03.201, that is
roughly **first-frame+30 to +291 s**. Log emission/event delivery and capture
brackets do not supply exact event-time alignment; the two windows are not
identical. No clock epochs were aligned, no request/frame ratio inferred.

**Exact per-presented-frame descriptor numbers are unsupported.** Native's
field named `frames` is drawable-submit signals, not scanouts; DXVK's is
requests, not frames. The 17,877 perf frames/302.6 s describe a different window
and cannot divide these totals. Below, “per signal” and “per request” always
mean the actual stream-local counter delta, never a presented-frame denominator.
Likewise there is **no valid total across layers or across all four identities**.

### KK descriptor operations and attributed elapsed time

**Elapsed ≠ CPU, not a wall union or removable savings.** These are disjoint
native entrypoint/driver-execution scopes; bind/push/template-push counts include
secondary/reusable-primary replay, **not application-call counts**. Replay may be
uncovered by the client scopes. Scopes exclude layout/template lifecycle,
constants, attachments and shader resource loads. Requested work is not proof of
successful work. Times include waiting/preemption/diagnostics; no overhead
subtraction. Formula: `sum(delta elapsed_ticks) / 1e9 × 1e6 / 15,569` µs/signal.

| Native operation | Executions | Executions/signal | Elapsed µs/signal | Numerical % of 16,700 µs **per signal**, not scanout-frame share |
| --- | ---: | ---: | ---: | ---: |
| allocate | 2,954,281 | 189.754063 | 30.071360 | 0.180068% |
| bind | 2,705,137 | **173.751493** | 12.204188 | 0.073079% |
| pool reset | 995 | 0.063909 | 12.190443 | 0.072997% |
| push | 15,569 | **1.000000** | 1.141050 | 0.006833% |
| template update (not template push) | 39,499 | 2.537029 | 1.662920 | 0.009958% |
| update writes/copies | 1,543,066 | 99.111439 | 20.942321 | 0.125403% |
| template push | **0** | **0** | **0** | **0** |
| free / pool create / pool destroy (each) | **0** | **0** | **0** | **0** |
| **Covered native total** | **7,258,547** | **466.217933** | **78.212281** | **0.468337%** |

Bind + push + template-push alone: **2,720,706 executions = 174.751493/signal**;
this subtotal is already inside the all-operation total, not an addition.
Total **1,217,687,000 ticks = 1.217687 elapsed s**. Zero rows above are observed
zeros in this admitted window only, not claims about missing streams/tails.
Allocate includes **995 reported failures**; timing failures/clock errors are
zero. Failure counters are retained API-result evidence, not parser corruption
or proof of a game defect. Do not subtract them or match them to another layer.

### DXVK client scopes: requests, NOT frames

**Summed same-thread elapsed, not CPU or wall union.** Only category-exclusive
rows are additive; parent inclusive overlaps children. The Vulkan partition is
already in the client envelope: **never add native time**, subtract layers, or
assume replay containment/count parity. Prep is broad, not fully removable;
standalone work remains separate; specification-data/constants/renderpass/
shader/layout-template-lifetime/heap-buffer paths are excluded or unobserved.
Formula: `exclusive_ticks / 1e7 × 1e6 / 62,116` µs/**request**.

| Category / operation | Calls | Calls/request | Exclusive elapsed µs/request (**not per frame**) |
| --- | ---: | ---: | ---: |
| prep / prep | 1,539,806 | 24.789201 | 19.663140 |
| prep / pool alloc | 2,907,138 | 46.801758 | 8.391946 |
| prep / vk allocate | 2,908,113 | 46.817454 | 13.395397 |
| prep / vk bind | 1,539,486 | 24.784049 | 4.481958 |
| prep / vk update | 1,539,486 | 24.784049 | 13.327103 |
| standalone / pool alloc | 39,419 | 0.634603 | 0.261831 |
| standalone / pool recycle | 62,120 | 1.000064 | 0.214117 |
| standalone / vk allocate | 39,436 | 0.634877 | 0.507418 |
| standalone / vk bind | 1,159,866 | 18.672580 | 5.235120 |
| standalone / vk reset | 993 | 0.015986 | 3.072564 |
| standalone / vk template update | 39,419 | 0.634603 | 0.723875 |

Within this client only, vk bind total **2,699,352 / 62,116 = 43.456630
calls/request**. There are no explicit push/template-push operation rows in
this client schema; their client-call counts are **unsupported, not zero**.
No vkd3d execute-request denominator is available here.

| Disjoint client elapsed subtotal | Ticks (10 MHz) | µs/request | Numerical % of 16,700 µs **per request**, NOT frame-budget share |
| --- | ---: | ---: | ---: |
| prep (28.055086 non-Vulkan + 31.204458 Vulkan µs/request) | 36,809,658 | **59.259543** | **0.354848%** |
| standalone (0.475948 non-Vulkan + 9.538977 Vulkan µs/request) | 6,220,871 | **10.014925** | **0.059970%** |
| observed excluded rows | 0 | **0** | **0** |
| **Observed client exclusive total, not fully removable** | **43,030,529** | **69.274469** | **0.414817% per request only** |

The last column is just `(µs/request)/16,700 × 100`, a scale reference, **not a
claim that descriptors consume 0.415% of a frame**. Actual client per-frame
budget share cannot be supplied. Total is **4.3030529 elapsed s**, about
**1.6542% of its own observation duration** as a *thread-sum/wall-duration scale*,
not CPU utilization, wall union or frame share. All other schema rows have zero
observed calls/time in this interior. The client reports **992 vk-allocation
failures (975 prep, 17 standalone)**, **320 empty-dirty prep calls**, and
**39,419 unknown-work template calls**: template cardinality/bytes are unknown,
not zero. Neither nested scope call counts nor write-record counts are summed
as independent application operations.

### Actual-platform calibration and feasibility

All 16 samples/stream valid; each records six clock reads. Values below are
**µs min / median / maximum (nonzero samples/16)**; raw ticks retained in strict
JSON and `accounting.json`, not subtracted. KK frequency 1 GHz; clients 10 MHz.

| Stream | Adjacent reads | Empty instrumented scope | Inner client scope |
| --- | --- | --- | --- |
| KK device 1 | 0 / 0 / 0 (0) | 0 / 0 / 1 (2) | not emitted |
| DXVK device 1 | 0 / 0 / 0.1 (5) | 0.1 / 0.2 / 4 (16) | 0 / 0 / 0.1 (4) |
| KK device 2 | 0 / 0 / 0 (0) | 0 / 0 / 0 (0) | not emitted |
| DXVK device 3 | 0 / 0 / 0.1 (4) | 0 / 0.1 / 1 (15) | 0 / 0 / 0.1 (6) |

Feasible for **aggregate elapsed screening**: long valid windows, millions of
counted executions, nonzero totals and no clock/history/nesting errors. Not
individual-call precision or an overhead bound: native samples are quantized
at observed 1 µs increments; QPC representation is 0.1 µs, not demonstrated
effective resolution. Zero adjacent/empty readings do not mean free clocks or
zero work. Sixteen short startup samples do not characterize runtime tails,
contention, publication/logging cost or disabled/enabled perturbation. With many
sub-resolution scopes, calibration/overhead uncertainty matters. Do not subtract
a median per call, call the aggregate CPU time, or extrapolate a savings bound.

## Earlier menu baseline: honest comparison

The [earlier CPU baseline](2026-10-23-kk-descriptor-cpu-baseline.md) remains
**INSUFFICIENT**: animated menus, selected running samples, definite printed
leaves about **0.086% DXVK / 0.050% vkd3d**, large JIT/top-N/inline/unwind gaps.
Those are **sample fractions**, not elapsed budget shares, and cannot be divided
into today's numbers or converted to CPU milliseconds. No old raw was re-parsed.

What changed relative to the same-IPA scoped menu emission gate is the
**workload: owner-save gameplay**, not the probe/parser method or its permission
to claim CPU. The earlier sampler was a different metric altogether, not a
comparable elapsed baseline. The append repair made native records observable
([host cause](2026-10-24-descriptor-append-cause-host.md)); previous native absence
was unobserved, never zero. Today's gameplay does not cure missing coverage,
denominator alignment, perturbation or elapsed-as-CPU limitations.

## A0 recommendation and next decisive measurement

**Still small / not decisive; do not start A2.** Use **167 µs of recoverable CPU
per presented frame (1% of 16.7 ms)** as an explicit *provisional screening
threshold*, not an owner-agreed or retroactively passed acceptance criterion.
The design required the owner to choose B and perturbation tolerance in advance;
no such agreed numeric B is supplied. Native's covered **78.212 µs/signal
(0.4683% per signal scale)** looks small, but is not complete descriptor CPU.
Client's **69.274 µs/request** cannot be compared directly with B per frame;
counts alone, its large number of calls, or elapsed alone do not authorize A2.
Thus this input neither proves a worthwhile removable CPU cost nor a rigorous
whole-descriptor below-B bound, and says nothing decisive about D3D12 copies.

**Next queue item: owner-approved A0 frame-aligned thread-CPU and perturbation
measurement, including the D3D12 selected-Simple path.** First agree B/error
budget and repeatable owner-save scene; commission a bounded measurement design
that associates actual presented-frame events with each stream's own boundaries
(without joining clocks by frequency), preserves request denominators, attributes
actual thread CPU to the named regions plus uncovered native replay, and separates
non-removable work. Use warm same-IPA diagnostics-off/on/off controls to bound
perturbation and a repeated representative window; include vkd3d's actually
selected optimized/default Simple implementation without switching its vtable
for profiling. A repeated, covered, credibly removable CPU opportunity above B
could justify reconsidering A2; an adequate uncertainty-inclusive bound below B
would defer it for this workload. No clock bridge/profiler implementation, new
phone session or A2 is authorized by this recommendation. Supervisor/owner may
instead defer A2 now; another uncontrolled DXVK menu/count run would not decide it.

## Plain not proven

- **No CPU attribution**, exact per-presented-frame descriptor cost, complete
  wall union, or complete all-stream/process cost. Native replay may be uncovered;
  missing streams/tails and explicitly excluded paths remain unknown.
- **No A/B against diagnostics flag-off**, perturbation bound, speedup, power
  saving, recovered CPU budget or descriptor-buffer benefit.
- **No gameplay-performance claim beyond the recorded frame stats**, no
  sustained correctness/compatibility verdict, no comparison to another title,
  scene or renderer; no D3D12 gameplay/CopyDescriptors measurement here.
- **A2 gate NOT satisfied; A2–A4 NOT started.** This is a bounded decision input,
  not an implementation go-ahead or a rigorous all-descriptor negative bound.
- No exact snapshot/frame alignment or across-layer arithmetic; no certification
  of source-clean IPA, every stream's lifetime, or post-run settings/phone state.

## Host checks and retained analysis

`./pp names` and `./pp secrets` both **exit 0, clean**; logs/statuses under
**scratch**. `git diff --check` passes. Only this evidence and the plan Runner
state are committed; no image, raw, home path, runtime/parser/build-record edit,
pin movement or plan-index change. All run-file hashes before/after analysis
match for **all 57 files** (`run-files-{before,after}.json`); parser bytes unchanged. No suite/build
needed for this documentation-only chunk. Saved-JSON arithmetic/assertions and
raw kind/size/hash/IPA/result checks retained in `verification.json`.

**Games observed (supervisor bookkeeping):** Hollow Knight (`app-367520`), IPA
`31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122`, run directory
above; **302.6 s played from the owner's save** per handoff and recorded server
span; **17,877 frames**, mean/median/p10/min **59.4/60.0/58.9/44.4 FPS**, thermal
nominal, recorded hitches ≥25/50/100 ms all zero. **No compatibility verdict**;
the supervisor files the title's Compatibility result. This writer made no
device command or game input.

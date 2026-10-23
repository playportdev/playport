# Descriptor diagnostic parser — offline host only

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**Plan:** [A0 Runner item 4](../plans/2026-10-22-kk-proton-parity.md).
**Independent parser review pending.** No native/client/runtime/Swift/profiler,
producer schema, defaults, pins or descriptor-buffer changes. No build, new IPA,
phone/install/UI/perf/game/network commands. This is log analysis, not another app
entrypoint or a new `pp` capability. A2 remains gated.

## Tool and source contract

```sh
python3 tools/descriptorprof.py saved.log another.log
python3 tools/descriptorprof.py --json saved.log
```

Module docstring/`--help` documents policy and limits. Exit **0** means usable
intervals without rejected evidence; **1** insufficient (including invalid-only
input); **2** mixed usable/rejected or insufficient-stream evidence. Missing
telemetry never reports successful zero cost. Inputs are read-only, separately
identified by argument index/file, component, PID, module (clients), device and
initialization ticks. No streams from separate files or components are merged.

Validated against actual producers, not just earlier prose:

- `.work/run/mesa/mesa/src/kosmickrisp/vulkan/kk_debug.c` enabled/calibration/report
  functions and `kk_descriptor_stats.h`: 10 rows, disjoint driver executions;
  KK calibration omits initialization ticks. Associate only with one preceding
  enabled lifetime for that file/PID/device; missing/ambiguous association rejects.
  Secondary/reusable-primary replay may lie outside client envelopes.
- `.work/run/vulkan-pe/dxvk/src/dxvk/dxvk_descriptor_stats.{h,cpp}`: 12 operations
  × 3 categories, exact banner and calibration keys (clock kind is in banner,
  **not** snapshot/calibration prefix); sibling-clock errors override capture flags.
- `.work/run/vulkan-pe/vkd3d-proton/libs/vkd3d/vkd3d_descriptor_stats.{h,c}`:
  18 operations × 3 categories, clock kind on every record, selected Simple path
  and uncovered flag required in enabled banner. All heap operation names and raw
  requested/processed element, metadata/payload byte and unknown-work counts stay
  distinct. RTV/DSV/constants remain excluded, not an opportunity assertion.

Strict exact known keys/version/kind/banner semantics, unsigned u64/boolean/sample
ranges, duplicate keys/rows, unique complete operation/category sets and consistent
metadata/units are checked. Ordinary decoration before the bracket marker is
accepted. Malformed/unknown diagnostic records have line reasons, conservatively
invalidate that input's snapshots, and are never silently ignored. Supported
platform clocks are QPC and the named monotonic host clocks; injected helper clock
kinds are explicitly unsupported. Monotonic clocks require 1 GHz units.

## Interval and denominator decisions

No implicit initialization-as-zero baseline. Require two consecutive, ordered,
complete captures of one identity; both boundaries must be quiescent, inactive,
clock-valid and fully match publication/calls/completed/timed identities. Validate
inclusive = direct children + exclusive, cumulative max bounds and exclusive total
= outer-thread-sum across categories. Inspect both boundaries for **historical**
operation/nesting/report errors, even `clock_ok=1 quiescent=1 final=1`; reject those
boundaries rather than correcting earlier valid child counters. Later errors do
not contaminate earlier clean intervals. No error recovery is attempted. A
cumulative reset/decrease, changed clock/units/order or saturation prevents hidden
recovery under that same identity. Rejected windows and captures retain reasons
and line provenance, not a best-looking-interval selection.

`active`, final and capture flags are state, not subtractable counters. Cumulative
`max_ticks` is checked for monotonicity and retained as an end-boundary bound, not
subtracted or advertised as an interval maximum. Overflow/saturation rejects.
Calibration keeps all raw flags/brackets (including failed samples) and reports
missing samples explicitly; it is never used as an overhead correction or proof
of phone precision. Missing/suppressed/killed final tail stays unknown.

For captures A and B, JSON preserves both `[ts_begin, ts_end]` brackets and the
observation separation range `[B.begin-A.end, B.end-A.begin]` in ticks/seconds.
This bounds **observation separation**, not workload event alignment. Quiescence
means capture consistency only. Completed maxima cannot bound active work; unsafe
active boundaries are rejected. Equal/quantized timestamps are valid measurements
but a zero lower separation is explicitly an insufficient duration denominator.
No rate is computed from these brackets.

Per-stream raw row deltas, ticks/hz elapsed seconds and actual workload deltas:

- KK `frames` is labeled **successful-submit drawable signals**, not scanouts.
- DXVK **client submission requests**, not frames.
- vkd3d **client execute requests**, not frames or GPU completion.

Zero counts are explicit. Presented-frame normalization is **unsupported pending
independently aligned frame/log design**. No elapsed-per-presented-frame,
CPU-per-frame, payoff/savings, threshold or automatic A2 decision is emitted.
Process/thread CPU context stays external. Scope elapsed includes preemption,
waiting and diagnostic overhead; summed thread scopes can exceed walltime.

Client prep summary sums only **exclusive** rows, partitioned into Vulkan and
non-Vulkan client work. Standalone and excluded are separately summarized; do not
add inclusive children or count excluded descendants twice. Prep is a broad,
ambiguous candidate envelope, not fully removable work. `work_unknown` is retained
beside numeric zeros, not silently treated as known zero cardinality/bytes.
Native elapsed remains a separate driver-execution sum: never sum/subtract layers,
assume count parity/containment or invent a shared epoch because frequencies match.

## Checks and retained examples

All commands used `PLAYPORT_BUILD=$PWD/.work` and repository-local
`TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp`; foreground commands bounded
600–1800 seconds, producer exit codes checked. No native helper rerun/build needed.

- Focused unittest: **18 passed**, including complete 10/36/54-row synthetic
  snapshots; prefix/interleaved device/module/lifetime/file isolation; exact schemas,
  calibration association/flags/missing data; malformed/negative/overflow/version
  cases; duplicates/truncation; reset/decreasing clocks/counters; active/final and
  operation errors despite clean capture flags; saturation; zero counts/equal
  timestamps; unknown work versus zero; cumulative max semantics; nesting,
  excluded descendants/RTV attribution; 50 seeded missing-row/token trials; CLI
  JSON/text and no-data exit behavior.
- `./pp test --quick`: **730 Python tests and 26 C groups passed**; Swift omitted.
- `./pp names`, `./pp secrets`, exact owned staging/whitespace/private-path checks,
  protected-owner comparisons and postcommit empty index: recorded in writer report.

Read-only REAL helper output (host fixtures, **not gameplay**) parsed together in
text/JSON: exit **2**, mixed evidence, **11 usable KK intervals**, no parser schema
errors. Schema support does not require deliberately bad fixture captures to pass:

| Input | Streams | Captures / row counts | Valid captures | Usable / rejected intervals |
| --- | ---: | --- | ---: | ---: |
| `.work/run/mesa/hosttest/descriptor-on.log` | 9 | 19 × 10 | 19 | 11 / 0 |
| `.work/run/mesa/hosttest/descriptor-helper.log` | 2 | 7 × 10 | 1 | 0 / 5 |
| `.work/agent-notes/kk-parity/supervisor-dxvk-clock.log` | 1 | 1 × 36 | 1 | 0 / 0 (single boundary insufficient) |
| `.work/agent-notes/kk-parity/supervisor-vkd3d-helper.log` | 2 | 2 × 1 | 0 | 0 / 0 (partial 1/54 rows, no banners) |

KK rejected evidence includes concurrent/active boundaries, historical bind clock
errors, saturation, invalid initialization/frequency and report-clock failures.
vkd3d partial snapshots explicitly reject incomplete coverage/banner data; one
also has saturation and an injected unsupported `incrementing` clock. DXVK's
printed sibling-error trace lines are ordinary test commentary, not schema rows;
its one complete printed capture cannot form an interval. No missing rows were
fabricated and real inputs were not rewritten.

Example first usable **host fixture**, not a cost conclusion: raw native delta
**162519 ticks** at **1 GHz** (0.000162519 elapsed seconds), observation separation
**452730–453352 ticks**, drawable-signal delta **0**. Normalization explicitly
unsupported. Synthetic client example: prep exclusive **90 ticks = 60 non-Vulkan
+ 30 Vulkan**, excluded **10**, standalone **20**; not inclusive100 + child30,
not CPU, not native+client, not recoverable savings.

Retained under `$PLAYPORT_BUILD/agent-notes/kk-parity/`:
`a0-parser-{focused,quick,names,secrets}.log`, `a0-parser-real.{json,txt}`,
`a0-parser-real-summary.txt`, `a0-parser-inputs.sha256`, synthetic examples and
`a0-parser-validation.log`. Committed tests generate only scrubbed synthetic IDs;
no raw private logs/PIDs/home paths are committed.

## Protected state and next gate

No IPA created. Existing dev IPA SHA256
`74c0d54e668570a320a11bf6e8e7c6aef46d42fb101f4d1aa0531b63408234b1`
remains prior build identity, **not a parser build or new calibration**. It includes
the owner's uncommitted SettingsView edit and is not exact committed-source
provenance. Protected owner file SHA256 remains
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`;
file and diff match the private snapshots. No owner staging/stash/reset/clean/commit.

**Next independent parser review**, then separately owner-coordinated existing
save/scene/activity/load/window/budget, actual-platform probe install/calibration,
off/on controls and bounded human gameplay. Native QPC/iOS precision, perturbation,
controls, runtime smoke and gameplay are **UNRUN** here. No games played. Supervisor
owns Linear synchronization and subsequent phone coordination. A2 remains gated.

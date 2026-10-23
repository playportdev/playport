# Descriptor probe device prep — blocked by interleaved wire records

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**2026-10-23. Partial DXVK menu smoke only; measurement PREP BLOCKED.**
Exact dev IPA upgraded in place, container retained. Both DXVK controls reached
first-frame+30 and visibly rendered the main menu. Actual phone calibration exists,
but strict parsing of the unchanged full enabled log returns **insufficient, exit1,
0 usable intervals, 17 malformed records**. Native snapshot output is interrupted
mid-line by other loggers. Supervisor directed stopping: **D3D12 off/on UNRUN**,
selected CopyDescriptorsSimple path **unobserved**, no runtime/parser correction,
reconstruction, filtering, repeat, logging rebuild or human measurement.

No game-menu buttons, save navigation, save selection, New Game, gameplay input or
human measurement were sent. The scripted pad was connected with `--pad` only;
no pad script/buttons were sent to the game. Owner controller untouched. Later
existing-save/room loading remains the owner's action, after supervisor coordination.
No A0 cost/benefit or A2 conclusion; A2–A4 remain not started.

## Build and retained raw evidence

Installed without rebuilding:
`.work/out/20261023-150040-74c0d54e/Playport-26.5-74c0d54e.ipa`.
SHA256 **`74c0d54e668570a320a11bf6e8e7c6aef46d42fb101f4d1aa0531b63408234b1`**.
Previously verified89/89, includes the protected owner's uncommitted UI edit:
**not exact committed-source provenance**. This chunk changed no build records.
Install producer exit0, `.work/install-runs/20261023-161343`: installed16:14:23+02:00,
30-second upgrade, explicitly “container kept”; never uninstalled.

Protected `app/Sources/S1Probe/UI/SettingsView.swift` SHA256 remains
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`.
File/diff match the owner snapshot and `.owner.diff`; never edited or staged.
Starting branch `dev/kk-proton-parity`, HEAD `9a31c85`; main `26699f6` untouched.

Run roots (all raw logs, events, argv, timeline and images retained):

| Route / flags | `.work/ui-runs/` directory | Producer / exact IPA | First frame / bound |
| --- | --- | --- | --- |
| DXVK D3D11 off | `descriptor-prep-dxvk-off-20261023` | exit0, final result ok, hash above | +13.64s / first-frame+30 reached |
| DXVK D3D11 on | `descriptor-prep-dxvk-on-20261023` | exit0, final result ok, hash above | +11.56s / first-frame+30 reached |
| vkd3d D3D12 off | UNRUN, stopped at blocker | — | — |
| vkd3d D3D12 on | UNRUN, stopped at blocker | — | — |

Notes under `.work/agent-notes/kk-parity/`: `device-prep-session.sh` and `.log`,
`device-prep-install.log`, `device-prep-dxvk-{off,on}.jsonl`,
`device-prep-dxvk-parser.{json,txt}`, `device-prep-analysis.txt`,
`device-prep-error-compare.txt`, `device-prep-raw.sha256`, before/final status logs.
Original enabled `pull/s1-host.log` SHA256
`f2668220bff3198b977d7f412ba6c17f99432ef35dbdc1fc7eef912f57947fac`;
parser JSON SHA256 `75560a876a00a2a849a5da1a4db8cba3bab60ae8e0b1c4b4a1398429dd97f8d4`;
text SHA256 `8a01e8b72b347b0532aed669500e1544c8701c48d9e3d2cb99dbcb4f77c7897a`.
Never rewrote these inputs/outputs. Screenshots/artwork stay under `.work`, not docs.

## Commands and visual limits

Read AGENTS, current Runner/DEVICE/help, accepted probe/parser host evidence, and
prior B3/A0 phone recipes. Foreground bash producers with >=600-second timeout;
checked producer statuses, not tail/echo statuses. Environment:

```sh
export PLAYPORT_BUILD="$PWD/.work"
export TMPDIR="$PWD/.work/agent-notes/kk-parity/tmp"
./pp phone lock -- bash .work/agent-notes/kk-parity/device-prep-session.sh
```

Session holds one lock across exact `pp install --no-build --ipa IPA` and both
plays; outer producer exit0. Each play uses `--expect-ipa IPA`, `--play app-367520`,
`--until first-frame+30 --wait 120`, `--pad`,
`--screenshot-after 20 --screenshot-after 30`,
`--shot`, explicit Vulkan/720/60/`-force-d3d11`. Off graphicsOptions empty; on exactly
`MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1`. UI actions HUDoff,
CPU/pass profilingfalse, GPU capture0, runtimeCountersOfffalse; no keep-settings,
capability flags, unsafe UBO, capture, extra workload or alternate app entrypoint.
Normal logging only. Backend and args confirmed by title/settings lines and DXVK3.1.1.

Images inspected, not assumed from result status:
- Off20s: Playport starting overlay, “No controller connected” at that instant;
  no claim this image proves controller readiness. On20s: publisher logo.
- Off30s: autosave-information splash (not evidence of a save write); on30s: black.
- **Both screen-stop.png show the correct live main menu**, Start Game highlighted,
  no obvious corruption; nothing selected. UI tool takes stop shots before ending
  the app. They occur2.085/2.204s after the stop marker. The requested fixed-time
  **pre-stop menu** visual criterion is not satisfied; no visual rerun authorized.

Zero descriptor markers in off's23,436-line log; enabled log25,469lines contains
both native and DXVK banners/calibrations/snapshots. Narrow VK_ERROR/device-loss/
GPU-fault/shader-or-pipeline-failure search found no candidates on either run.
DXVK warning/error message sets identical: existing EDID/display metadata and
monitor/interface/frame-statistics warnings remain. Not globally error-free logs.

**Autonomous cache side effect:** off log21 says `library: fex: disk cache 81.8 MB
with 9.19 GB free on the phone, under 10.0 GB: cleared`; on log22 repeats this policy
with80.8MB at9.19GB free. Worker neither requested nor manually deleted caches;
ordinary Play triggered the product's existing policy on both launches.
Do not describe caches as preserved. Compile/JIT logs retained in full (including
CB_SUMMARY and DXVK “Using6 compiler threads” at off21030/on21178); no launch-speed
claim, cold/warm equivalence or perturbation comparison. No cache setting changed.

## Actual-platform calibration (raw, not overhead correction)

Four independent lifetimes in the enabled log, all16 samples0–15 retained each:

| Label | Component / exact runtime identity | Banner line | Clock / Hz |
| --- | --- | --- | --- |
| K1 | kk pid29109 device1 init226412265084000 | 14299 | monotonic elapsed / 1,000,000,000 |
| D1 | dxvk pid100 module4466675048 device1 init2264212220103 | 14322 | QPC / 10,000,000 |
| K2 | kk pid29109 device2 init226413599895000 | 18302 | monotonic elapsed / 1,000,000,000 |
| D3 | dxvk pid100 module4466675048 device3 init2264225553669 | 18319 | QPC / 10,000,000 |

These identities are not joined or assumed one-to-one. Secondary K2/D3 have
calibration but no snapshots: their operations/tails are unknown, not zero.
Windows client `init_ok=1`; all calibration flags present are1, each six clock reads;
parser reports0 invalid samples in each stream. Native does not emit a separate
inner-scope bracket. All statistics below are **raw ticks**, min/median/max;
nonzero is number of samples, followed by distinct positive deltas (observed steps).

| Stream | Adjacent ticks; nonzero; steps | Empty instrumentation/publication ticks; nonzero; steps | Inner scope ticks; nonzero; steps |
| --- | --- | --- | --- |
| K1 | 0/0/0; 0/16; none | 0/0/0; 0/16; none | not emitted |
| D1 | 0/0/1; 1/16; 1 | 1/1/49; 16/16; 1,2,4,49 | 0/0/2; 5/16; 1,2 |
| K2 | 0/0/0; 0/16; none | 0/0/0; 0/16; none | not emitted |
| D3 | 0/0/1; 2/16; 1 | 0/1/9; 15/16; 1,2,9 | 0/0/1; 5/16; 1 |

QPC tick=100ns in reported units; native tick=1ns **unit, not demonstrated
resolution**. Zero/quantized native calibration does not establish zero cost or
precision; no host substitute, median subtraction or instrumentation-overhead
removal. Empty scope cost is not proof of full-run perturbation. No CPU-ms,
per-frame elapsed, savings, scanout rate or cross-layer aggregation inferred.

## Strict parser outcome and actionable wire blocker

```sh
python3 tools/descriptorprof.py --json .work/ui-runs/descriptor-prep-dxvk-on-20261023/pull/s1-host.log
python3 tools/descriptorprof.py .work/ui-runs/descriptor-prep-dxvk-on-20261023/pull/s1-host.log
```

Both exit1, **0 usable**, not a mixed exit2 pass. All86 candidate adjacent windows
(43K1 +43D1) rejected. No windows exist for K2/D3. All88 observed snapshots are
rejected conservatively due malformed source records, including structurally
complete ones. No favorable subset was reparsed or used to bypass rejection.

| Stream | Captures | Structurally complete rows | Partial rows |
| --- | ---: | --- | --- |
| K1 | 44 | 40 ×10/10 | snapshot3:1/10;16:7/10;17:6/10;24:9/10 |
| D1 | 44 | 41 ×36/36 | snapshot3:27/36;16:33/36;17:32/36 |
| K2 / D3 | 0 /0 | none | missing snapshots/tails |
| vkd3d | unrun | 54-row viability untested | selected Simple path unobserved |

Malformed source lines:21441,21444,21448,21450,21454,21457,21460,21465,21468,
23127,23131,23134,23269,23273,23276,23283,23888. First16 contain interrupted KK
snapshot prefixes plus DXVK snapshot rows (snapshot3,16,17); last contains a KK
snapshot24 row interrupted by CB_SUMMARY. All parser reasons:
`malformed key=value token`. Raw21441 is **KK kind=snapshot device1 snapshot3
op=allocate**, interrupted mid-record by **DXVK kind=snapshot device1 snapshot3
op=prep category=prep**. Sanitized bounded excerpts (ellipses mark omitted text,
not replacement input):

```text
21441: [kk-descriptor] ... snapshot=3 ... op=allocate calls=119 sets=119 write_records=0info:  [dxvk-descriptor] ... snapshot=3 ... op=prep category=prep ...
21442:  write_elements=0 write_bytes=0 ... active=0info:  [dxvk-descriptor] ... op=spec_data_excluded category=prep ...
21444: [kk-descriptor] ... snapshot=3 ... op=free ... copy_elements=0info:  [dxvk-descriptor] ... op=pool_alloc category=prep ...
21445:  copy_bytes=0 ... pool_bytes=0info:  [dxvk-descriptor] ... op=pool_recycle category=prep ...
23888: [kk-descriptor] ... snapshot=24 ... op=template_update ... clock_errors=0E 68 [CB_SUMMARY] ...
```

This is definite concurrent interleaving, not merely an unsupported intact schema
or missing final tail. KK row fragments resume on following physical lines; it
also interleaves with non-probe CB_SUMMARY. Actual reconstructed producer sources:
- `.work/run/mesa/mesa/src/kosmickrisp/vulkan/kk_debug.c:486–503` holds native
  `flockfile(stderr)`, then emits each snapshot via prefix `fprintf`, repeated
  per-field `fprintf` at500, and `fputc('\n')` at501. That native FILE lock does
  not demonstrate serialization with Wine/client logging.
- `.work/run/vulkan-pe/dxvk/src/dxvk/dxvk_descriptor_stats.h:201–217` assembles one
  `ostringstream` per row, `m_emit(out.str())`; `dxvk_device.cpp:17` supplies
  `Logger::info`. `src/util/log/log.cpp:48–103` locks its own mutex, prefixes lines
  and uses Wine `__wine_dbg_output` (with long-line split policy).

Likely emission/serialization defect across these independent sinks. No claim
that a particular single-write fix is proven sufficient; separate correction must
respect actual sink semantics. No native/parser/test-source edit made here.

All parsed K1/D1 snapshots report clock_ok1/quiescent1/overflow0/report errors0;
all retained rows clock_errors0/active0, client nest_errors0. Corrupted rows remain
unknown, so these flags do **not** make the full capture valid. Incomplete windows
also have count-sequence and client exclusive/outer-sum mismatch reasons; preserve
all parser reasons. Missing orderly tails on all four lifetimes, killed work unknown.
Raw observation separations near1s (max2.378s) show recurring reports, not usable
measurement intervals or steady menu residency throughout startup.

Actual workload counts exist, **not expected deterministic game counts**. Example
last structurally complete but REJECTED snapshot44, K1 lines25442–25451:
allocate139,913 calls; bind131,566/198,583 sets; update71,178/341,432 write elements;
template_update4,151/13,230 elements; push2,465/4,930 elements. D1 snapshot44
lines25404–25439: prep71,018 calls/340,700 prepared slots; prep vk_update71,018
calls/340,700 write elements; standalone vk_template4,143 calls. These cumulative
raw observations are not validated interval deltas or complete-process costs.
Allocation failures retained: K1 allocate37; D1 vk_allocate prep33/standalone4;
not clock/nesting errors and not a claimed GPU regression. No cross-layer count
parity, subtraction or containment claim. Unobserved operations remain unknown.

## Restoration and phone handoff

Session ended, then bounded read-only UI outside it restored and inspected settings:
- `.work/ui-runs/descriptor-prep-restore-options-20261023`: graphics and Developer
  options, then ten Down presses within **Playport options only**, never the game.
  Launch argumentsNone, Graphics optionsNone, Runtime keysNone, default720/60/Vulkan;
  inherited on-screen control overrides retained. Timeline explicitly settings `{}`.
- `.work/ui-runs/descriptor-prep-restore-diagnostics-20261023`: Developer and Graphics
  screenshots show sampling/pass/capture/validationoff, runtime counterson, HUDoff.
  Explicit `open:black`, screenshot, `--leave-running`: **last observed screen black**,
  not inferred from unattended mode. Both UI producers exit0, exact IPA hash.

No keep-settings. Lock released; status holdernull. Before:71%, external/charging,
7.1GB free; final:76%, external/charging,7.1GB free. Built-in JIT3.19/3.06s;
no timeout/person-required/power failure or retry. Readiness is historical, not a
promise for a later launch. Inherited unattended expiry unchanged:
**2026-10-23T17:44:05+02:00**; never toggled/renewed. Profile valid until
2026-10-30T13:00:08+01:00. No private device/store/team/pairing identifiers committed.

**Phone has the probes, but is NOT measurement-ready.** Supervisor owns a focused
wire-emission correction/review, renewed bounded prep authorization and subsequent
owner workload/window/budget coordination. Do not launch human measurement now.
Games observed: **Hollow Knight (Steam367520), DXVK menu only**. Supervisor updates
PLA-42/Compatibility without replacing prior gameplay status; RDR2 not launched.

## Host/documentation gates

`pp test --quick`, `pp names`, `pp secrets`, whitespace/exact staged-path checks
recorded in the worker report under the build area. No new test-source files;
original strict parser remained unchanged and correctly rejects damaged evidence.
Independent reviewer gate remains required. This is a committed **blocker
checkpoint**, not a completed device-calibration/measurement gate.

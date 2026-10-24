# Descriptor prep retry: menus render, telemetry BLOCKED

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **2026-10-23.**
One separately authorized menu-only retry after independent acceptance of Mesa0122/0123
(`68e5eab`/`cdaff3c`). Exactly two of the maximum four plays executed. **Preparation
fails:** native emission latches before its banner; unchanged strict parser reports
0 usable intervals and two explicit malformed poison records. Supervisor confirmed
STOP: D3D12 off/on remain UNRUN. No human measurement, gameplay or A2–A4 work.
Successful rendering below is separate from failed telemetry viability.

## Exact installation and bounded UI runs

- Exact verified dev IPA: `$PLAYPORT_BUILD/out/20261023-203743-689b9479/Playport-26.5-689b9479.ipa`.
  SHA256 `689b9479ff6d6910bf7d96fa359259345bd8ef1406ab7c361833800c7b9b7a4e` checked
  before use; previous89/89 verification reused, no rebuild. Includes protected,
  uncommitted owner UI edit: **not exact committed-source provenance**.
- `./pp install --no-build --ipa EXACT_IPA` exit0, installed20:49:46+02:00 in19s,
  explicitly **upgrade in place, container kept**; never uninstall. Install evidence
  `$PLAYPORT_BUILD/install-runs/20261023-204917` and notes `retry-install.log`.
- Install and both related plays held one supported `pp phone lock` session.
  Every UI command used `--expect-ipa EXACT_IPA`; all final `event:result` events
  match the full hash. No accidental newest-IPA selection, branch switch or build.
- Both runs: Hollow Knight (`app-367520`), Vulkan/DXVK,720p,60fps,
  `arguments=-force-d3d11`, no experimental capabilities. Off options empty;
  on exactly `MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1`.
  HUDoff, CPU/pass profiling off, GPU capture0, normal runtime counters; validation
  off confirmed on restoration. Session-scoped only, no keep-settings.
- `--until first-frame+50 --wait 120 --pad --screenshot-after 45
  --screenshot-after 55 --shot`. Neutral pad connection only during plays; no
  game buttons/keys, menu-button input, save navigation, Start Game or new slot.
  Owner controller untouched. No capture/profiler/CPU sampler, cache deletion
  request, runtime/parser/test-source change, extra play or screenshot rerun.

| Route | Run under `$PLAYPORT_BUILD/ui-runs/` | Producer/final result | First frame / JIT |
| --- | --- | --- | --- |
| DXVK off | `descriptor-retry-dxvk-off-20261023` | exit0,oktrue,first-frame+50 reached | +12.05s /3.14s |
| DXVK on | `descriptor-retry-dxvk-on-20261023` | exit0,oktrue,first-frame+50 reached | +11.32s /2.92s |
| D3D12 off/on | UNRUN | required STOP after full raw DXVK parse | actual Simple path and uncovered flag unobserved |

Both45s and55s screenshots were directly inspected for both runs: matching live
Hollow Knight main menus, Start Game highlighted but never selected, no apparent
rendering corruption. These are pre-stop images, not inferred from stopshots.
No gameplay or menu-residency proof for the entire capture. Images/artwork,
`events.jsonl`, `timeline.txt`, `argv.txt` and complete `pull/s1-host.log` remain
under the run directories, not committed. Selfcheckok, no reported pool/band
exhaustion or runtime-limit failures. No launch-speed/performance inference.

### Baseline errors and autonomous cache clearing

Read-only bounded analysis in notes `retry-analysis.txt`: GPU-error search
(`VK_ERROR`, device loss, GPU fault, shader/pipeline failure) found zero candidate
lines in either full log. Warning/error message sets have **no new on-vs-off
messages**: existing map_free_area, monitor/EDID/display metadata, unknown interface
and frame-statistics warnings remain. This is not a globally error-free claim.

Product itself cleared **80.8MB FEX disk cache on each launch**, log off21/on22,
reporting8.65GB free under its10GB threshold. Worker requested no deletion and
changed no policy. Six compiler threads reported at off21082/on21155. No cold/warm,
cache-preservation, startup or perturbation inference from these menu checks.

## Strict complete-log failure; native activation but no native stream

Unchanged commands, each producer exit1:

```sh
python3 tools/descriptorprof.py --json .work/ui-runs/descriptor-retry-dxvk-on-20261023/pull/s1-host.log
python3 tools/descriptorprof.py .work/ui-runs/descriptor-retry-dxvk-on-20261023/pull/s1-host.log
```

Full output retained as `retry-dxvk-parser.{json,txt}` plus stderr/exit-code files
in `$PLAYPORT_BUILD/agent-notes/kk-parity/`. **0 usable,60 rejected adjacent
intervals,61 rejected captures,2 malformed records**, no unknown schema reported.
Off24,231-line raw log has **zero diagnostic markers**. On26,204-line raw log has
2,232 diagnostic-marker physical lines. No filtering/reconstruction, discarded
rejections, favorable-subset reparse, schema relaxation or killed-tail zero fill.

Exact complete malformed lines **14473** and **18375** each read:

```text
[kk-descriptor] emission failed
```

These are intentional native failure-poison markers, **not evidence of renewed
row interleaving**. On log19 and2269 confirms the requested activation options;
poison proves the native emitter was reached. No KK banner, calibration or
snapshot row was emitted. Native identities, timings, active/error/overflow/work
cardinalities are therefore **unknown**, not zero. No complete10-row KK capture;
36-row DXVK structures survive but strict source poisoning invalidates them.
54-row vkd3d viability and actual selected Simple path/uncovered flag remain unrun.

Source-backed classification, read-only inspection:
- `$PLAYPORT_BUILD/run/mesa/mesa/src/kosmickrisp/vulkan/kk_debug.c:334–382`:
  any failed formatting/sink check or bounded write sets `emission_failed`, makes
  one best-effort poison write, and suppresses future rows for that device.
  `:477–495` emits the banner first and returns before calibration if it fails.
  Thus emission fails **before the first banner**, but **the failing branch is
  UNKNOWN from current telemetry**. The generic poison carries no errno/type/flags.
- Supported sinks remain successful F_GETFL/O_APPEND regular file or FIFO with
  whole row within known positive runtime PIPE_BUF. Other types/query failures,
  write failure/short write or formatting failure can all reach this marker.
  Do **not** infer that this phone sink definitely was unsupported.
- `app/Sources/WineHost/wine_host.c:1291–1320` normally append-opens/dup2s fd2;
  stamped mode and dev-cap machinery can divert it (`:312–326,361–385`). No saved
  log-cap notification found. This code is not observation of actual fd2 state.
  No additional diagnostic activation/reenactment authorized.
- Accepted0122/0123 host guarantees still assume stable fd2/flags; downstream
  relay integrity, other writers' partial lines and newline-only positive short
  plus failed-poison terminal edge remain limits. Client long-line splitting
  remains possible/unverified, not established as this run's failure.

### Separate client identities and rejected state

Both share pid100/module4506946920 but remain **separate** devices/identities:

| Label | Device / init_ticks | Banner line | Captures / intervals |
| --- | --- | ---: | --- |
| D1 |1 /2429617022242|14475|61×36/36 rows;60 rejected intervals,0 usable|
| D3 |3 /2429629989451|18376|0 captures;0 intervals, later work unknown|

All61 D1 captures have clock_ok1,quiescent1,overflow0,report_clock_errors0;
all2196 retained rows active0/clock_errors0/nest_errors0. Those flags cannot cure
source poisoning. Historical failure fields nonzero in103 rows, max50;
last rejected snapshot61 (lines26147–26182) vk_allocate failures prep50,
standalone7. `work_unknown` nonzero in59 retained rows (standalone vk_template),
last cumulative6192; unknown template cardinality is explicit, never filled with
zero. D3 has no row state to evaluate. Both missing orderly tails; later work
unknown. Multiple DXGI/DXVK devices never joined or paired with a native stream.

## Actual-platform raw calibration, no cost correction

Only D1/D3 have actual samples0–15, all16 each, init_ok1, six clock reads,
adjacent_ok/scope_ok/empty_ok all1; parser invalid-sample count0. Each QPC clock
is10,000,000Hz (tick unit100ns), **not established resolution**. Complete raw
begin/end values and validity remain in raw log and parser JSON. Derived raw
triples below are adjacent/inner-scope/empty-publication **ticks**, not CPU time:

```text
sample    D1 triple   D3 triple
0         1/1/74     1/1/8
1         1/0/1      1/0/1
2         1/1/4      0/0/0
3         1/0/1      0/0/1
4         0/0/2      0/0/1
5         0/0/1      0/0/1
6         0/0/1      1/0/1
7         0/0/2      0/0/1
8         0/0/1      1/0/1
9         0/0/2      1/0/1
10        0/0/2      0/0/2
11        1/1/1      0/0/0
12        1/0/1      1/0/1
13        1/0/1      0/0/1
14        1/0/1      0/0/1
15        0/0/1      0/0/1
```

| Stream / kind | min/median/max ticks | Nonzero/16 | Positive observed steps |
| --- | --- | --- | --- |
| D1 adjacent |0/0.5/1|8|1|
| D1 scope |0/0/1|3|1|
| D1 empty |1/1/74|16|1,2,4,74|
| D3 adjacent |0/0/1|6|1|
| D3 scope |0/0/1|1|1|
| D3 empty |0/1/8|14|1,2,8|

**Native calibration absent in this retry.** Previous native all-zero deltas are
quantization, not zero overhead or known resolution; never substitute previous
or host samples. Do not subtract medians/calibration, sum/subtract layers or
assume count parity/containment. Elapsed includes waiting/preemption/diagnostics,
not CPU or removable savings. Thread sums are not a wall union; client requests
and native drawables are not presented frames. Menu telemetry viability would
not establish gameplay, perturbation or A2 proof; here even viability failed.

## Retention, restoration and handoff

Hashes (full untouched inputs, notes `retry-raw.sha256`):
- Retry off log: `135e559240de5ddb99dffd48425ea79a44f188760a2c5ea2dacf961b7049e09f`.
- Retry on log: `48d01f122d68c38b9307e258d7aa4f9acca5ce2686ba287833b91d6199c7f0c2`.
- Parser JSON: `4e58a9e03a917f6270243b494dce03ed2901b986b702c66247db6af9d72225e5`.
- Parser text: `8ed8d8c820cf828a545aff08e5bbe9e74f50e1348c9c01cfd34543a39d9db3a3`.
- Original failed prep raw log stays immutable:
  `f2668220bff3198b977d7f412ba6c17f99432ef35dbdc1fc7eef912f57947fac`.

After STOP, supported UI launches outside the play session restored recorded
settings undo. Restoration runs `descriptor-retry-restore-{options,diagnostics,confirm}-20261023`
under `$PLAYPORT_BUILD/ui-runs/`, each producer0/finalok/exactIPA. Directly inspected
screenshots: argumentsNone, Runtime keysNone, Graphics optionsNone; default720/60/
Vulkan, previous on-screen control overrides retained. Sampling/pass/capture/
validationoff, countersnormal/on, HUDoff. Supervisor separately approved **one
read-only tenDown scroll in Playport Game options only** to reveal lower None
rows; never sent to a game. Final action explicit `open:black --leave-running`;
last screenshot directly observed **pure black**, not an unattended assumption.

Final status: lock holdernull, exact IPA installed in dev mode; battery**73%**,
externalpowerfalse/chargingfalse,**5.9GB free** (before75%,notcharging,6.1GB).
Unattendednull before/after; never toggled/renewed the expired inherited setting.
No JIT/setup failure or retry. Phone left black, no game launched for owner.

Protected owner SettingsView SHA256 before/after:
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`;
file cmp with owner snapshot and diff cmp with owner.diff pass. Never edited,
staged, stashed, reset or committed it. Main branch remains26699f6; work stays
on dev/kk-proton-parity. Only this evidence and minimal Runner/README docs owned
by this checkpoint; no logs/artwork/private identifiers/home paths committed.

**Installed but NOT measurement-ready.** Supervisor owns review, source-backed
failure diagnosis/any new authorization and Linear/Compatibility updates. Games
observed: **Hollow Knight (Steam367520), DXVK main-menu only**, no gameplay;
preserve earlier best-known gameplay status. D3D12 and other games not launched.
Owner personally loading/playing their existing save is later activity, not
started here. No automatic follow-up measurement; A0/A2 gates remain unchanged.

Validation: `./pp test --quick` exit0 (745 Python tests,26 C groups, all passed;
Swift excluded by quick), `./pp names`/`./pp secrets` exit0 clean. Diff hygiene,
exact staged-document-path assertion and protected owner/raw-hash checks pass;
logs `retry-{quick,names,secrets}.log` stay in the notes area. No test-source
changes. Independent review required; this is a blocker checkpoint, not a
completed preparation/calibration gate.

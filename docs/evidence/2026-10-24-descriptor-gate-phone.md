# Descriptor sink/append: two-route device emission gate

**Date:** 2026-10-24. **Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**Result:** the reviewed **emission/smoke gate is met on both routes**, on KK
native device 1: enabled banner, 16 calibration samples, complete 10-row captures
and admitted strict intervals, with no poison. This is not an all-device-stream
measurement pass: other identities have banners/calibration only, and every
stream lacks an orderly final tail. Both whole-input parser results are therefore
**mixed, exit 2**, not clean exit 0. **A0 justification remains unsatisfied; A2
stays gated.**

This writer performed host-only analysis of the supervisor's two completed runs;
no install, phone command, retry, gameplay or device input. The
[host repair](2026-10-24-descriptor-append-cause-host.md) and
[interrupted earlier attempt](2026-10-24-descriptor-gate-interrupted.md) remain
historical evidence, not re-parsed or rewritten here. Old native absence remains
unobserved, never zero.

## Provenance, session and exact historical argv

- Dev IPA: `.work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa`.
- SHA256: **`31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122`**.
- Branch: `dev/kk-proton-parity`; analysis started at `aa5736c` with a clean tree.
  The IPA's install record reports HEAD `1c8534e`; retained host `argv.txt` records
  DXVK at `1c8534e`, D3D12 at `aa5736c`. This is recording history, not a claim
  that the unchanged installed IPA was rebuilt at either run's host HEAD.
- Supervisor script: `.work/agent-notes/kk-parity/gate-retry-session.sh`.
  One lock session, **no reinstall**; both launches record `UI_SESSION=11a329210dd6`.
  `gate-retry-status.txt` records `dxvk-exit=0` and `d3d12-exit=0`.
  The `installed` events are install-record identity checks, not new installs;
  both `--expect-ipa` checks and final results match the SHA above.
- Run directories, retained unchanged, including screenshots and pulled raws:
  - DXVK: `.work/ui-runs/descriptor-gate-retry-dxvk-20261024/`.
  - D3D12: `.work/ui-runs/descriptor-gate-retry-d3d12-20261024/`.

These are historical commands, not retry instructions. The script's `pp ui`
arguments match each retained `argv.txt` (the latter names `tools/ui.py`):

```sh
./pp ui --action hud:off --action set:cpuProfile=false --action set:passProfile=false \
  --action set:gpuCaptureFrame=0 --action set:runtimeCountersOff=false \
  --settings 'app-367520:{"graphics":"vulkan","screen":"720","frameLimit":60,"arguments":"-force-d3d11","graphicsOptions":"MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1"}' \
  --play app-367520 --until first-frame+10 --wait 120 --pad --shot \
  --out .work/ui-runs/descriptor-gate-retry-dxvk-20261024 \
  --expect-ipa .work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa

./pp ui --action hud:off --action set:cpuProfile=false --action set:passProfile=false \
  --action set:gpuCaptureFrame=0 --action set:runtimeCountersOff=false \
  --settings 'app-367520:{"graphics":"vulkan","screen":"720","frameLimit":60,"arguments":"-force-d3d12","graphicsOptions":"MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1"}' \
  --play app-367520 --until first-frame+10 --wait 120 --pad --shot \
  --out .work/ui-runs/descriptor-gate-retry-d3d12-20261024 \
  --expect-ipa .work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa
```

Settings: Vulkan, 720, 60-frame limit, route argument as above,
`MESA_KK_DEBUG=descriptor_stats PLAYPORT_DESCRIPTOR_STATS=1`; HUD, CPU/pass
profiling and frame capture off; runtime counters enabled. Session-scoped:
no `--keep-settings`. No persistent-settings or restoration-after-this-session
claim is inferred from killing the app; restoration occurs on a later launch
outside the session.

### Outcome and phone state

Final `event:"result"` lines in `gate-retry-dxvk.jsonl` and
`gate-retry-d3d12.jsonl` agree with the corresponding run's `events.jsonl`:

| Route | Final result | Surface ready | JIT acquisition | Runtime started | Game started | First frame | Stop after launch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DXVK | `ok:true, exit:0, until_reached:true` | +0.71 s | 2.96 s | +5.01 s | +6.00 s | **+11.33 s** | 30.1 s |
| D3D12 | `ok:true, exit:0, until_reached:true` | +0.67 s | 3.03 s | +5.02 s | +6.02 s | **+13.56 s** | 34.8 s |

Both results say `why:"until first-frame+10"`. Launch pids/nonces:
DXVK `33551`/`d39e0a18`, D3D12 `33570`/`d93a1128`. Both runs record a stop
screenshot followed by `killed` for that pid. Both screenshots show Hollow
Knight's rendered main menu with Start Game selected; neither shows gameplay.
Screenshots remain only in their run directories; no image is published here.

**Supervisor-recorded before/after state (handoff, not a new status query):**
the above `31430e96…` IPA was already installed before the retry, and the
supervisor's `pp phone status` confirmed that SHA installed afterwards. After
both runs the app was not running, battery **35 % charging**, **4.3 GB free**,
`unattended:null`. The run events independently corroborate IPA identity and
both app kills; battery/free-space/unattended are attributed to the supervisor's
status record, not reconstructed from raw telemetry. No new before-run battery
value is asserted.

## Whole-raw integrity and unchanged strict consumer

The only inputs to the consumer were each **complete** `pull/s1-host.log` below.
No filtering, subsetting, reconstruction, hand editing, recovery or cross-layer
joining. Read `python3 tools/descriptorprof.py --help` first; ran the default
text mode and `--json` **once each per raw**, separately, with the consumer
unchanged from `aa5736c`. Commands were:

```sh
python3 tools/descriptorprof.py .work/ui-runs/descriptor-gate-retry-dxvk-20261024/pull/s1-host.log
python3 tools/descriptorprof.py --json .work/ui-runs/descriptor-gate-retry-dxvk-20261024/pull/s1-host.log
python3 tools/descriptorprof.py .work/ui-runs/descriptor-gate-retry-d3d12-20261024/pull/s1-host.log
python3 tools/descriptorprof.py --json .work/ui-runs/descriptor-gate-retry-d3d12-20261024/pull/s1-host.log
```

All output, stderr, exit statuses and analysis scratch are under
`.work/agent-notes/kk-parity/gate-retry/` (denoted **scratch** below); `TMPDIR`
was its `tmp/` subdirectory. `cli-invocations.json` retains actual argv/producer
exits; outputs are `dxvk.text`, `dxvk.json`, `d3d12.text`, `d3d12.json`, each
with its own `.stderr` file (**all four empty**). Saved-JSON summaries do not
re-run the consumer. Before/after SHA256 manifests verify **all 42 files in both
run directories unchanged**, not just the raws.

| Whole raw | Bytes / lines | SHA256 |
| --- | --- | --- |
| DXVK `pull/s1-host.log` | 3,289,108 / 26,039 | `c09b7c8e8d1bf98ce271296e3823c505503652a147051e697da14569d783bdbe` |
| D3D12 `pull/s1-host.log` | 3,915,125 / 27,117 | `94dbeb7841717d1cdca65f380f93cf2928aed0ef00676497b8eda3d52f20ad60` |

| Route | Enabled / calibration / snapshot **rows** | `emission failed` | Malformed/unsupported/poison | Text / JSON exit | Usable / rejected intervals |
| --- | --- | --- | --- | --- | --- |
| DXVK | **4 / 64 / 1104** | 0 | 0 | **2 / 2** | **46 / 0** |
| D3D12 | **5 / 80 / 1610** | 0 | 0 | **2 / 2** | **49 / 0** |

Exact text-mode summary lines:

```text
Descriptor diagnostics: mixed; usable intervals=46
Descriptor diagnostics: mixed; usable intervals=49
```

`mixed` is caused by the additional streams **without two snapshots/any
interval**, not a hidden malformed row or a rejected interval. There are no
source/stream issues, invalid calibration samples or invalid observed captures.
Missing final tails are reported explicitly but are not themselves the parser's
mixed-status predicate. All observed snapshot sets are complete; **no partial
snapshot row set** was retained. Missing tail means later work unknown, not a
manufactured final boundary or zero work.

## Every stream: identity, calibration and longest complete window

IDs are local telemetry identities, not phone identifiers. Native KK has **no
module field**; client `pid=100` is distinct from the Mach/native pid. Do not
infer device correspondence or temporal alignment across components from equal
numeric IDs, frequencies or serials.

Each row has **one enabled banner and 16 samples (sample 0 through 15), all
valid**. Raw line numbers refer to that route's complete raw. Longest window
means the maximal consecutive **complete, strict-valid capture sequence**:
10 rows/capture for KK, 36 for DXVK, 54 for vkd3d. These are observation windows,
not event-time-aligned gameplay or measured CPU durations.

| Route / component | pid / module / device / init_ticks | Banner line; calibration lines | Snapshot rows; longest complete window | Strict intervals admitted / rejected |
| --- | --- | --- | --- | --- |
| DXVK / KK | `33551 / absent / 1 / 330671452182000` | 15597; 15598–15613 | 240; **24 × 10**, serials 1–24, L21686–25977 | **23 / 0** |
| DXVK / DXVK | `100 / 4520086888 / 1 / 3306804521700` | 15615; 15616–15631 | 864; **24 × 36**, serials 1–24, L21648–26008 | **23 / 0** |
| DXVK / KK | `33551 / absent / 2 / 330672841915000` | 19956; 19957–19972 | **0; no complete window** | **0 / 0**, insufficient |
| DXVK / DXVK | `100 / 4520086888 / 3 / 3306818365958` | 19973; 19974–19989 | **0; no complete window** | **0 / 0**, insufficient |
| D3D12 / KK | `33570 / absent / 1 / 330724320295000` | 16181; 16182–16197 | 260; **26 × 10**, serials 1–26, L17911–27099 | **25 / 0** |
| D3D12 / vkd3d | `100 / 4498383696 / 1 / 3307352778120` | 16585; 16587–16617 (16 interleaved rows) | 1350; **25 × 54**, serials 1–25, L23390–27085 | **24 / 0** |
| D3D12 / DXVK | `100 / 4486696296 / 1 / 3307353251522` | 17672; 17673–17688 | **0; no complete window** | **0 / 0**, insufficient |
| D3D12 / KK | `33570 / absent / 2 / 330727681072000` | 21463; 21464–21479 | **0; no complete window** | **0 / 0**, insufficient |
| D3D12 / DXVK | `100 / 4486696296 / 3 / 3307366757831` | 21480; 21481–21496 | **0; no complete window** | **0 / 0**, insufficient |

Longest-window endpoint observation-separation bounds, derived from the retained
capture brackets without aligning clocks across layers:
DXVK KK **25.226245 s**, DXVK client **25.2281480–25.2281491 s**;
D3D12 KK **28.606095–28.606096 s**, vkd3d **26.6169906–26.6169930 s**.
These are not additional intervals admitted across nonconsecutive endpoints;
the parser admits only the consecutive pairs counted above.

### Exact enabled banners (whole raw lines)

These quote every banner's fields, including identity, units and coverage.
Client clocks are QPC at 10,000,000 Hz; KK is monotonic elapsed at
1,000,000,000 Hz. Every banner explicitly says `cpu_clock=unsupported`.

DXVK raw L15597:
```text
[kk-descriptor] v=1 component=kk kind=enabled pid=33551 device=1 init_ticks=330671452182000 hz=1000000000 clock=monotonic_elapsed cpu_clock=unsupported coverage=legacy_entrypoints scopes=disjoint rollback=allocate work=requested inline=bytes push=api_records failures=vk_result_or_command_error_at_exit excluded=layout_template_lifecycle_constants_attachments_shader_loads publication=relaxed_bracketed boundary=timestamp_range final_may_be_incomplete=1
```
DXVK raw L15615:
```text
info:  [dxvk-descriptor] v=1 component=dxvk kind=enabled pid=100 module=4520086888 device=1 init_ticks=3306804521700 init_ok=1 hz=10000000 schema=1 coverage=legacy_sets clock_kind=qpc cpu_clock=unsupported thread_model=summed_same_thread_scopes union=outermost_thread_sum exclusive=inclusive_minus_direct_children categories=prep,standalone,excluded candidate=sum_prep_category_exclusives_broad_not_fully_removable exclusions=spec_data_constants,renderpass,shader,layout_template_lifetime,heap_buffer_paths native=separate_uncovered_replay_no_cross_layer_subtraction capture=nontransactional active_or_invalid=reject killed_tail=missing denominator=client_submission_requests elapsed_includes=waiting,preemption,diagnostics
```
DXVK raw L19956:
```text
[kk-descriptor] v=1 component=kk kind=enabled pid=33551 device=2 init_ticks=330672841915000 hz=1000000000 clock=monotonic_elapsed cpu_clock=unsupported coverage=legacy_entrypoints scopes=disjoint rollback=allocate work=requested inline=bytes push=api_records failures=vk_result_or_command_error_at_exit excluded=layout_template_lifecycle_constants_attachments_shader_loads publication=relaxed_bracketed boundary=timestamp_range final_may_be_incomplete=1
```
DXVK raw L19973:
```text
info:  [dxvk-descriptor] v=1 component=dxvk kind=enabled pid=100 module=4520086888 device=3 init_ticks=3306818365958 init_ok=1 hz=10000000 schema=1 coverage=legacy_sets clock_kind=qpc cpu_clock=unsupported thread_model=summed_same_thread_scopes union=outermost_thread_sum exclusive=inclusive_minus_direct_children categories=prep,standalone,excluded candidate=sum_prep_category_exclusives_broad_not_fully_removable exclusions=spec_data_constants,renderpass,shader,layout_template_lifetime,heap_buffer_paths native=separate_uncovered_replay_no_cross_layer_subtraction capture=nontransactional active_or_invalid=reject killed_tail=missing denominator=client_submission_requests elapsed_includes=waiting,preemption,diagnostics
```
D3D12 raw L16181:
```text
[kk-descriptor] v=1 component=kk kind=enabled pid=33570 device=1 init_ticks=330724320295000 hz=1000000000 clock=monotonic_elapsed cpu_clock=unsupported coverage=legacy_entrypoints scopes=disjoint rollback=allocate work=requested inline=bytes push=api_records failures=vk_result_or_command_error_at_exit excluded=layout_template_lifecycle_constants_attachments_shader_loads publication=relaxed_bracketed boundary=timestamp_range final_may_be_incomplete=1
```
D3D12 raw L16585:
```text
330735.277:0064:0068:info:vkd3d-proton:d3d12_device_descriptor_emit: [vkd3d-descriptor] v=1 component=vkd3d kind=enabled pid=100 module=4498383696 device=1 init_ticks=3307352778120 init_ok=1 hz=10000000 clock_kind=qpc copy_simple_path=default uncovered_selected_copy=0 coverage=prep_broad_ambiguous_constants_ubo_tracking,copy_cpu_metadata,selected_simple,direct_vk exclusions=separate_constants_redzone,rtv,dsv native=separate_uncovered_replay_no_subtraction capture=nontransactional_all_rows_required errors=override_quiescent killed_tail=missing thread_model=same_thread_nesting_summed_elapsed_no_registry cpu_clock=unsupported denominator=client_execute_requests_not_frames_or_gpu_completions byte_counts=source_copy_assignments_not_memory_traffic additive=sum_exclusive_by_category parent_inclusive=overlapping elapsed_includes=waiting,preemption,diagnostics
```
D3D12 raw L17672:
```text
info:  [dxvk-descriptor] v=1 component=dxvk kind=enabled pid=100 module=4486696296 device=1 init_ticks=3307353251522 init_ok=1 hz=10000000 schema=1 coverage=legacy_sets clock_kind=qpc cpu_clock=unsupported thread_model=summed_same_thread_scopes union=outermost_thread_sum exclusive=inclusive_minus_direct_children categories=prep,standalone,excluded candidate=sum_prep_category_exclusives_broad_not_fully_removable exclusions=spec_data_constants,renderpass,shader,layout_template_lifetime,heap_buffer_paths native=separate_uncovered_replay_no_cross_layer_subtraction capture=nontransactional active_or_invalid=reject killed_tail=missing denominator=client_submission_requests elapsed_includes=waiting,preemption,diagnostics
```
D3D12 raw L21463:
```text
[kk-descriptor] v=1 component=kk kind=enabled pid=33570 device=2 init_ticks=330727681072000 hz=1000000000 clock=monotonic_elapsed cpu_clock=unsupported coverage=legacy_entrypoints scopes=disjoint rollback=allocate work=requested inline=bytes push=api_records failures=vk_result_or_command_error_at_exit excluded=layout_template_lifecycle_constants_attachments_shader_loads publication=relaxed_bracketed boundary=timestamp_range final_may_be_incomplete=1
```
D3D12 raw L21480:
```text
info:  [dxvk-descriptor] v=1 component=dxvk kind=enabled pid=100 module=4486696296 device=3 init_ticks=3307366757831 init_ok=1 hz=10000000 schema=1 coverage=legacy_sets clock_kind=qpc cpu_clock=unsupported thread_model=summed_same_thread_scopes union=outermost_thread_sum exclusive=inclusive_minus_direct_children categories=prep,standalone,excluded candidate=sum_prep_category_exclusives_broad_not_fully_removable exclusions=spec_data_constants,renderpass,shader,layout_template_lifetime,heap_buffer_paths native=separate_uncovered_replay_no_cross_layer_subtraction capture=nontransactional active_or_invalid=reject killed_tail=missing denominator=client_submission_requests elapsed_includes=waiting,preemption,diagnostics
```

### Exact strict-result lines and acceptance boundary

For **each of the nine identities** the text output says:
```text
  complete raw 16 samples; invalid samples=0; missing orderly tail; later work unknown
```
The full per-stream raw sample-0/sample-15 lines (including all flags and ticks)
are quoted with provenance in scratch `exact-quotes.txt`; all 16 individual raw
samples/line numbers per identity remain in each JSON output, with
`summary.json` indexing the windows.

DXVK native device 1, then DXVK client device 1 (`dxvk.text`):
```text
  snapshot 1 rows=10 lines=21686..21695: valid capture (not exact event boundary)
  snapshot 24 rows=10 lines=25963..25977: valid capture (not exact event boundary)
  interval 1..2: usable
  snapshot 1 rows=36 lines=21648..21685: valid capture (not exact event boundary)
  snapshot 24 rows=36 lines=25967..26008: valid capture (not exact event boundary)
  interval 1..2: usable
```
D3D12 native device 1, then vkd3d client device 1 (`d3d12.text`):
```text
  snapshot 1 rows=10 lines=17911..17920: valid capture (not exact event boundary)
  snapshot 26 rows=10 lines=27090..27099: valid capture (not exact event boundary)
  interval 1..2: usable
  snapshot 1 rows=54 lines=23390..23443: valid capture (not exact event boundary)
  snapshot 25 rows=54 lines=27032..27085: valid capture (not exact event boundary)
  interval 1..2: usable
```
For DXVK-route KK device 2 and DXVK device 3, and D3D12-route KK device 2 and
DXVK devices 1 and 3, the exact output is:
```text
  INSUFFICIENT: two consecutive valid complete snapshots required; no zero baseline
```

**Per-route review criteria:** DXVK **met for native device 1** (banner + 16
samples + 24 complete 10-row captures, 23 admitted intervals); D3D12 **met for
native device 1** (banner + 16 samples + 26 complete 10-row captures, 25 admitted
intervals). Thus native emission through the repaired ordinary log sink and the
two-route launch smoke are observed on this IPA. Native device 2 on **both**
routes falls short of complete-capture/interval criteria: only banner and
calibration observed. The client-only identities listed above likewise lack
captures. This does not certify every stream or complete lifetime coverage.
There is no sink-identifying poison to diagnose in these runs; **zero poison
records is not evidence of zero descriptor work**. A diagnostic poison would
have been failure evidence, never a measurement pass.

## Explicitly not proven / next

- **Menu-only to first-frame+10**, not representative gameplay; no save was
  entered, no gameplay or autonomous game interaction. No gameplay correctness
  claim or compatibility verdict beyond **“the title launched to a rendered
  first frame on this IPA.”** The supervisor files the compatibility entry.
- **No performance result**, benchmark, regression exclusion or speedup claim.
  Startup marks are only smoke timings, not an A/B comparison.
- **No CPU attribution**: these clocks measure elapsed scopes, including
  waiting, preemption and diagnostics, not CPU time or a wall-time union.
- **No savings or perturbation claim**: calibration is retained raw, not
  subtracted; diagnostic overhead is not quantified. Client prep envelopes are
  not removable work. No cross-layer sum/subtraction, identity join, frequency
  alignment or presented-frame normalization.
- **No descriptor-buffer benefit or A2 authorization**: vkd3d reports
  `copy_simple_path=default`; these are legacy-path diagnostics. The earlier
  menu CPU profile was judged **INSUFFICIENT**, and launch/emission success does
  not overturn that judgment. **Next: A0 interpretation** (defer versus an
  owner-authorized representative workload); **A2–A4 remain unstarted/gated**.
- No complete-lifetime/terminal-loss guarantee: all orderly tails are missing,
  banner-only streams are unobserved beyond calibration, and old saved native
  absence remains unobserved, never zero. No general concurrent sink-rebinding
  or flag-mutation guarantee follows from two successful captures.

## Host recording checks

`./pp names` and `./pp secrets` both exited **0**, reporting **clean**; logs
`names.log`, `secrets.log`, producer statuses `check-status.txt` under scratch.
`verification.log` records exact raw-banner/strict-output quote checks, per-stream
sample/capture checks, matching final run/notes results and all 42 run-file
hashes. Consumer SHA256 remains
`c84a1d72b26d2237c4ccedd16925c6b419cdb4f4803e9d53281f4db01a3a3b11`,
byte-identical to `aa5736c`. No build, suite or device command was needed for
this documentation-only chunk; no earlier raw was consumed. The committed
scope is this evidence plus the plan Runner-state update, with no home path or
image.

**Games observed:** Hollow Knight (`app-367520`), DXVK and D3D12 routes, IPA
`31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122`, both run
directories above, both reached a rendered first frame +10 with no poison.
**No gameplay and no autonomy with the game.** This writer used no device
commands; compatibility bookkeeping is the supervisor's responsibility.

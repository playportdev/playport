# Hollow Knight Vulkan performance resume: opt-in probes, no default winner

**Linear:** PLA-72; [plan](../plans/2026-10-06-vulkan-performance.md).
**Session:** 2026-10-22–23, unattended, main checkout. This continues the plan's
2026-10-21 desk review; it is not an exit-criteria result. Only Hollow Knight
(Steam 367520) was played. Portal 2 was removed to make room for its installation;
RDR2 was untouched. No MSL 4.1 experiment was run during the continuation.

## Outcome

- Vulkan still spends more tiler busy time per frame than DXMT and reaches thermal
  pressure earlier. This investigation found **no safe proved default winner**.
- Nine independently selectable probes are retained, **off by default**, in Mesa
  0109–0117. Host shader/AIR reductions were hypotheses, not measured speedups.
- The strongest repeatable signal was `no_fp_preserve`: in a stationary-room ABBA,
  hot GPU time was 10.50–10.68 ms against 11.28–11.34 ms with switches off (about
  6.4% lower). FPS improved only 0.4–1.6; energy and tiler-time improvements were
  not established. This switch relaxes advertised NaN/Inf semantics and stays
  **diagnostic, opt-in**, not a shipping fix.
- `ubo_unbounded` removes required bounds checks and can fault or return incorrect
  data. It remains measurement-only. `fp_precise_only` also has unproven NaN
  correctness. Matching screenshots cannot prove any of these semantically safe.
- No historical regression was established under comparable conditions, so no
  commit bisect was justified. The combined arm did not reproduce a performance
  regression against the confirmed float-only range, so subset bisection was not
  triggered; the unusually fast single float screening result did not repeat.

## Builds and protocol

Baseline dev IPA:
`71029ff49f204321f5cedbe2cd8a05b2b5a7415881232a1a00375b4c54b0ddd0`.
Experimental dev IPA:
`315cee09ef51e7516a1251f60b65b3f4b358435e3051b1ed3cfaa41f3129ffeb`.
The experimental build was made from c2121f5 plus Mesa 0109–0117 and their host
tests; it also inherited an unrelated, uncommitted SettingsView change. That
change is not part of this work and is not committed here. Its baseline smoke
was `$PLAYPORT_BUILD/ui-runs/20261022T232850` (`first-frame+10`, successful).

Phone: iPhone18,4, iOS 27.0.1, external power, charge 80% throughout the measured
continuation. Every cooled run began at thermal `nominal`, after
`--cool 15 --cool-max 25`. Native resolution, free-running, Vulkan/DXMT selected
through the game's UI settings. Each cache variant was warmed before screening;
continuation measured logs show 64 deserialized stages and zero translation or
compile failures. All run directories below are beneath `$PLAYPORT_BUILD/perf-runs/`.
The producer exit status and final `result` event were checked, not stale writer
summaries. No completed old-writer run was repeated as an allegedly unfinished run.

Original route v2: `--secs 130 --pad first-frame+25:hk-new-game --pad
first-frame+80:hk-walk --shot first-frame+128`. Its final scene sometimes diverged.
**Stationary continuation (`g2-*`, `g3-*`) deliberately omits `hk-walk`** and stays
in the opening King's Pass room after the new-game cinematic. Read those arms
only against their stationary control, not against the walking baseline or the
2026-10-08 references. Window `85:125` is the stationary post-cinematic scene;
`15:40` includes menu transitions, not a gameplay benchmark.

Tiler busy ms/frame is `til% * 10 / FPS`, from the IOAccelerator utilization
samples; it is not a GPU timestamp duration. The GPU clock is not measured.
System power is a coarse battery-gauge reading: its repeat spread, especially
in the early window, is too large to support a small energy claim.

## Original baseline and settings screens (71029ff4)

Route-v2 ABBA, `pp perf --compare ... --window 85:125`:

| run | FPS | p99 ms | GPU ms | til% | Mi/f | sys mJ/f | first pressure s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| pla72r-b-dxmt-1 | 83.3 | 25.0 | 9.95 | 59.9 | 64.8 | 52.9 | 80 |
| pla72r-b-vk-1 | 75.5 | 25.0 | 11.81 | 84.3 | 79.2 | 58.6 | 45 |
| pla72r-b-vk-2 | 77.4 | 25.0 | 11.56 | 85.9 | 78.3 | 57.5 | 60 |
| pla72r-b-dxmt-2 | 83.4 | 29.2 | 9.75 | 69.0 | 64.2 | 59.6 | 75 |

At `15:40`, both backends had GPU time 6.38–6.54 ms, but Vulkan tiler busy time
was 7.16–7.20 ms/frame against DXMT's 4.23–4.29. At `85:125` it was
11.10–11.16 against 7.19–8.27. `SplitSceneCount` was zero; geometry buffer sizes
were similar. GPU driver memory was about 1.08 GB on Vulkan versus 0.35–0.39 GB
on DXMT (a separate, uninvestigated lead).

The old reference's DXMT hot-window GPU time of 7.46 ms is not a valid regression
oracle here: its pressure began at 105 s rather than 75–80 s. Pre-pressure
King's Pass buckets were 6.67–6.75 ms now versus 6.56–6.84 ms then. Vulkan's
11.56–11.81 ms is below the reference's 13.40 ms. No bisect was performed.

`pla72r-s-wa14`: 10.56 ms, but the walk ended in another spot, so not an
attributable gain. `pla72r-s-wa6`: 11.56 ms, no measurable gain, same scene.
Workaround 17 is already disabled on this OS, so separate 17/14,17 arms were
skipped. The shader dump is retained privately under
`$PLAYPORT_BUILD/agent-notes/pla72r/dump-hk/` (36 pipelines).

## What the new probes measure

| Mesa patch | UI Graphics options switch | Purpose / constraint |
| --- | --- | --- |
| 0109 | `MESA_KK_EXPERIMENTAL=no_fp_preserve` | Hide NaN/Inf-preservation properties; semantic risk, never default from these tests |
| 0110 | `...=fp_precise_only` | Restrict preservation / group math pragmas; backend NaN behavior unproven |
| 0111 | `...=root_table_loads` | Keep root-table loads rooted in constant argument pointers |
| 0112 | `...=const_offset_loads` / `...=ubo_unbounded` | Constant-space descriptor loads / **unsafe unchecked UBOs** |
| 0113 | `MESA_KK_DEBUG=passes` | Encoder/barrier/clear/store opportunity counters |
| 0114 | `MESA_KK_EXPERIMENTAL=narrow_barriers` | Narrow render-end stage barrier, retain vertex dependency waits |
| 0115 | `...=ds_dont_care` | Elide a depth/stencil store only for the immediately following eligible discard |
| 0116 | `MESA_KK_DEBUG=vertex_stats` | Count geometry and emulation work |
| 0117 | `MESA_KK_EXPERIMENTAL=ubo_vec4_bounds` | Merge checked scalar UBO loads within a 16-byte chunk; preserve reported robust granularity |

Shader inspection corrected the desk-review hypothesis: HK's DXVK shaders use
float-controls-1 SignedZeroInfNanPreserve, not float-controls-2, and every float
operation is NoContraction. DXMT treats these shaders as precise too. KosmicKrisp
adds the multiply guard and precise functions, but the much larger AIR reduction
came from removing UBO bounds checks. That reduction is **not** permission to
remove robustness. The checked-vector alternative reduced host AIR size, but did
not show the predicted large tiler reduction on the phone.

Counters (`pla72r-s-stats`) showed about 14,000 vertices, 4,700 primitives and
50,500 output slots/frame, 96–97 draws, 24 render and 5 compute encoders/frame,
no unrolling/GS/tessellation, no render splits, and zero fold, merge or dead-DS
candidates. Therefore no further `ds_dont_care` measurement was justified.
`pla72r-g-nb-count` (warm diagnostic run, not a perf comparison) showed 24 vertex
waits per 25 render encoders (96%); per the barrier helper's stopping rule, no
narrow-barrier ABBA was justified.

## Experimental-IPA screens

Old-writer cooled route-v2 screens, `85:125`:

| run | option | GPU ms | FPS | cool-window tiler ms/frame |
| --- | --- | ---: | ---: | ---: |
| pla72r-s-stats | counters | 11.14 | 55.0 | 7.07 |
| pla72r-s-col | const_offset_loads | 11.45 | 75.3 | 7.10 |
| pla72r-s-unb | ubo_unbounded | 10.38 | 72.4 | 6.93 |
| pla72r-s-v4 | ubo_vec4_bounds | 11.84 | 75.7 | 7.09 |

The counters arm ended in the opening chamber, unlike col/unbounded. Vec4 ended
at a slightly different cave position with the low-health darkening effect.
These are **screens, not controlled hot-window wins**. The expected multi-ms
tiler-time reduction did not appear in the comparable early windows.

A fresh switches-off warm-up was `pla72r-g-w-off`. Cooled `pla72r-g-off-1`
completed, but logged `Metal HUD off` after a settings undo (the known PLA-82
signature); its GPU figures are invalid. To avoid rerunning that unchanged setup,
the continuation turned the HUD on through `pp ui --action hud:on --keep-settings`
and used stationary runs. HUD was present in every g2/g3 measured screenshot/log.

Stationary screens on the **same** experimental IPA, `85:125`:

| run | option | GPU ms | FPS | tiler ms/f | Mi/f | sys mJ/f | pressure s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| pla72r-g2-off-1 | none | 11.34 | 82.6 | 9.58 | 72.2 | 55.4 | 65 |
| pla72r-g2-nofp | no_fp_preserve | 9.27 | 74.8 | 9.61 | 77.9 | 61.7 | 70 |
| pla72r-g2-prec | fp_precise_only | 10.77 | 83.1 | 10.08 | 71.1 | 56.5 | 70 |
| pla72r-g2-root | root_table_loads | 11.40 | 82.6 | 9.47 | 73.0 | 55.7 | 70 |
| pla72r-g2-combo | col + vec4 + nofp + root | 10.69 | 81.5 | 9.79 | 76.2 | 55.6 | 90 |
| pla72r-g2-nb | narrow_barriers | 10.73 | 79.7 | 10.29 | 74.2 | 55.4 | 65 |

Root-table loads did nothing measurable. The combination did not beat the
confirmed float-only range below, so there is no demonstrated combined benefit.
Its 10.69 ms does not establish a bad combination: the 9.27-ms single-screen
float result had lower FPS and was not repeated by either confirmation arm.
Precise-only's similar single-screen signal remains unconfirmed and risky;
there is no shipping decision that requires further testing it here.

## ABBA confirmation, no_fp_preserve versus switches off

Consecutive stationary runs, warm caches, `pp perf --compare` window `85:125`:

| order / run | GPU ms | FPS | p99 ms | tiler ms/f | Mi/f | CPU mW | sys mJ/f | pressure s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A pla72r-g3-off-a | 11.28 | 83.0 | 20.84 | 10.00 | 70.4 | 248 | 52.6 | 75 |
| B pla72r-g3-nofp-a | 10.68 | 84.2 | 20.84 | 9.84 | 71.1 | 251 | 61.6 | 75 |
| B pla72r-g3-nofp-b | 10.50 | 83.4 | 25.01 | 9.94 | 71.2 | 247 | 54.9 | 90 |
| A pla72r-g3-off-b | 11.34 | 82.6 | 20.84 | 10.06 | 71.9 | 248 | 54.8 | 70 |

GPU-time ranges do not overlap; the approximately 6.4% signal is real within
this bounded test. Tiler busy time differs only 0.06–0.22 ms/frame; no large
geometry-side improvement appeared. CPU-work ranges overlap. Energy is not
better (and the float arm's spread is large); the thermal onset still varies.
At `15:40`, GPU ms is 6.35–6.36 off and 6.36–6.38 on; tiler ms/frame is
6.92–6.95 off and 6.95–7.12 on. This does not close the original DXMT energy gap.

All g2/g3 screenshots show the same opening chamber, Knight, grass and lighting,
with small position/animation differences; no obvious corruption. Original
route screens were inspected too, including the route divergences noted above.
No command-buffer/GPU-fault or shader compile failure was found. These image
checks do not prove NaN semantics, robustness or general barrier correctness.
Screenshots and raw logs remain in their run directories, not in this document.

## Validation and retained artifacts

- Inherited producer host test: `agent-notes/pla72r/w/hosttest1.log`, passed.
  168 flag-off host MSL files were byte-identical to the helper's unpatched
  baseline. No new host MSL 4.1 test was run during this continuation.
- `./pp test --quick`: passed again after takeover
  (`agent-notes/pla72r/w/g-test-quick.log`).
- Experimental build verified: 89 checks passed, 0 failed; smoke reached
  `first-frame+10`. Switches were exercised through UI Graphics options only.
- Detailed helper analysis, comparison tables, producer exit records and durable
  continuation report are under `$PLAYPORT_BUILD/agent-notes/pla72r/`.

### Complete played-run inventory for compatibility tracking

All entries below are Hollow Knight. Baseline IPA 71029ff4:
`pla72r-dump-vk`, `pla72r-warm-dxmt`, `pla72r-b-dxmt-1`, `pla72r-b-vk-1`,
`pla72r-b-vk-2`, `pla72r-b-dxmt-2`, `pla72r-s-wa14`, `pla72r-s-wa6`.
Experimental IPA 315cee09:
`pla72r-w-stats`, `pla72r-w-col`, `pla72r-w-unb`, `pla72r-w-v4`,
`pla72r-w-nofp`, `pla72r-w-combo`, `pla72r-w-nb`, `pla72r-w-dsdc`,
`pla72r-s-stats`, `pla72r-s-col`, `pla72r-s-unb`, `pla72r-s-v4`,
`pla72r-g-w-off`, `pla72r-g-off-1` (HUD-invalid), `pla72r-g-w-root`,
`pla72r-g-w-prec`, `pla72r-g2-off-1`, `pla72r-g2-nofp`, `pla72r-g2-prec`,
`pla72r-g2-root`, `pla72r-g2-combo`, `pla72r-g2-nb`, `pla72r-g3-off-a`,
`pla72r-g3-nofp-a`, `pla72r-g3-nofp-b`, `pla72r-g3-off-b`,
`pla72r-g-nb-count`. Every producer completed exit 0. The old experimental smoke
is listed above. Final committed-main installation and gate are recorded below.

## Final committed-main installation

Code/tests/probes/evidence committed as `ecd6c15`; no default switch changed.
Rebuilt its committed app sources, **excluding the foreign SettingsView edit**:
its exact bytes were saved under the build area and restored byte-for-byte after
the build. No generated build-record row changed. The final verified dev IPA is
`b9acbe707087c29368d829c58d5e10048d316d6dd89561fd0ec437fa76ec3ecc`
(`out/20261023-045230-b9acbe70/Playport-26.5-b9acbe70.ipa` beneath the build area),
89 verification checks passed, 0 failed. Upgraded in place; container retained.

Final Hollow Knight gates (720/60, no experimental options), both successful:

| backend | run directory under build area | result |
| --- | --- | --- |
| Vulkan | ui-runs/20261023T045359 | first-frame+10 |
| DXMT | ui-runs/20261023T045454 | first-frame+10 |

The first smoke command had an invalid `pp ui --settings` argument (missing the
title-ID prefix), failed before launching the game, and was corrected; it was
not a failed game start or a duplicate play.

Final default-options native/free route-v2 run: `perf-runs/pla72r-final-off`,
exit 0; `graphicsOptions=[]` confirmed in the launch log. Window `85:125`:
78.7 FPS, p99 25.01 ms, GPU 11.29 ms, tiler 88.0%, 76.8 Mi/f,
CPU 252 mW, phone 54.3 mJ/f. Nominal start, pressure at 75 s, charge 80%,
external power. It ended at the same King's Pass cave as the original walking
Vulkan baseline, correctly rendered, with no Metal/compile errors. This is a
final correctness/performance check, not an optimization claim across IPAs.

Phone status confirms the final IPA and committed runtime `ecd6c15`. HUD was
returned to off through the UI; session-only settings were undone. Hollow Knight
remains installed, Portal 2 absent, RDR2 untouched; unattended mode renewed.
No push. A subsequent documentation-only commit records these final results;
the installed code is that committed main runtime. Compatibility/Linear updates
are left to the supervisor, with a machine-readable run/IPA inventory in
`$PLAYPORT_BUILD/agent-notes/pla72r/reports/W-gpt-runs.json`.

**Remaining limits:** no Portal 2 gate (kept uninstalled by this handoff), no
Vulkan float-controls CTS, no general proof of the experimental barrier or
robust-vector pass, no D3D12 parity/exit runs. Unsafe switches must remain opt-in.

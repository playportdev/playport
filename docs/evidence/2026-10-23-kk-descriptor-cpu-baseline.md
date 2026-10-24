# KosmicKrisp descriptor CPU baseline: preliminary menu observation

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **Plan:**
[Proton parity](../plans/finished.md#kosmickrisp-proton-parity), A0.
**Recommendation: INSUFFICIENT to authorize A2.** Two baseline profiles were collected,
but they do not establish descriptor cost in gameplay or resolve total descriptor CPU time.
A2–A4 remain **not started**, subject to the supervisor's decision. No implementation,
instrumentation, defaults, build, install, cache clearing, merge or push in this chunk.

## Build, settings and scene

Reused installed dev IPA:
`$PLAYPORT_BUILD/out/20261023-071927-5e3fc6a8/Playport-26.5-5e3fc6a8.ipa`, SHA256
`5e3fc6a89019ef10f054d3ce47f4191e0354ff5df66c73d65814d7fd0241da7d`.
Every perf/UI command used `--expect-ipa`; both final UI play results record that hash.
Starting branch/HEAD: `dev/kk-proton-parity` / `6abdf76`; main remains `26699f6`.

**Not an exact committed-source IPA:** it includes the protected owner's uncommitted
`app/Sources/S1Probe/UI/SettingsView.swift` edit, SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`.
File and binary diff match the inherited private snapshots before/after work; never changed,
staged, stashed or committed. Runtime unchanged from B1/B3 phone evidence.

Both runs: Hollow Knight (`app-367520`), Vulkan/Khronos, 720p, frame limit 60,
**empty graphicsOptions**, HUD off, CPU sampling on through Settings' supported Diagnostics,
other perf profiling/capture switches off, runtime counters on. No experimental flags:
DXVK client logs show descriptorBuffer, memoryPriority, pageableDeviceLocalMemory and
shaderModuleIdentifier all **0** on both routes. Backend-generated variables and the
supported sampling variable remain; no experimental/environment options were injected.

The readily available King's Pass scripts require New Game and progress. They were not used.
Instead, one **180-second main-menu baseline per route**, neutral scripted controller,
no buttons/movement/new save. No repeat. All four `shot-ff030.png` / `shot-ff150.png` images
show the same expected animated title/main menu, Start Game selected, without obvious
corruption. The +150 captures precede the stop events by **27.74 / 27.76 s** (DXVK/vkd3d).
They are live scene checks, not black stop captures. No gameplay relevance is asserted.

## Actual commands and retained artifacts

Used `PLAYPORT_BUILD=$PWD/.work` and
`TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp`. `pp` held the device lock for each run.
Foreground waits had a 900-second timeout; both producers returned **0**, uninterrupted.

```sh
./pp perf --out .work/perf-runs/kk-a0-dxvk-20261023 \
  --title app-367520 --secs 180 --shot first-frame+30 --shot first-frame+150 \
  --cpu-prof --no-hud \
  --pad first-frame+0:.work/agent-notes/kk-parity/a0-neutral-pad.txt \
  --settings '{"graphics":"vulkan","screen":"720","frameLimit":60,"arguments":"-force-d3d11","graphicsOptions":""}' \
  --expect-ipa .work/out/20261023-071927-5e3fc6a8/Playport-26.5-5e3fc6a8.ipa
```

Second command changes only `--out` to `.work/perf-runs/kk-a0-vkd3d-20261023` and
arguments to `-force-d3d12`. Neutral pad file is one `180000 -` step; no input.
Commands/full final events: `$PLAYPORT_BUILD/agent-notes/kk-parity/a0-{dxvk,vkd3d}.jsonl`.
Each run retains `argv.txt`, `run.json`, `ui-run.txt`, `run/events.jsonl`,
`run/pull/s1-host.log`, `this-launch.log`, `profile.txt`, `threads.txt`, `summary.json`,
power/thermal/GPU monitor files and the two scene screenshots. No screenshots/logs committed.

| Route | Final perf / UI play result | First frame from launch | All / retained steady samples | Thermal / battery |
| --- | --- | --- | --- | --- |
| DXVK, D3D11 | ok true, exit 0 / until first-frame+180 reached | 11.70 s | 9,766 / **8,840** | nominal throughout; 80% external power |
| vkd3d, D3D12 | ok true, exit 0 / until first-frame+180 reached | 11.36 s | 9,484 / **8,385** | nominal throughout; 80% external power |

Logs identify DXVK 3.1.1 / vkd3d-proton `567710d877bb3d4`, not a DXMT measurement.
The near-60-fps capped menu and first-frame times are descriptive, not a speedup comparison.

## What the sampler can actually count

Source inspected before collection: `tools/perf.py`, `tools/sampleprof.py`,
`patches/madeira-unix` 0028/0096 and current
`$PLAYPORT_BUILD/run/unix/mythic/build/ntdll-unix/server_ios.c:1979–2207`.

- Selects up to **six busiest threads**, each at least 5% of one core at selection;
  records only samples observed running. Not a census of all CPU time/threads.
- Nominal loop: **3,000 iterations**, `usleep(1000)`, then **15 s sleep** between bursts.
  Suspension, state reads, walking and description add overhead. Actual completed burst
  spacing here is **25.9–26.9 s**, not a demonstrated 1 kHz / 3-second wall-time capture.
  There are no retained per-sample timestamps or calibrated per-thread sample durations.
  **Do not multiply samples by 1 ms or extrapolate to descriptor CPU milliseconds.**
- Seven completed bursts per route. Exclude first burst (926 / 1,099 samples) as initial
  startup/menu-transition observation. No attempt to time compilation from that burst;
  the earlier startup/compilation is not comprehensively sampled.
- Retained bursts 2–7 end approximately +46, +73, +100, +127, +153, +180 s for DXVK;
  +46, +72, +98, +124, +150, +177 s for vkd3d, relative to the first `[frames] n=16`
  timestamp. These are line-order brackets, not per-sample times. Given the intervening
  15-second sleeps, these later bursts exclude the initial transition; they do not sample
  the entire intervening steady window continuously.
- Native per-thread leaves: at most **80 rows per burst**, capacity 500 keys; global leaf
  top 45/capacity 400. Thread-module top 60/capacity 120. Tables drop rows, not just names.
  `class` has capacity only eight keys per burst; it is not an exhaustive denominator.
- Printed percentages rounded to 0.1%. Analysis weights each row by its burst's exact
  sample total. Thus reconstructed row counts (`≈`) and percentages are approximate;
  an absent row means **unobserved**, not zero. Integer ranges below account for rounding
  in printed rows only, not omitted rows or threads.
- `pe-inclusive` is the **first PE frame** on a limited frame-pointer chain, not a full
  call tree; there is no per-thread-inclusive table. Chain longer than two frames observed
  in 5,425/8,840 and 5,117/8,385 retained samples; not proof every caller was recovered.
  Exclusive leaf and inclusive rows overlap and must **not be added**.

Symbolication uses staged `Runtime/vulkan/arm64ec-windows` DLLs, not DXMT's. IPA bytes match
staged d3d11, dxgi, d3d12, **d3d12core** and xtajit64 exactly. The signed KosmicKrisp differs
as a whole file, but all file-backed section addresses/sizes/bytes (including `__text`)
match staged framework sections; its local symbol offsets are usable. Proof:
`$PLAYPORT_BUILD/agent-notes/kk-parity/a0-symbol-binary-check.txt` (core/helper comparison
also recorded in analysis). PE/KK PCs are rounded down to **16 bytes**; nearest preceding
symbols need boundary checks, below. Proprietary game symbols are unavailable.

## Retained steady samples by thread

Denominator for “all” is **8,840 DXVK / 8,385 vkd3d running samples**, not whole-process
CPU time. Thread counts reconstructed from rounded percentages. Unnamed Wine threads
retain their sampler keys; the dominant one is main-like but **not independently identified
as the game's main thread**. Its native/helper and guest hotspots are reported without
inventing a Unity function name.

| Route / thread | Samples ≈ | % all | JIT samples ≈ (% thread) | Definite descriptor leaf samples ≈ (% thread) |
| --- | ---: | ---: | ---: | ---: |
| DXVK `w2443192` (dominant unnamed) | 3,866 | 43.7 | 2,917 (75.5) | no printed row |
| DXVK `dxvk-cs` | 1,651 | 18.7 | 3 (0.2) | **7.6 (0.46)** |
| DXVK `w2443239` (unnamed) | 1,183 | 13.4 | 1,166 (98.6) | no printed row |
| DXVK `UnityGfxDeviceWorker` | 1,047 | 11.8 | 799 (76.3) | no printed row |
| DXVK `m2443296` (native) | 497 | 5.6 | no printed row | no printed row |
| vkd3d `w2449116` (dominant unnamed) | 3,778 | 45.1 | 2,887 (76.4) | no printed row |
| vkd3d `UnityGfxDeviceWorker` | 2,519 | 30.0 | 1,109 (44.0) | **4.2 (0.17)** |
| vkd3d `w2449175` (unnamed) | 1,102 | 13.1 | 1,083 (98.3) | no printed row |
| vkd3d `m2449171` (native) | 434 | 5.2 | no printed row | no printed row |
| vkd3d `m2449459` (native) | 160 | 1.9 | no printed row | no printed row |

Hotspots (each percentage uses that **thread's** reconstructed sample denominator):
DXVK CS: AGX `<redacted>` **25.3%**, kernel `kevent_id` **19.2%**.
DXVK render worker: Unity block `+8e3f00` **18.4%**, `__ulock_wait2` **17.7%**.
vkd3d render worker: AGX `<redacted>` **11.7%**, `kevent_id` **7.0%**, Unity block
`+949e00` **5.8%**. Dominant unnamed threads: generic JIT **24.6/26.9%**, Unity block
`+15a400` **5.3/4.4%** (DXVK/vkd3d); native leaves include `swtch_pri` and symbolized
xtajit64 tree/map helpers. This does not attribute those waits/helpers to descriptors.
Native `m…` workers show IOKit traps/workqueue returns; no deeper driver meaning inferred.

For context, CS thread-module rows include KK ≈114.5 (1.30% all), d3d11 ≈156.9 (1.77% all).
vkd3d render worker includes KK ≈115.4 (1.38% all), d3d12core ≈105.8 (1.26% all).
These are **whole-module**, not descriptor costs or complete upper bounds.

## Descriptor rows, definitions and ambiguity

These are **exclusive per-thread leaf** rows, checked against the actual symbol ranges.
Source paths below are under `$PLAYPORT_BUILD/run/`; no new instrumentation was added.

| Route / leaf | Rounded-count-compatible samples | Weighted estimate | % all |
| --- | ---: | ---: | ---: |
| DXVK CS: `DxvkDescriptorPool::alloc` | 1–2 | 1.39 | 0.016 |
| DXVK CS: `DxvkContext::updateDescriptorSetsBindings` | 1–2 | 1.61 | 0.018 |
| DXVK CS: `kk_UpdateDescriptorSets` | 1–2 | 1.61 | 0.018 |
| DXVK CS: `kk_CmdBindDescriptorSets2KHR` | 1–2 | 1.55 | 0.017 |
| DXVK CS: `kk_AllocateDescriptorSets` | 1–2 | 1.47 | 0.017 |
| **DXVK definite printed leaf sum** | **5–10** | **7.62** | **0.086** |
| vkd3d render: `kk_UpdateDescriptorSets` | 1–2 | 1.39 | 0.017 |
| vkd3d render: `d3d12_command_list_update_descriptors` | 1 | 1.22 | 0.015 |
| vkd3d render: `kk_CmdBindDescriptorSets2KHR` | 1–2 | 1.56 | 0.019 |
| **vkd3d definite printed leaf sum** | **3–5** | **4.17** | **0.050** |

Attribution:
- `vulkan-pe/dxvk/src/dxvk/dxvk_descriptor_pool.cpp:24–69`: allocates descriptor sets.
  `dxvk_context.cpp:7114–7300`: collects dirty bindings, allocates/updates sets, including
  update templates; `dxvk_cmdlist.h:553–571` calls the Vulkan update functions.
- `mesa/hosttest/mesa/src/kosmickrisp/vulkan/kk_descriptor_set.c:278–382,670…`:
  writes/copies descriptor bytes and allocates sets. `kk_cmd_buffer.c:653–738` binds root
  set addresses/state. These are descriptor CPU operations, not shader descriptor loads.
- `vulkan-pe/vkd3d-proton/libs/vkd3d/command.c:8212–8265`: updates descriptor heaps,
  static samplers, root descriptors/constants/table offsets. The sampled function is
  **not** `CopyDescriptors`. `device.c:6502…` routes `CopyDescriptorsSimple_default` to
  descriptor-copy helpers; `resource.c:5095–5260` batches Vulkan descriptor copies.
  **No CopyDescriptors/copy-helper leaf or first-PE-inclusive row was captured** on either
  the initial or steady vkd3d tables. This cannot establish zero copy cost.

Two extra bins are **excluded** from the definite sums:
- DXVK CS `KosmicKrisp+c2d20`: ≈1.47 samples (1–2), 0.017% all / 0.089% CS.
  Nearest symbol `kk_CmdPushDescriptorSet2KHR`, but the 16-byte bin also includes
  `kk_CmdPushConstants2KHR` beginning at `c2d28`.
- vkd3d render `KosmicKrisp+d04e0`: ≈1.42 samples (1–2), 0.017% all / 0.056% render.
  Nearest symbol `kk_GetDescriptorSetLayoutBindingOffsetEXT`, but the bin includes
  `kk_UpdateDescriptorSets` beginning at `d04ec`. **Not evidence of descriptor-buffer use.**

Metal `mtl_render_pass_*descriptor*` matches are render-pass attachment objects, **not Vulkan
resource descriptors**, and are not counted. No free/reset descriptor rows printed.
No global-leaf `vkUpdateDescriptorSets*`/descriptor family row survived top-45 reporting;
per-thread top-80 rows above provide the actual observations.

DXVK first-PE-inclusive has `updateDescriptorSetsBindings` ≈1.61 / 8,840 (**0.018% all**).
No descriptor-specific vkd3d first-PE row printed. Do **not** add DXVK's inclusive row to
its exclusive rows, or invent a per-thread-inclusive total from this global table.

## Coverage, conclusion and next decision

Thread-module JIT share: **≈4,888 / 8,840 (55.3%) DXVK**, **≈5,079 / 8,385 (60.6%) vkd3d**;
these translated guest samples are not function-resolved descriptor attribution.
Additional visible native leaves with redacted/unresolved names: **≈679 (7.7%) / ≈540 (6.4%)**.
Thus roughly **63.0% / 67.0%** already lacks useful leaf-function attribution in these
categories alone; not a complete unresolved census. Top-N/storage omissions and limited
unwinding leave further gaps. Thread-module row sums cover 98.35% / 97.97%; global leaf
70.82% / 66.99%; first-PE-inclusive 25.24% / 36.54% (all subject to rounding/truncation).
The class table covers only 83.80% / 85.76%, so treating its remainder as zero is wrong.

**High confidence:** the menu rendered on both baseline routes with flags off; a few
native descriptor operations were sampled, on the expected CS/render workers.
**Low confidence / insufficient:** total descriptor cost, CopyDescriptors cost, any gameplay
bottleneck or predicted A2 benefit. Tiny *printed* fractions do not bound omitted calls,
inline work, caller-attributed memcpy, unsampled threads or JIT work. The current sampler
cannot answer the full A0 gating question; no repeated campaign or profiler redesign was
attempted. A0 has a preliminary baseline artifact, **not a satisfied A2 justification gate**.

Proposed next action for the supervisor: keep A2 gated and decide whether to defer it or
separately approve a representative existing-save workload and/or an attribution method
with usable stack/guest coverage. No such follow-up or implementation is authorized here.
No single-run improvement claim, default promotion, or inference about other games.

Offline reuse: `$PLAYPORT_BUILD/agent-notes/kk-parity/a0-analyze.py`, `a0-accounting.json`,
`a0-accounting-summary.txt`, `a0-descriptor-symbols.tsv`; each perf directory also has
`profile-all-rows.txt` / `profile-steady-all-rows.txt`. The script uses existing sampleprof,
retains all **logged** rows and excludes first burst; it cannot recover dropped rows.
An extracted steady log must retain/prepend `title: graphics: vulkan`, otherwise sampleprof
would default to DXMT DLLs. `python3 …/a0-analyze.py` reproduces these tables without a phone.

Restoration: read-only UI `20261023T084251` confirms default Vulkan/720p/60, arguments None,
Graphics options None and Runtime keys None; inherited controls retained. UI
`20261023T084524` confirms CPU sampling/pass profiling/capture/validation **off**, runtime
counters **on**, HUD **off**, then explicitly opens/captures the black page. No further game
launch. Session settings undone, no keep-settings. Phone after: 80% external power, not
charging, 6.1 GB free. Inherited unattended expiry **2026-10-23T17:44:05+02:00** unchanged,
not renewed/toggled. Last captured screen black; persistent visibility after harness rest
is not independently sampled. Status logs are private `a0-status-{before,after}.log`.

Validation: `pp test --quick`, `pp names`, `pp secrets`, owned-doc whitespace/exact-path
staged review and protected owner-file/diff comparisons passed. Only this evidence and
plan/index updates committed. Supervisor owns PLA-431 and Hollow Knight PLA-42/site updates:
**menu-only baseline observation**, not replacement of historical best-known gameplay.

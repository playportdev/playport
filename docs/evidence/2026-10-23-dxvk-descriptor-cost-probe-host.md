# DXVK descriptor elapsed probe — host only

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **Plan:**
[Proton parity](../plans/2026-10-22-kk-proton-parity.md), A0 queue item 2.
DXVK **0006**, `Class: diagnostics`, default disabled. Independent review pending.
No phone/install/UI/perf commands, game runs, CPU attribution or A2 authorization.

## Payload and activation

`PLAYPORT_DESCRIPTOR_STATS=1`, through existing dev Graphics options; the environment
is read once per device. No Swift, driver entrypoint, configuration default, pin,
feature-selection, shader-generation, MSL or explicit cache-key change. Other values
leave the probe disabled. Source payload is `src/dxvk/`:
`dxvk_context.cpp`, `dxvk_descriptor_pool.cpp`, `dxvk_cmdlist.{h,cpp}`,
`dxvk_device.{h,cpp}`, new `dxvk_descriptor_stats.{h,cpp}`, and its `meson.build`
source entry. Supervisor approved the constructor-only command-list `.cpp` wiring
and out-of-line helper/build entry. Delivery is format-patch plus series, not the
scratch source checkout. Initial source commit `94967e6`; build reconstructed the
same patch as `4e767ca`. Command lists cache their existing owning device's pointer;
no cross-device pointer copying or new ownership edge.

Device diagnostics are constructed before resources and destroyed after them, including
constructor failure unwinding. Orderly final reporting follows resource/pool teardown;
DLL process detachment abandons reporting instead of claiming an orderly final.
Descriptor scopes allocate no memory, acquire no mutex and register no threads.
Enabled scopes use a **32-entry same-thread TLS stack**; the small RAII handle passes
values, not its address, to the real out-of-line helper. Depth overflow and mixed-device
nesting invalidate the affected scope/ancestors explicitly, without changing operations.

## Coverage and additive contract

Operations: `prep`, `spec_data_excluded`, `pool_alloc`, `pool_recycle`, `pool_destroy`,
`vk_allocate`, `vk_pool_create`, `vk_reset`, `vk_pool_destroy`, `vk_update`,
`vk_template`, `vk_bind`. Each has three fixed rows: `category=prep`, `standalone`,
`excluded` (**36 rows per complete snapshot**, including zero rows).

- `prep`: the complete legacy `updateDescriptorSetsBindings` source region, including
  dirty-mask evaluation, array resizing, binding preparation/copies, tracking, allocation,
  update and bind. Its independent-set specification-data/constants tail is a nested
  `spec_data_excluded` subtree, including that tail's allocation/update/bind plumbing.
- Pool allocation times only the leaf overload. Wrapper overloads do not triple-count
  the same allocation. Its nested create/allocate attempts, including failed attempts,
  are separate direct children. Recycling includes existing collection/locking and
  nested reset calls; pool destruction includes nested Vulkan destroys. Bulk-overload
  traversal outside a selected outer scope is not separately covered.
- Direct Vulkan scopes cover only calls through these named wrappers, not every Vulkan
  descriptor call in the process. Standalone rows may include internal/meta operations;
  they are not automatically descriptor-buffer-removable work. Render-pass descriptors,
  shader costs, push constants, layout/template lifetime, descriptor-buffer and heap
  preparation paths are not added to the covered legacy opportunity.

For each **valid completed scope**, `exclusive_ticks = inclusive_ticks -
direct_child_ticks`. Children are measured on the same thread and clock, not obtained
from independently published totals. Invalid children invalidate ancestors' timing;
no fabricated exclusive is published. Repeated same-helper recursion is supported.
`thread_sum_outer_elapsed_ticks` advances only on scopes with no instrumented parent.
It is an outermost **sum across threads**, not a process-wall union or CPU time, and
can exceed the observation window. Inclusive parent/child columns overlap: **do not
add them**. Sum exclusive columns across rows for disjoint attribution. In particular:

- Sum all `prep`-category exclusives for the covered broad legacy envelope **excluding
  the specification-data subtree**. Separate non-Vulkan exclusives from `vk_*`
  exclusives for client preparation/allocation versus nested Vulkan attribution.
- Keep standalone and excluded categories separate. Do not add a parent's inclusive
  or outermost total again to its children's exclusives. Raw `prep.inclusive_ticks`
  includes its excluded tail and can also overlap recursive prep calls.
- This is a **broad candidate envelope**, not a removable-time estimate: tracking,
  lifetime work, implicit resolve preparation and diagnostic overhead can remain even
  with a different descriptor representation. There is no exported removable-CPU total.

[KK's replay correction](2026-10-23-kk-descriptor-cost-probe-host.md#replay-correction-host-only-pla-431)
remains binding: native counts are driver executions. Secondary execution/reusable-primary
replay may occur outside client prep regions. Keep **uncovered native/replay coverage
separate**. Never subtract windowed KK totals to invent client exclusives, require
native/client count parity or containment, or add KK elapsed to overlapping client totals.

## Schema and validity

Every record begins `[dxvk-descriptor] v=1 component=dxvk kind=...`.
Kinds: `enabled`, 16 bounded `calibration` records, `snapshot`. Identity:
`pid`, `module` (in-process diagnostic generation-storage address, disambiguating PE
DLL copies), `device` generation, `init_ticks`, `init_ok`, `hz`. The enabled banner
also names `clock_kind`, coverage/exclusions, summed-thread/nontransactional semantics
and `cpu_clock=unsupported`. All telemetry numbers are cumulative integers/raw ticks.
Each snapshot row adds:

```
snapshot ts_begin ts_end client_submission_requests final clock_ok
report_clock_errors overflow quiescent entered_before completed_before
entered_after completed_after op category
calls completed sets write_records write_elements write_bytes prepared_slots
dynamic_offsets failures empty_dirty_mask work_unknown timed_calls
inclusive_ticks direct_child_ticks exclusive_ticks max_ticks
thread_sum_outer_elapsed_ticks clock_errors nest_errors active
```

`prepared_slots` counts flattened legacy client slots. Normal updates count actual
write records/elements; inline-uniform counts, if passed to the wrapper, are bytes,
not elements. Template updates from prep know elements, but not retained template-entry
cardinality: `write_records=0`, `work_unknown` advances. Other template-wrapper callers
have unknown entry/element cardinality, explicitly flagged rather than traversed or
invented. `sets` means prep dirty sets, leaf requested allocations, requested allocation
attempts, bind inputs, template target sets, or pool-create capacity according to `op`.
Reset/destroy do not claim a live-set traversal count. `empty_dirty_mask` does **not**
promise no work: resizing or excluded specification-data work may still occur.
`failures` counts failed Vulkan result attempts and exception-unwound scopes, separately
at each nested layer; those failure counts are not an additive API-failure oracle.

The denominator is **client submission requests accepted by DXVK's submission queue**,
not presents, frames, completed GPU work or actual Vulkan submits. Reports occur on the
first request, about once per second on subsequent requests, and orderly final teardown.
No requests means no periodic report. Presented-frame denominators must come from the
existing frame logs later; none are invented here. Logger suppression or a killed tail
means missing output, never zero work. Failed/backwards report clocks emit one snapshot
per failure episode plus final, not one per request. A partial log lacks a complete
snapshot until all 36 distinct rows with one identity/serial/bracket are present.

Windows uses the same QPC primitive as `util_time.h`, but checks QPC and cached QPF
results directly (the existing convenience wrapper ignores failures). Raw ticks avoid
conversion overflow. Host uses checked `CLOCK_MONOTONIC`, including checked timespec
conversion. Host timing is **not** Windows/iOS clock-resolution evidence. Frequency
failure, failed/backwards clocks, child invalidity and counter saturation are explicit;
valid equal timestamps remain quantized valid measurements, not proof of zero work.
Counter/publication/serial saturation sticks `overflow=1`, without wrapping identities.

Counters are atomic; entered/completed publication brackets capture. `quiescent=1`
means unchanged equal publication counts **during counter capture**, not an event-time
transaction. Calls count entries; timed durations count valid completions. Other captures
can mix publication stages. Timestamps bracket the capture; events at either edge can
belong to adjacent deltas. Active scopes have no finite duration bound from a previously
completed maximum. Missing rows, active/concurrent captures, overflow, clock/nesting
errors and absent orderly tails must be rejected or explicitly bounded by later parsing.
Final reporting does not override invalidity. Per-thread rows were explicitly withdrawn
by the supervisor: there is no registry/cap on measured threads, and no per-thread CPU
attribution can be recovered from the aggregate.

Calibration records contain six raw checked reads per sample: adjacent timestamps,
the exact enabled empty RAII scope's timestamps, and an external empty-path bracket
including its TLS/counter publication. Each pair has its own validity flag. Scratch
counters do not contaminate device totals. Nothing is subtracted. Elapsed can include
waiting/preemption and diagnostic overhead; a positive value alone does not justify A2.

## Host validation and artifact

Using `PLAYPORT_BUILD=$PWD/.work`,
`TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp`, bounded foreground producers:

- Real helper fixture: `build/dxvk-descriptor-test/run.sh`; **passed**. Deterministic
  nested/direct/standalone/excluded/repeated regions; exact work/ticks/exclusives;
  empty/quantized scopes; early return/exception; start/end/child clock failure,
  backwards/noncontained timestamps, timespec conversion overflow/invalidity, zero
  frequency, saturated work/elapsed, active and concurrent capture, depth overflow,
  mixed-device invalidation, two-thread/two-device isolation, serial/identity,
  first/1-Hz/failure-suppressed/final reports and valid/invalid raw calibration.
  Disabled mode reads no clocks and publishes nothing, including inside an enabled
  parent. Logger exceptions do not escape. Same fixture with ASan+UBSan **passed**.
- Full existing Mesa host runner **passed**, including helper/API/replay and Zink.
  **236/236** off/on MSL files identical, each arm also **236/236** byte-identical
  to its saved pre-DXVK arm; existing default flags preserved; Zink **25** files.
  No GPU executes. No DXVK Vulkan integration execution was performed.
- Optimized host `-O2` guard and production ARM64EC `-O3` actual context/pool objects,
  actual inline update/template/bind wrappers and guard inspected. Disabled branches
  bypass diagnostic clock/TLS/atomic/logging and work-count traversal. Existing
  reference-count atomics/operation work remain. Initial host inspection caught
  compiler stack-canary TLS induced by address-taking RAII state; final fixed-TLS
  state/value-handle design removed it. Initial GCC attribute-only compile failures
  preceded the out-of-line helper; warnings were not suppressed. This is static
  path inspection for these builds, not zero-instruction/layout/cache overhead proof.
- `./pp build`: **exit 0**, dev IPA **89 passed, 0 failed**. Exactly seven actual DXVK
  DLL rows changed in `app/artifacts.tsv`; generated Wine PE manifests unchanged.
  Existing verification ran for dev. Fresh release-specific executable contamination
  checks were **not run** (no release IPA built; no Swift/driver files added).
- `./pp test --quick`: **712 Python tests, 26 C groups passed**; Swift intentionally
  omitted. `./pp names`, `./pp secrets`: clean. Source/addition whitespace and exact
  owned-path/private-path review passed; format-patch's canonical blank context lines
  are not source whitespace changes. Protected owner snapshot and diff compare equal.

Verified IPA:
`$PLAYPORT_BUILD/out/20261023-104300-0bc7e996/Playport-26.5-0bc7e996.ipa`
SHA256 **`0bc7e996fbd8a55bf7a43d9c4b7fe5b36a4dffb2cedeef4fc041d02a69f2c331`**.
**Not exact committed-source provenance:** includes the owner's protected/uncommitted
SettingsView edit, file SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`, diff SHA256
`3e371c630d659be316befde9e60824ae0a4be12f44a52084d1595740532ea7b9`.
It remains unchanged, unstaged and uncommitted. No unrelated session changes included.

Logs/artifacts under `$PLAYPORT_BUILD/agent-notes/kk-parity/`:
`a0-dxvk-{helper,helper-sanitized,mesa-host,build,quick,names,secrets}.log`,
`a0-dxvk-{disabled-host,guard-arm64ec,wrappers-arm64ec,pool-arm64ec,context-arm64ec}.asm`;
failed early compiler logs retained separately. Host fixture sample rows/calibration are
not iOS overhead, Vulkan-execution or performance results.

**Next:** independent review, then separately authorized vkd3d writer, parser/integration
review, owner-selected scene/budget and device calibration/off-on controls, then human
existing-save gameplay. Device calibration, runtime smoke and gameplay are **UNRUN**.
A2 remains gated; no next component was started.

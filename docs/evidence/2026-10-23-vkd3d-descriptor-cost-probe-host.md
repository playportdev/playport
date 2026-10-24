# vkd3d descriptor elapsed diagnostics — host only

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**2026-10-23; independent review pending.** Default-off diagnostics, not descriptor
buffers, CPU attribution or a performance result. No phone/install/UI/perf/game
commands. Existing menu observations remain inconclusive; A2 remains gated.

## Delivery and build identity

- `patches/vkd3d-proton/0005-vkd3d-descriptor-cost-diagnostics.patch` plus series;
  canonical format-patch, diagnostics/evidence/no-upstream trailers. Source commit
  `856e24c50b18e41630ae0cfaef7cd592bd638f6c` was committed and formatted before
  `pp build` reconstructed it as `319255a4aa1bc0de2b0ad07d1abd53489bbd9f9d`.
  Both trees are `bd7ce891cd18cf14cb0aa4dce55dcbf095cb56ca`; comparison is empty.
- Payload: `libs/vkd3d/{command.c,device.c,resource.c,vkd3d_private.h,
  vkd3d_descriptor_stats.h,vkd3d_descriptor_stats.c,meson.build}`. Meson adds only
  the real helper source. No other series, pins, defaults, capabilities, shaders,
  cache keys, bridge, app configuration API or profiler change.
- Dev IPA: `.work/out/20261023-150040-74c0d54e/Playport-26.5-74c0d54e.ipa`.
  SHA256 **`74c0d54e668570a320a11bf6e8e7c6aef46d42fb101f4d1aa0531b63408234b1`**.
  `pp build` exited 0, **89/89 verification checks**.
- Exactly one generated record changed: `app/artifacts.tsv`, arm64ec
  `d3d12core.dll`, 6,406,144 bytes, SHA256
  `a98a68c2fa132b8ea410f7d857f231ec4977c781ade5a18f9afe41a70b64a6cc`.
  No generated Wine manifest, other vkd3d/DXVK/Mesa artifact row changed.
- The IPA includes the owner's uncommitted SettingsView edit: file SHA256
  `14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`,
  diff SHA256 `3e371c630d659be316befde9e60824ae0a4be12f44a52084d1595740532ea7b9`.
  Byte comparison against the protected snapshot passes; never staged or committed.
  This is **not** an exact committed-source IPA. No installation was performed.

## Activation, lifetime and disabled path

Existing Graphics options `PLAYPORT_DESCRIPTOR_STATS=1`; exact value, cached once
on successful device initialization, after the existing vtable selection. Disabled
calls branch on the optional owning-device pointer before diagnostic TLS/clocks,
atomics, logging or work traversals. Fixed embedded per-device aggregates, enabled-only
32-entry same-thread TLS stack; no diagnostic thread registry/cap, scope allocation
or mutex. A scope ends explicitly once on every selected C return path. General-copy
helpers and Simple fallback delegation do not start duplicate API scopes.

The zeroed device allocation leaves the optional pointer null throughout failed
initialization. Successful diagnostics initialize before publishing that pointer;
normal device destruction reports after teardown then clears it. Stack entries are
popped on scope end; no thread registration holds stale device pointers. Snapshot
publication uses an atomic try-guard, not a hot-scope lock. Existing logger locking
and report formatting are enabled-only diagnostic overhead.

**Compiler/security overhead qualification approved by supervisor:** optimized distro
GCC and clang fixtures both perform stack-canary `%fs:0x28` TLS accesses before the
pointer guard because scopes use address-taken stack locals. This is
**instrumentation-induced compiler/security/prologue overhead**, not original work
or diagnostic TLS. Normal security flags were preserved; no canary suppression or
noinline-everywhere workaround. Actual production ARM64EC and i386 object inspection
shows guards before diagnostic calls, with no diagnostic TLS/clocks/atomics on the
disabled branch. Added stack allocation/zeroing, spills, branches and layout effects
remain; this is not a literal zero-instruction-overhead claim.

## Source-backed coverage and work definitions

1. `d3d12_command_list_update_descriptors`: graphics/compute/other broad preparation
   envelope including dirty tests, bindings, hoisting, root/table work, allocation,
   tracking and combined root-constant UBO data. Separate root-constants/redzone
   subregions and their descendants are `excluded` where separable. Combined UBO,
   raw root VA/table push data and tracking remain **ambiguous/non-fully-removable**.
   `dirty_root_slots` is the entry dirty-root mask population, not actual descriptor
   elements. `table_slots` is the root signature's declared table count per invocation,
   not dirty tables or table descriptor cardinality; `work_unknown` marks the gap.
2. General CopyDescriptors plus all **eight actual Simple implementations** are
   instrumented without changing the replacement function or vtable declarations.
   Those original selection bytes compare identical; every original `device.c` line
   remains in order. Simple implementations: `default`, `descriptor_buffer_16_16_4`,
   `descriptor_buffer_64_64_32`, `embedded_64_16_packed`, `embedded_32_16_planar`,
   `embedded_32_32_planar`, `embedded_128_32_planar`, `embedded_generic`.
   Original cached/non-temporal/single/range copy shapes and profiling selection are
   retained. No existing broad API profiler was enabled.
3. General `dst_ranges`/`src_ranges` are raw supplied range counts. No diagnostic loop
   reads unused ranges. Their requested total elements remain **unknown**, explicitly
   flagged, not zero. Simple has one range each and `requested_elements=descriptor_count`.
   `processed_elements` counts actual common-loop chunks or the selected Simple path,
   exactly once, not delegated helper calls. Heap type is explicit in API operation
   names: resource=CBV/SRV/UAV (0), sampler (1), RTV (2), DSV (3), unknown=other.
   RTV/DSV are separate **excluded/noncandidate** operations, not descriptor-buffer work.
4. `metadata_bytes` counts source copy/assignment sizes: legacy view/types plus
   conditional raw VA and buffer-range metadata, or planar embedded metadata when
   actually present. RTV/DSV count their copied structure size. `payload_bytes` counts
   explicit optimized/embedded copy bytes; packed resource metadata is included in
   the same payload and must not be counted again. These are source copy byte counts,
   not memory-bus traffic or recoverable instructions. Legacy mapped host-copy-template
   calls have `mapped_copy_calls` and **unknown payload byte size**, flagged by
   `work_unknown`; a zero payload byte counter is not a zero-copy claim. Work-unknown
   counts may combine cardinality/byte gaps, not quantify their missing magnitude.
5. Chosen direct Vulkan calls: legacy copy `vkUpdateDescriptorSets` (copy records and
   actual descriptor elements); descriptor set bind (one set per call); root push
   descriptor writes (each record has one element); selected descriptor-buffer/heap
   binds/offsets and raw-VA/table/constants push calls (`vk_other`, cardinality unknown).
   These are immediate same-thread children of selected scopes; calls in the shared
   global-heap helper can also be standalone. There is no descriptor-set allocation
   call in this selected source subtree. Other resource/layout/pool lifetime,
   internal/meta work, global memcpy, shaders and nonselected Vulkan calls are not a
   complete-process attribution. Standalone work is not automatically removable.

The enabled banner compares the **actual installed vtable's Simple function pointer**
and emits `copy_simple_path` plus `uncovered_selected_copy=0|1`. A recognized path has
coverage; unrecognized/profiler wrappers are explicitly uncovered, not guessed.
No Vulkan execution was performed here, so the running device's selected path is
**unobserved**. Legacy non-descriptor-buffer configurations select `default` by the
unchanged source; do not mistake that conditional source fact for a runtime banner.

## Nesting, additivity and validity

Within a thread, a child must start at/after its parent start and greatest previous
sibling end, end within its eventual parent, and leave summed immediate child ticks
no greater than parent elapsed. Greatest child end never moves backwards. Equal
quantized timestamps are valid, not proof of zero work. Bad clocks, child timing,
overflowed depth, mixed devices and containment errors invalidate ancestry and
publish errors. Locally completed earlier children are not retroactively erased;
**operation errors override an otherwise quiescent/valid snapshot**.

For valid completed scopes: `elapsed=end-start`, `exclusive=elapsed-direct_children`.
Only an outermost scope contributes `thread_sum_outer_elapsed_ticks`. Parent and
child inclusives overlap: **do not add them**. Sum exclusives for disjoint attribution,
keeping prep, standalone and excluded categories separate. Descendant exclusions
inherit. Aggregate thread sums can exceed observation wall time; no thread rows,
CPU time, wall union or recovered instruction cost is claimed. Native elapsed is
already inside measured direct Vulkan calls: never add native totals again or
subtract independently windowed native values. Native KK counts **driver executions**,
including secondary/reusable-primary replay outside client scopes; no native/client
invocation-count parity or containment assumption is valid.

## Clock, reporting and parser handoff

Windows uses checked `QueryPerformanceCounter` and module-once cached valid
`QueryPerformanceFrequency`, the same primitive as vkd3d's convenience timer but
without ignoring failures. Raw ticks and frequency are retained. No fallback makes
failed reads into valid zero durations. Host uses checked `CLOCK_MONOTONIC`, labeled
`host_clock_monotonic`, **not** Windows/iOS precision proof. Initialization and clock
failures do not change rendering results. Sixteen calibration rows retain raw adjacent
reads and actual enabled empty-scope/publication brackets, six reads/sample, isolated
scratch counters, validity flags, and no guessed subtraction. Phone calibration,
effective precision and on/off perturbation remain **UNRUN**.

Prefix: `[vkd3d-descriptor] v=1 component=vkd3d kind=enabled|calibration|snapshot`.
Identity on every row: `pid module device init_ticks init_ok hz clock_kind`. Module
is the address of DLL-local generation storage; device generations distinguish
lifetime reuse. Snapshot sequence identifies **54 required rows** (18 operations ×
`prep,standalone,excluded`), even if an operation was not invoked:

```
prep_graphics prep_compute prep_other
copy_resource copy_sampler copy_rtv copy_dsv copy_unknown
simple_resource simple_sampler simple_rtv simple_dsv simple_unknown
spec_data_excluded vk_update vk_bind vk_push vk_other
```

Each cumulative integer row carries:

```
snapshot ts_begin ts_end client_execute_requests final clock_ok quiescent overflow
report_errors entered_before completed_before entered_after completed_after
op category calls completed dst_ranges src_ranges requested_elements processed_elements
metadata_bytes payload_bytes mapped_copy_calls sets records vk_elements dirty_root_slots
table_slots work_unknown failures timed_calls elapsed_ticks direct_child_ticks
exclusive_ticks max_ticks thread_sum_outer_elapsed_ticks clock_errors nest_errors active
```

Publication is approximately 1 Hz at **client ExecuteCommandLists requests**, including
zero-list/failed requests, plus orderly final device destruction. That denominator
is neither frames, GPU submits nor GPU completions; frames come from existing logs.
Capture rows use relaxed atomic loads bracketed by entered/completed publication
counters and checked times. It is **nontransactional**: require the whole identity/
sequence/row set, reject or explicitly bound active/concurrent/inconsistent intervals,
check initialization, overflow, report/operation errors and timed/completed counts.
Never let `quiescent=1 clock_ok=1` override operation errors. Missing/suppressed/killed
rows or the tail mean missing data, not zero work.

INFO is not removed by `VKD3D_NO_TRACE_MESSAGES`; normal default logging threshold
FIXME includes INFO. No broad logging change. Suppression is detected as callback
failure internally; the existing void logger cannot acknowledge buffered/file I/O
failure, so collection still requires complete interior snapshots. Logger failure
injection tests the real helper callback boundary, not OS I/O. No per-call logs,
parser, runtime activation channel, sampler or thread-CPU bridge was added.

## Host validation

- `build/vkd3d-descriptor-test/run.sh`: real production helper, deterministic clocks,
  nesting/exclusions/standalone/repeated wrappers/work counts, early-return/end-once,
  threads/devices, depth/mixed-device/clock/frequency errors, saturation, calibration,
  logger callback failure, active/backwards capture and valid equal timestamps pass.
  Built ARM64EC d3d12core also retains enabled/snapshot/banner strings despite trace
  compilation being disabled.
  Both original reviewer sibling traces and deeper/failing-read variants reject.
  GCC and clang pass; ASan/UBSan pass with bounded execution.
- Full real ARM64EC build and independent scratch i386 meson/ninja build pass.
  Final changed C compilation has no new warning; upstream C++ warnings remain.
  Actual optimized object inspection covers prep, default/optimized Simple and
  resource-copy guards on both architectures, plus separate helper TLS/clock code.
  Distro GCC/clang compiler-canary limitation is disclosed above, not hidden.
- Reconstructed helper rerun passes. Explicit checksum/staged-DXMT/notices IPA
  verification passes **88 checks**, zero failures; the build's **89th** check also
  compares the previous IPA's provisioned device (offline; no phone access).
- `pp test --quick` passes: **712 Python tests / 26 C test groups**, including
  patch/trailer, pin, name and secret gates. Explicit `pp names` and `pp secrets`
  are clean. Exact ten-path staging allowlist excludes the owner file. Owned
  source/nonpatch whitespace and home/private-path checks pass. Unfiltered staged
  `diff --check` flags canonical format-patch blank context/signature lines (saved
  diagnostic, not source whitespace); regenerated canonical bytes compare equal
  and source commit additions pass `diff --check`. The patch was not hand-trimmed.
- Mesa host/MSL suite and DXVK fixture suites were **not rerun**: their source and
  artifact rows did not change. Inherited accepted results are not new validation.
- Real Vulkan/descriptor-copy integration semantics, Wine QPC failure integration,
  device calibration, phone smoke and gameplay are **UNRUN**. Compilation/source
  selection identity is not behavioral proof.

Next: independent review, then separately assigned parser/integration; only afterward
owner save/scene/activity/window/budget coordination, calibration/controls and bounded
human gameplay. No A2 authorization follows from these host diagnostics.

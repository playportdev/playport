# 0160: KosmicKrisp's Proton-parity features stay opt-in; descriptor buffers wait

**Status:** accepted, 2026-10-24, by the owner
([PLA-431](https://linear.app/playportdev/issue/PLA-431);
[plan outcome](../plans/finished.md#kosmickrisp-proton-parity)). The plan's delivered
work is complete. Deferring A2–A4 is a prioritization choice, not a measured
negative result or rejection of descriptor buffers. This confirms
[0158](0158-kk-gpl-stays-experimental.md), not a promotion of GPL.

## Decision

- **Features stay off by default.** `memory_priority` (Mesa 0119,
  `VK_EXT_memory_priority` + `VK_EXT_pageable_device_local_memory`),
  `module_identifier` (Mesa 0120, `VK_EXT_shader_module_identifier`) and `gpl`
  remain behind their separate `MESA_KK_EXPERIMENTAL` names. No compatibility
  entry or dev/release default enables them. A dev build can opt in through
  Graphics options ([0137](0137-graphics-options-set-any-variable.md)); release
  ignores that row.
- **The wineserver fix ships unconditionally.** Madeira-unix 0221 preserves
  queried fd-status flags when adding `O_NONBLOCK` to an imported shared open
  file description. This is a bug fix, not an experimental feature: importing
  fd2 over `SCM_RIGHTS` must not clear the log's `O_APPEND`. If `F_GETFL` fails,
  retain the old non-blocking fallback; unknown flags cannot then be preserved.
  The diagnostic emitter still rejects a non-append regular sink.
- **Diagnostics remain opt-in, default off.** Mesa 0121–0125 use
  `MESA_KK_DEBUG=descriptor_stats`; DXVK 0006/0007 and vkd3d-proton 0005 use
  `PLAYPORT_DESCRIPTOR_STATS=1`. Their strict offline consumer is
  `tools/descriptorprof.py`. Failure-time sink details are diagnostic evidence,
  not a bypass of append/PIPE_BUF checks or a measurement pass.
- **Descriptor buffers are deferred, not rejected.** A2 (core plus the folded
  vkd3d 4-byte SSBO alignment), A3 (embedded immutable samplers) and A4 (GPL
  interaction), and their implementation/phone gates, move to
  [PLA-441](https://linear.app/playportdev/issue/PLA-441). None has started; no
  `descriptor_buffer` implementation or separate `ssbo_align_4b` flag ships.
  DXVK's descriptor-buffer config is not made a default.
- **Present wait stays off on iOS** (Mesa 0018). C1–C3, including low latency,
  remain [PLA-435](https://linear.app/playportdev/issue/PLA-435).
  `VK_EXT_depth_bias_control` and `VK_KHR_shader_atomic_int64` stay absent:
  [PLA-433](https://linear.app/playportdev/issue/PLA-433) and
  [PLA-434](https://linear.app/playportdev/issue/PLA-434). This close-out starts
  none of those tracks.

## Why

- **B1 is parity, not residency management.** Metal has no per-allocation priority;
  KK keeps heaps in one device-wide residency set. The priority API is a no-op.
  [Host](../evidence/2026-10-22-kk-memory-priority-host.md) and
  [phone](../evidence/2026-10-23-kk-memory-priority-phone.md) show accepted calls
  and both-route launch smoke, with vkd3d-specific pageable enablement not
  independently proven.
- **B3 works, but is not a measured speedup.**
  [Host](../evidence/2026-10-22-kk-module-identifier-host.md) tests cover identifier
  miss/hit/second-device/GPL behavior. The
  [phone](../evidence/2026-10-23-kk-module-identifier-phone.md) loads a 7,448-byte
  disk library with 25 PSOs and creates 25 graphics pipelines from identifiers.
  Phone identifier-miss fallback and performance benefit remain unobserved.
  GPL's separate default gate stays with PLA-429 under 0158.
- **The fd-status failure was concrete.** The
  [host cause and fallback repair](../evidence/2026-10-24-descriptor-append-cause-host.md)
  reproduced the shared-description append loss. The
  [two-route phone gate](../evidence/2026-10-24-descriptor-gate-phone.md) then
  observed native banners, 16 calibration samples and complete captures: 46/49
  strict usable intervals, 0 rejected, malformed or poison records. Both parser
  results were mixed (exit 2), because five streams had calibration only; all
  final tails were unknown. This proves bounded emission/smoke, not all-stream
  measurement completeness.
- **A0 does not settle descriptor-buffer value.** The
  [menu sampler](../evidence/2026-10-23-kk-descriptor-cpu-baseline.md) printed
  descriptor leaves at about 0.086% DXVK / 0.050% vkd3d of retained running
  observations, with large JIT/top-N/unwind gaps. These are not total CPU bounds.
  The [owner-played DXVK run](../evidence/2026-10-24-a0-descriptor-human-run.md)
  supplies a representative workload, not CPU attribution: 17,877 frames over
  302.6 s, mean/median/p10/min FPS 59.4/60.0/58.9/44.4. HUD-off reported zero
  hitches are unavailable detection, **not hitch-free proof** (review record
  `8d412d2`). Its strict result is mixed exit 2, 612 usable/0 rejected intervals,
  two calibration-only streams and four unknown final tails.

  In fixed interior snapshots 31→290, KK covers **78.212281 µs elapsed per
  drawable-submit signal**, 15,569 signals over about 260.790435 s: numerically
  **0.468337% of 16.7 ms per signal**, not presented-frame CPU share. Bind/push/
  template-push are 173.751493/1/0 executions per signal; all native operations
  are 466.217933/signal. DXVK records 62,116 submission requests over about
  260.128187 s: prep **59.259543**, standalone **10.014925**, total
  **69.274469 µs elapsed per request**, not per frame. Native executions include
  replay; client thread sums are not a wall union or removable savings. Missing
  coverage, independent boundaries, quantization and no diagnostics-off control
  prevent a complete negative bound. No cross-layer sum/subtraction or D3D12
  copy-cost inference is valid. **Covered native looks small; total NOT DECISIVE.**
- **The other gaps have different gates.**
  [Present-wait evidence](../evidence/2026-10-08-vulkan-perf-p99.md) measured late
  frames falling from 1.2–1.5% to 0.19% when it was removed on iOS; Mesa 0010,
  not 0018, fixed the hang. Metal lacks force-UNORM depth-bias control and a full
  native int64-atomic set. The existing issues retain those research questions.

## What would reopen descriptor work

Reopen PLA-441 only for an **owner-approved bounded measurement design providing
real thread-CPU attribution**, or after the owner **chooses a workload-specific
worthwhile recoverable CPU threshold B (ms per presented frame), acceptable
error/perturbation tolerance and a perturbation design in advance**. Neither
route is an implementation go-ahead. The previous **167 µs/frame (1% of 16.7 ms)**
was provisional, not owner-agreed or retroactively passed.

The design must use a repeatable owner-save scene, independently align actual
presented-frame events with each stream's own boundaries, keep request
denominators distinct, cover client preparation/copies and uncovered native
replay without double counting, and separate non-removable work. Retain
actual-platform calibration/quantization uncertainty; require warm same-IPA
diagnostics-off/on/off controls and a repeated representative window. Include
D3D12's actually selected optimized/default Simple copy path without changing its
vtable for profiling. Do not join clocks by frequency. A repeated, covered,
credibly removable CPU opportunity above B can justify reconsidering A2; an
adequate uncertainty-inclusive bound below B can defer it for that workload.
Another menu/count-only run or large elapsed envelope alone cannot decide it.
No CPU-clock bridge/profiler or new phone session is authorized by this record.

## Costs and remaining work

The feature and diagnostic patches remain maintained, off by default; no Vulkan
CTS or all-title correctness claim follows. No default promotion, descriptor
speedup or power saving was measured. PLA-441 carries the implementation
research and future gates; PLA-433/434/435 retain their scope. UI-session safety
and its outstanding marker-path/release/abrupt-death checks remain independent
[PLA-440](https://linear.app/playportdev/issue/PLA-440), unchanged by closing
PLA-431. Historical evidence is retained without reinterpreting failed captures.

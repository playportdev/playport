# Plan: KosmicKrisp Proton-parity extensions

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431) (umbrella). Deferred items:
[PLA-433](https://linear.app/playportdev/issue/PLA-433) (B2 depth bias),
[PLA-434](https://linear.app/playportdev/issue/PLA-434) (B4 int64 atomics),
[PLA-435](https://linear.app/playportdev/issue/PLA-435) (C present wait and low latency).
**Date:** 2026-10-22. **Kind:** plan, research done, in progress. **Branch:**
`dev/kk-proton-parity`, now in the main checkout after rebasing onto `26699f6`
([0117](../decisions/0117-side-copies-that-build.md)); the former side copy
`.work/worktrees/kkparity` is detached at `4fa1e73`. **Pins read:** `mesa` b39d173 + `patches/mesa` 0001–0103; `dxvk`
e5ffd0f + `patches/dxvk` 0001–0005 (tree head d942d78); `vkd3d-proton` 31d1f89 +
`patches/vkd3d-proton` 0001–0004 (tree head 567710d). Trees read: `$PLAYPORT_BUILD/run/vulkan-pe/dxvk`,
`$PLAYPORT_BUILD/run/vulkan-pe/vkd3d-proton`, and the patched Mesa in
`$PLAYPORT_BUILD/run/mesa/hosttest/mesa` (driver: `src/kosmickrisp/vulkan/`).

**Owner's decisions (2026-10-22):**
- Close these gaps against Proton on RADV and NVK. GPL is excluded (PLA-429).
  - A. `VK_EXT_descriptor_buffer`.
  - B. `VK_EXT_memory_priority` and `VK_EXT_pageable_device_local_memory`,
    `VK_EXT_depth_bias_control`, `VK_EXT_shader_module_identifier` and
    `VK_KHR_shader_atomic_int64` (false in the table today).
  - C. `VK_KHR_present_wait`/`present_wait2` on iOS (off since `patches/mesa` 0018), then
    `VK_NV_low_latency2`.
- Each feature lands behind its own `MESA_KK_EXPERIMENTAL=<name>`, off by default, as GPL did
  ([0158](../decisions/0158-kk-gpl-stays-experimental.md)).
- Phone gates are queued for the main checkout and listed as unrun.
- Valve/Proton defaults are ours. Nothing is offered upstream (`Offered-upstream: no`).

**What the research changes** (details below; the owner decides, open questions at the end):
1. **vkd3d-proton never takes the descriptor-buffer path on KosmicKrisp as it stands.** KK reports
   `minStorageBufferOffsetAlignment` 16, and vkd3d then turns descriptor buffers off. NVK reports 4
   to vkd3d through a driconf entry. That is a small change with its own D3D12 win, so it becomes
   chunk A1 and moves up the queue.
2. **DXVK turns descriptor buffers on only for RADV, NVK and llvmpipe.** On KK it needs
   `dxvk.enableDescriptorBuffer = True`, which goes against "Proton defaults are ours". DXVK also
   prefers `VK_EXT_descriptor_heap` over descriptor buffers.
3. **Present wait was turned off on iOS because it made pacing worse, not because it hung.**
   `patches/mesa` 0010 fixed the hang. 0018 removed present wait because it cut late frames from
   1.2–1.5 % to 0.19 %. Turning it back on is expected to bring that regression back. C is a
   measurement behind a flag, not a known win.
4. **`VK_NV_low_latency2` cannot be reached today.** Nothing in Playport calls Reflex: there is no
   dxvk-nvapi and the vendor ID is Apple. DXVK's own latency control works without the extension.
   Deferred.
5. **Metal has no full set of 64-bit atomics.** In Metal's own headers, `atomic_ulong` has only
   `atomic_min_explicit`/`atomic_max_explicit`, on device memory, with no return value. Textures
   have `atomic_min`/`atomic_max` on `ulong4`, also with no return value. Threadgroup memory has
   none. `KHR_shader_atomic_int64` can only be partial, which is an owner decision. The same
   question is FL12_2's chunk 0 probe (PLA-81).
6. **`depth_bias_control` gives nothing on its own.** Metal has no switch that forces a UNORM bias
   on a float depth buffer. Without that, DXVK and vkd3d-proton behave as they do today. The win
   (correct bias for D24 games, whose D24 KK stores as D32F) needs a shader emulation (M), and no
   installed title exercises it. Owner decision.

## Settled (owner, 2026-10-22)

1. **The 4-byte SSBO alignment for vkd3d-proton (A1) folds into `descriptor_buffer`.** No
   separate `ssbo_align_4b` flag; it lands with A2 under the one flag.
2. **DXVK and descriptor buffers:** enable `dxvk.enableDescriptorBuffer=True` for DXVK later,
   by a decision record, only if the phone shows it wins. Until then DXVK runs measure it through
   graphics options only.
3. **Out of the queue:** B2 depth bias (PLA-433), B4 int64 atomics (PLA-434), C1–C3 present wait
   and low latency (PLA-435). Their research stays below for those issues.
4. **A2 is gated on A0.** The descriptor-buffer core (L) starts only after the phone CPU profile
   (A0, main checkout) shows descriptor cost matters.
5. Models (owner reconfirmed 2026-10-23): both hard and easy tasks use
   `openai-codex/gpt-6.1-sol` (high); Opus usage is exhausted.

## Runner state

The supervisor keeps this section.

- **Branch:** `dev/kk-proton-parity` in the main checkout, rebased from `7103952` onto
  main `26699f6`; transfer HEAD `4fa1e73`. Side copy detached; main branch untouched.
  Owner SettingsView edit preserved byte-for-byte and uncommitted (SHA256
  `14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`).
- **Done:** research; side copy S0 (2026-10-22: two `pp build`s exit 0, IPA `29cfa508…` 89/89 checks, host test and `pp test --quick` pass, nothing committed; report left in the build area at `.work/agent-notes/kk-parity/reports/s0-side-copy.md`). S0 found that meson's binary `coredata.dat` in a copied `run/mesa` names main and writes into main's `meson-private`: delete those meson dirs before a copy's first build (PLA-436).
- **B1 done** (`a2fba62` → `7dee945`, mesa 0119, bit 16, flag `memory_priority`): host test 59 ok, flag MSL 181/181 identical, side-copy IPA `3393f48f…` 89/89; [historical host evidence](../evidence/2026-10-22-kk-memory-priority-host.md).
  Rebased host suite: 185/185 identical. **Phone runtime gate passed** on both routes,
  with vkd3d-specific client-log verification limited;
  [phone evidence](../evidence/2026-10-23-kk-memory-priority-phone.md).
- **B3 done** (`12d113b` → `2a76219`, mesa 0120, bit 17, flag `module_identifier`): common-runtime identifiers, `MESA-BLAKE3` algorithm UUID kept (supervisor, spec's "should"); identifier pipelines only from a cache, else `VK_PIPELINE_COMPILE_REQUIRED`. Host test 62 ok (supervisor reran), MSL 181/234 identical; side-copy IPA `c88649a7…` 89/89; [historical host evidence](../evidence/2026-10-22-kk-module-identifier-host.md).
  **Phone smoke and disk-cache hit proof passed** (25 warm graphics identifier hits);
  [phone evidence](../evidence/2026-10-23-kk-module-identifier-phone.md). Phone identifier
  miss/fallback unobserved; no performance claim.
- **Integration (2026-10-23):** append conflicts in host runner/series and wanted-helper
  definitions resolved by retaining both sides. Mesa patches regenerated against 0118;
  main bits 0–15 retained, parity moved to 16/17 (supervisor approved). Range-diff inspected;
  no other semantic change. Fresh main IPA `5e3fc6a8…` verified 89/89; no build-record
  changes. Owner edit included, not committed. Full host suite, combined parity/GPL run,
  `pp test --quick`, names and secrets passed. B3 MSL comparison now 185/239.
- **Next (owner, 2026-10-23):** improve measurement; do not waive A0. Read-only design
  investigation completed (child `20afcc4d`); report left in the build area at
  `.work/agent-notes/kk-parity/reports/a0-measurement-design.md` (PLA-431).
  Proposed opt-in scoped descriptor counters/elapsed timing in KK and both clients avoid
  sampler/JIT redesign, but elapsed time is not CPU time: a small envelope can reject an
  opportunity; a large one alone cannot prove benefit. Existing vkd3d API profiling changes
  optimized vtable selection, so is not a drop-in baseline. No safe automatic existing-save
  workload established; New Game/King's Pass scripts need owner permission and assumptions.
  **Owner approved scoped diagnostics and existing-save human-controller gameplay.**
  Ordered measurement queue (PLA-431), one writer each:
  1. KK `MESA_KK_DEBUG=descriptor_stats` counters/elapsed timing and host coverage:
     **implemented** (`8b6a20e`), host checks passed; independent review ACCEPT
     (child `31c95ed3`, report left in the build area at
     `.work/agent-notes/kk-parity/reports/a0-kk-probe-review.md`). The bounded
     documentation/replay-test correction closes its P2 finding (host checks passed):
     bind/push counts measure driver executions including secondary/reusable-primary
     replay, not application-call
     counts. Preserve replay costs as potentially uncovered by client scopes; no client/native
     count-parity or containment assumption. Real snapshots assert 0/1/2/2 secondary
     and 3/3/4/5 reusable-primary cumulative calls per bind/push/template-push. Test-only
     opt-in deferred mock feedback avoids inline callback reentry; no production change.
     No blocking API-behavior defect established.
     Mesa 0121; [host evidence](../evidence/2026-10-23-kk-descriptor-cost-probe-host.md).
     Dev IPA `1a7935b2…` verified 89/89, owner UI edit included/uncommitted;
     Original 185/219 MSL prefixes unchanged; replay adds 17 at end, 236 off/on identical.
     Per-device disjoint scopes use checked monotonic elapsed time, not CPU time.
     No phone calibration/smoke or gameplay; A0 justification remains insufficient.
     Parent reviewed correction `1846ca5` and independently reran the full host suite:
     exit 0, replay counts and 236 off/on MSL identity confirmed. Log left in the build
     area at `.work/agent-notes/kk-parity/supervisor-replay-host.log`.
  2. **DXVK 0006 implemented** (`cea547f`), host checked; initial independent review **BLOCK**
     (child `6cbf8167`, report left in the build area at
     `.work/agent-notes/kk-parity/reports/a0-dxvk-probe-review.md`). Parent helper rerun
     passed (log `supervisor-dxvk-helper.log` under those notes), but lacked the failing trace.
     **Clock correction 0007 accepted** (`9edfd9b`), independent re-review **ACCEPT**
     (revived reviewer `f466bbe4`, report left in the build area at
     `.work/agent-notes/kk-parity/reports/a0-dxvk-clock-rereview.md`); prior P1 closed.
     Parent regression rerun passed, including both rejection traces
     (log `supervisor-dxvk-clock.log` under those notes). Child starts
     before the previous sibling end are rejected; child-end bookkeeping is monotonic,
     with explicit errors and ancestor invalidation. Real-helper regressions first failed
     against 0006: reviewer trace yielded exclusive 30, overlapping siblings 40, no errors.
     Both now publish zero valid parent/second-child timing and clock/nest errors;
     deeper invalidation, failed/backwards reads, recovery and equal timestamps pass.
     Reconstructed tree equals the source commit; helper and ASan/UBSan pass. Fresh dev
     IPA `a1e362fa…` verified 89/89; six actual DXVK artifact rows changed, protected owner
     UI edit included/uncommitted. Quick 712 Python/26 C groups pass; names/secrets clean.
     [Clock-fix host evidence](../evidence/2026-10-23-dxvk-descriptor-clock-fix-host.md).
     No Mesa/ARM64EC inspection suite or phone rerun in the correction. **Accepted as
     reference for the vkd3d host writer only; A2 and phone measurement remain gated.**
     Default-off
     `PLAYPORT_DESCRIPTOR_STATS=1`, per-device checked elapsed scopes, same-thread fixed
     TLS nesting, client inclusive/exclusive and summed-thread outermost attribution;
     standalone pool work and specification-data exclusions separate. No cross-layer
     subtraction or native replay containment assumption. Real-helper deterministic/
     two-thread/error/calibration tests and ASan/UBSan pass; optimized host/ARM64EC
     disabled paths inspected. Full Mesa host runner passes (236 off/on MSL unchanged),
     quick 712 Python/26 C groups, names/secrets clean. Dev IPA `0bc7e996…` verified
     89/89; seven actual DXVK artifact rows changed, owner UI edit included/uncommitted.
     [DXVK host evidence](../evidence/2026-10-23-dxvk-descriptor-cost-probe-host.md).
     No DXVK Vulkan execution, phone calibration/smoke or gameplay. Denominator is
     client submission requests, not frames. Per-thread rows withdrawn by supervisor;
     aggregates are thread sums, not wall union/CPU time. A2 remains gated.
  3. **vkd3d 0005 implemented** (`147ebbc`), host checked; independent review **ACCEPT**
     (child `d845db51`, report left in the build area at
     `.work/agent-notes/kk-parity/reports/a0-vkd3d-probe-review.md`), no issues found.
     Parent real-helper rerun passed (log `supervisor-vkd3d-helper.log` under those notes).
     Default-off
     scoped elapsed/thread-sum diagnostics preserve all eight Simple implementations
     and vtable selection; RTV/DSV/constants exclusions remain separate. Real-helper
     regressions, GCC/clang, ASan/UBSan and full ARM64EC/i386 builds pass. Actual
     disabled guards inspected; distro GCC/clang scope locals add compiler-canary TLS
     prologue overhead, not diagnostic TLS (no zero-overhead claim). Dev IPA `74c0d54e…`
     verified 89/89, one d3d12core artifact row changed; owner UI edit included/uncommitted.
     Quick/names/secrets pass. No Vulkan execution, device calibration/smoke or gameplay.
     [Host evidence](../evidence/2026-10-23-vkd3d-descriptor-cost-probe-host.md);
     report left in the build area at
     `.work/agent-notes/kk-parity/reports/a0-vkd3d-probe-host.md`.
     Accepted for parser/integration only; A2 and phone gates remain gated.
  4. **Offline parser/integration ACCEPT**: `496547c`, corrections `bafeced` and `5a46a4a`.
     Original review blockers (history loss, timing feasibility, post-final recovery, calibration
     contradictions, then duplicate-row history loss) are closed by original reviewer `e5bf2014`;
     report left in the build area at `.work/agent-notes/kk-parity/reports/a0-parser-final-review.md`.
     Parent independently reran all 33 focused tests: pass (`supervisor-parser-duplicate.log`).
     Quick745 Python/26 C groups, names/secrets pass. No native changes or new IPA.
     Strict10/36/54 rows, per-row cumulative history through gaps, integer timing feasibility,
     terminal final, raw calibration validity and forward duplicate quarantine prevent false
     recovery. Earlier clean windows and unrelated identities remain usable; raw invalid evidence
     retained. Real host inputs unchanged: 11 usable KK intervals/5 rejected helper windows;
     one DXVK capture and partial vkd3d output insufficient, not actual client interval proof.
     No cross-layer join/sum/subtraction, CPU attribution or presented-frame normalization.
     [Host evidence](../evidence/2026-10-23-descriptor-prof-parser-host.md); detailed correction
     reports left under `.work/agent-notes/kk-parity/reports/a0-parser-{fixes,duplicate-fix}.md`.
     Accepted for owner coordination and separately gated device calibration/smoke only, not A2.
     **Owner approved prepare-now:** dev upgrade in place and short menu-only probe checks.
     Later the owner will load their existing save/room personally; normal autosaves allowed.
  5. **Menu-only device prep BLOCKED** (PLA-431): exact verified probe IPA `74c0d54e…`
     upgraded in place, container retained. DXVK off/on both reached first-frame+30 and
     visibly rendered menus; actual native/QPC calibration retained. Strict full-log parser
     exit1: **0 usable intervals, 17 malformed interleaved records**, incomplete KK/client
     captures. KK multi-write snapshot lines interrupted by DXVK and other logging;
     no runtime/parser edits or reconstructed evidence. Supervisor stopped further plays:
     **D3D12 off/on and actual selected Simple path unrun**. Fixed pre-stop shots showed
     startup/splash/black; stop shots show menus. Product automatically cleared81.8/80.8MB
     FEX caches under its low-disk policy; worker requested no deletion. Settings/diagnostics
     restored, explicitly captured black, lock released; no gameplay or save navigation.
     [Device blocker evidence](../evidence/2026-10-23-descriptor-probe-device-prep.md);
     report `.work/agent-notes/kk-parity/reports/a0-device-prep.md` in the build area.
     **Host-only wire-emission correction implemented** (`68e5eab`), initial review **BLOCK**
     (child `7ca57dde`, report left in the build area at
     `.work/agent-notes/kk-parity/reports/a0-emission-review.md`). Parent emitter-matrix rerun
     passed (log `supervisor-emission.log` under those notes), but lacked unsupported sink cases.
     **Minimal sink correction0123 ACCEPT** (`cdaff3c`), independent re-review passed
     (revived reviewer `3fc82a56`, report left in the build area at
     `.work/agent-notes/kk-parity/reports/a0-emission-sink-rereview.md`), P1 closed.
     Parent expanded matrix rerun passed (log `supervisor-emission-sink.log` under those notes). (PLA-431,
     starting HEAD `2c15869`). Supports only regular files with successful F_GETFL/O_APPEND or
     FIFO rows within known positive PIPE_BUF; other types/flag failures use the existing latch
     and best-effort poison. Four actual-emitter sink tests red before production edit:37 record
     writes/latch0; green:0 record writes/1 poison attempt/latch1/0 future writes. After-init
     nonappend transition also tested; host API/helper captures truncate once then append-open.
     Full Mesa suite preserves236 baseline/off-on MSL identity and replay counts; three4010-row
     stress seeds, unchanged33 parser tests, quick745 Python/26 C groups, names/secrets pass.
     New dev IPA `689b9479…` verified89/89, owner edit included/uncommitted, not exact committed
     source; no build-record changes. No phone commands or parser/schema/client/bridge changes.
     [Sink-fix host evidence](../evidence/2026-10-23-descriptor-emission-sink-fix-host.md);
     report `.work/agent-notes/kk-parity/reports/a0-emission-sink-fix.md` in the build area.
     Accepted for a separately bounded device-prep retry only, not device or performance proof.
     Branch unmerged/unpushed; stable-fd2 and approved terminal-loss limits retained.
     Mesa0122 changes only KK diagnostic
     emission: checked2048-byte complete-row formatting and one raw write to the confirmed normal
     O_APPEND file sink. Actual committed emitter regression red before fix; deterministic
     `write_records=0info:` splice reproduced with an independent raw appender, then strict-parser
     append/pipe fixtures and three pinned stress seeds pass. Full host suite preserves236/236
     descriptor off/on MSL and the pre-fix236 prefix; unchanged33 parser tests and quick/names/secrets
     pass. Dev IPA `9d0d2b2a…` verified89/89, owner UI included/uncommitted, not exact committed-source
     provenance; no build-record changes. No parser/schema/timing/counter/activation changes or
     phone commands. Pipe rows above actual PIPE_BUF fail closed; terminal sink failure cannot
     guarantee detection of a newline-only short (explicitly tested/accepted limitation).
     [Host evidence](../evidence/2026-10-23-descriptor-emission-fix-host.md); report
     `.work/agent-notes/kk-parity/reports/a0-emission-fix.md` in the build area.
     **Menu-only prep retry BLOCKED (2026-10-23)**: exact IPA `689b9479…` upgraded in
     place, container kept. DXVK off/on reached first-frame+50 with live45/55s menus,
     but full raw strict parser exit1:0 usable,60 rejected intervals,2 native failure-poison
     records; no KK banner/calibration/10-row capture. Native activation confirmed; emitter
     latches before banner, exact failing branch UNKNOWN. DXVK61 complete36-row captures
     remain rejected on source poisoning, not selectively reparsed. Supervisor STOP after
     two plays; D3D12 off/on UNRUN, no extra retry/fix. Settings/diagnostics restored, explicit
     black,73% not charging/5.9GB, lock released; unattended unchanged/null.
     [Retry evidence](../evidence/2026-10-23-descriptor-probe-device-prep-retry.md); report
     `.work/agent-notes/kk-parity/reports/a0-device-prep-retry.md` in the build area.
     Original bad raw log remains immutable. No gameplay/performance/perturbation proof.
  The bounded retry is stopped; no further phone play/fix authorization here.
  Human gameplay still waits for owner handoff.
  No save automation/new slot authorized. No sampler
  redesign, CPU-clock bridge or descriptor implementation approved. Checkpoint `cdaff3c`;
  no merge or push. A2–A4 remain **not started**, gated on evidence that descriptor cost matters.
- **B1 phone (2026-10-23):** both flag-off routes and memory_priority DXVK/D3D12 reached
  first-frame+10. DXVK features 0 off / 1 on; priority counts 14/14 and 28/13.
  vkd3d's extension-name TRACE is compiled out; its initial priority allocation is behavioral
  evidence for memoryPriority, but global counters do not prove its pageable enablement.
  Runtime gate accepted with that explicit limit, not literal fulfillment of the original
  vkd3d client-log criterion. No gameplay/performance claim. Settings restored; battery 80%
  external, existing unattended setting unchanged.
- **B3 phone (2026-10-23):** same installed IPA `5e3fc6a8…`, owner edit included.
  D3D12 first/warm and GPL+identifier DXVK reached first-frame+10; warm D3D12 loaded a
  7448-byte disk library with 25 PSOs and created 25 graphics pipelines from identifiers.
  INFO logs survive compiled-out TRACE. First run compiled without identifiers; no phone
  identifier miss/fallback observed. Original warm/DXVK stop shots were black; one approved
  visual follow-up per route reached first-frame+20 and captured matching menus before stop.
  Settings/arguments/graphics options restored; 80% external power, unattended state unchanged.
  No gameplay/performance claim; GPL and module_identifier remain default off.
- **A0 preliminary (2026-10-23):** [descriptor CPU baseline](../evidence/2026-10-23-kk-descriptor-cpu-baseline.md).
  Two 180 s flag-off, HUD-off Vulkan/720p/60 main-menu profiles on the same `5e3fc6a8…`
  IPA (owner edit included), no gameplay/save progress. Steady denominators 8,840 DXVK /
  8,385 vkd3d running samples. Definite printed descriptor leaves ≈0.086% / 0.050% of
  those samples, ≈0.46% CS / 0.17% render worker; not complete cost estimates. JIT share
  55.3% / 60.6%, top-N omissions and limited unwinding; CopyDescriptors unobserved,
  not proven zero. Two quantized PC bins straddle function boundaries and are excluded.
  **Recommendation INSUFFICIENT for A2**, not an A0 justification-gate pass. Supervisor
  decides defer versus separately authorized representative workload/attribution work.
  No runtime/profiler changes or extra plays. Settings/diagnostics restored; last captured
  page black, 80% external power, inherited unattended unchanged.
- **Phone queue** (PLA-431, main checkout):
  - A0 scoped diagnostics host queue and KK0122/0123 independent re-review accepted.
    Menu-only device retry now BLOCKED by two native emission-failure poison records before
    banner (exact failure branch unknown),0 strict usable intervals; DXVK live menus render.
    D3D12 remains unrun, no further play/fix authorized. Supervisor diagnosis/review first;
    owner existing-save workload coordination
    and human measurement remain pending. No save automation or automatic measurement;
  - A's gates after an authorized A2–A4, which have not started.
- **Phone:** installed titles are Hollow Knight (`app-367520`) and RDR2. The D3D12 route is Hollow
  Knight with `-force-d3d12` (vkd3d-proton). No installed title is known to use depth bias.
- **Notes:** reports under `.work/agent-notes/kk-parity/reports/`, research scratch under
  `.work/agent-notes/kk-parity/research/`.

## How each chunk is built (the GPL pattern)

- **Patches.** One `patches/mesa` file per chunk, B1 at 0119 and B3 at 0120 after the main-checkout rebase, with `Class: feature`, an
  `Evidence:` link and `Offered-upstream: no`.
- **The flag.** A new `KK_EXPERIMENTAL_<NAME>` bit after main's bit 15 (B1: 16, B3: 17) in
  `kk_debug.h`/`kk_debug.c`. The table entry and feature read `KK_EXPERIMENTAL(<NAME>)`, as `gpl`
  does in `kk_physical_device.c`.
- **Host test.** `build/mesa-host-test/run.sh` runs `kk-host-test` once more with the flag.
  - Without the flag, the extension must be absent.
  - With it, the chunk's own check must pass.
  - For every chunk that should not change MSL, every `.metal` must be byte-identical to the
    flag-off baseline (the `cmp` loop GPL uses).
  - New MSL goes through `msl-compile.sh` (Apple's Metal front end under Wine; `METAL_EXE` and
    `WINEPREFIX` from an existing install under `.work`).
- **Cache key.** The pipeline cache UUID and the Mesa disk-cache ID hash the driver's build ID
  (`kk_physical_device_init_pipeline_cache`, `kk_physical_device.c:1040`), so every rebuilt driver
  already starts a fresh cache. A runtime flag that changes MSL for the same SPIR-V and state must
  also go into that hash, as `vertex_compute_workaround_6` does. Otherwise flag-on and flag-off
  share cache entries. Each chunk below says whether it needs this.
- **Side copy.** `pp build` and `pp verify` run in the side copy. It commits only path-independent
  record rows and never runs device commands (0117).
- **Phone gate.** Run in the main checkout after the branch moves there:
  - the smoke gate (Hollow Knight first frame +10) with the flag off;
  - the chunk's own runs with the flag on, through `pp ui --settings
    'app-367520:{"graphicsOptions":"MESA_KK_EXPERIMENTAL=<name> …"}'`
    ([0137](../decisions/0137-graphics-options-set-any-variable.md)).

  Results go in `docs/evidence/` with the IPA's sha256.
- **Decision.** One decision record (next free number 0159) at the end, as 0158 did, saying which
  flags stay off and which, if any, become defaults.

## What DXVK and vkd3d-proton do with each extension

"Turn it on" means whether, given KK's other capabilities, the layer would actually use the
extension once KK exposes it.

| Ext | DXVK (pin) | vkd3d-proton (pin) | Turn it on on KK? |
| --- | --- | --- | --- |
| `EXT_descriptor_buffer` | Driver allowlist: RADV, NVK, llvmpipe; otherwise needs `dxvk.enableDescriptorBuffer` | Yes if `descriptorBuffer`, `descriptorBufferPushDescriptors`, UBO non-uniform indexing, `minStorageBufferOffsetAlignment` ≤ 4 (or > 16) and a large enough range | DXVK: **no** without config. vkd3d: **no** until A1 |
| `EXT_memory_priority` | Priority on device-local allocations | Priority on heaps and committed resources | Yes, but it is a no-op on KK |
| `EXT_pageable_device_local_memory` | `vkSetDeviceMemoryPriorityEXT` after each allocation | MakeResident/Evict and non-resident heaps | Yes, but it is a no-op on KK |
| `EXT_depth_bias_control` | D3D9: float or UNORM rule; D3D11: UNORM for D16/D24 views | `vkCmdSetDepthBias2EXT` with a per-DSV representation | Yes, but nothing changes unless KK offers force-UNORM |
| `EXT_shader_module_identifier` | Only for GPL libraries (needs `MESA_KK_EXPERIMENTAL=gpl`) | Disk cache stores identifiers instead of SPIR-V; PSOs record them | vkd3d: **yes**. DXVK: only with gpl |
| `KHR_shader_atomic_int64` | Not used | SM 6.6 (already forced by vkd3d 0002), OPTIONS9/11 caps | Only partially possible |
| `KHR_present_wait(2)` | Frame thread waits for the display before releasing latency | Same, through `chain->present.wait` | Yes, and that is what 0018 removed |
| `NV_low_latency2` | Reflex tracker (needs nvapi), or `dxvk.latencySleep=True` | `ID3DLowLatencyDevice` (dxvk-nvapi only), out-of-band queue | Effectively no |

## A. `VK_EXT_descriptor_buffer`

### What the layers do

**DXVK** (`src/dxvk/`):
- **Choosing the descriptor model.** `DxvkContext`'s constructor (`dxvk_context.cpp:26-40`) picks
  descriptor heap, then descriptor buffer, then the legacy `DxvkDescriptorPool`, which updates
  sets with templates.
- **Auto means an allowlist.** `DxvkDeviceCapabilities::disableUnusedFeatures`
  (`dxvk_device_info.cpp:493-542`) turns off `descriptorHeap` unless the driver is RADV, NVK,
  llvmpipe or ANV, and `descriptorBuffer` unless it is RADV, NVK or llvmpipe.
  `dxvk.enableDescriptorBuffer` and `dxvk.enableDescriptorHeap` (`dxvk_options.cpp:10-11`, Auto)
  override it. "Descriptor heap deprecates descriptor buffer" (line 513): with both, DXVK takes
  the heap.
- **The descriptor-buffer path.**
  - DXVK makes one resource heap of up to 8 MB in eight slices, in device-local, host-visible
    memory (`dxvk_descriptor_heap.cpp:75-130`), and a sampler heap
    (`dxvk_sampler.cpp:370-395`).
  - It writes descriptors from `vkGetDescriptorEXT` bytes
    (`dxvk_descriptor_info.cpp:387-418`) and binds offsets.
  - It uses `vkGetDescriptorSetLayoutSizeEXT` and `vkGetDescriptorSetLayoutBindingOffsetEXT`
    (`dxvk_pipelayout.cpp:306-326`).
  - It sets `VK_PIPELINE_CREATE_2_DESCRIPTOR_BUFFER_BIT_EXT` on every pipeline, GPL libraries
    included (`dxvk_graphics.cpp:242,538`, `dxvk_shader.cpp:418,521,560`).
- **Without it** (KK today): pool allocations and `vkUpdateDescriptorSetWithTemplate` at draw time.
- **Expected win (inference):** CPU on `dxvk-cs`. Hollow Knight's `dxvk-cs` is about 4 Mi/frame
  ([p99 evidence](../evidence/2026-10-08-vulkan-perf-p99.md)), so a small title gains little.
  Heavier D3D11 titles may gain more. Not measured.

**vkd3d-proton** (`libs/vkd3d/`):
- **When it uses descriptor buffers.** `vkd3d_global_descriptor_buffer_init` (`resource.c:11412-11458`)
  enables them only when all of these hold:
  - `descriptorBuffer` and `descriptorBufferPushDescriptors`;
  - `shaderUniformBufferArrayNonUniformIndexing`;
  - it would need no SSBO offset buffer: `minStorageBufferOffsetAlignment` ≤ 4, or > 16, which
    gives up raw SSBOs;
  - `maxResourceDescriptorBufferRange` ≥ (10⁶ + 1) × the mutable descriptor size, doubled when it
    cannot embed mutable descriptors.

  KK's `minStorageBufferOffsetAlignment` is `KK_MIN_SSBO_ALIGNMENT` = 16
  (`kk_physical_device.c:701`, `kk_private.h:23`). `requires_offset_buffer` is therefore true, and
  **the path is skipped**.
- **Without it** (KK today):
  - `CopyDescriptors(Simple)` goes through `vkUpdateDescriptorSets` with `VkCopyDescriptorSet`
    batches (`resource.c:5095-5260`); `d3d12_device_CopyDescriptorsSimple_default` is at
    `device.c:6502`.
  - Typed buffer views always carry a typed offset buffer (`state.c:7859-7861`).
  - With 16-byte SSBO alignment, raw SSBOs also go through an SSBO offset buffer
    (`state.c:7854-7855`): one more indirection per raw buffer access in every D3D12 shader.
- **With it:** descriptor copies are memcpys into the heap. vkd3d picks specialised vtables for
  known descriptor sizes (`device.c:10447-10466`). KK's sizes (64-byte sampled image, 16-byte
  buffer) match none of them, so the generic path is used. Typed views are placed directly, so
  the typed offset buffer goes (`state.c:7857-7861`).
- **The embedded-mutable variant** (`vkd3d_bindless_supports_embedded_mutable_type`,
  `state.c:7642-7745`) packs a texel buffer and an SSBO into one mutable slot. It needs:
  - a power-of-two mutable size ≥ 32 (KK: 64);
  - a power-of-two `samplerDescriptorSize` ≥ 16;
  - `descriptorBufferOffsetAlignment` ≤ `robustStorageBufferDescriptorSize` (KK: 16).

  KK should report 16 to qualify.
- **Expected win (inference):** CPU on the game's render thread, where D3D12 games call
  `CopyDescriptorsSimple` thousands of times a frame, plus fewer GPU indirections. The
  [p99 evidence](../evidence/2026-10-08-vulkan-perf-p99.md) shows Hollow Knight's
  `UnityGfxDeviceWorker` at 17–20 Mi/frame on vkd3d against 11–12 on DXVK. Part of that gap may be
  descriptor emulation (inference); chunk A0 measures it.
- **`VK_EXT_descriptor_heap`** is supported but opt-in (`device.c:144`,
  `VKD3D_CONFIG_FLAG_STATIC(DESCRIPTOR_HEAP)`), and on by default only for WoW
  (`device_workarounds.c:134,215`). On vkd3d's default path, descriptor buffers are the way.

### What KosmicKrisp has

KK's descriptor model is NVK's. That makes descriptor buffers a close port of NVK's code.
- **Descriptor sets are plain GPU memory.** A pool is one `kk_bo` with a VMA heap
  (`kk_descriptor_set.h`). A set is `addr` and `size`.
- **Descriptor bytes are self-contained** (`kk_descriptor_types.h`):
  - sampled image: 64 B, with the Metal `gpuResourceID` and a 16-bit index into the device's
    sampler table;
  - storage image: 8 B;
  - texel buffer: 16 B, with an element offset, so any texel start works;
  - buffer: 16 B, a bounded global address.

  None of them points at CPU-side state. Shaders load textures as
  `*(constant texture2d<…>*)addr` and samplers as `sampler_table.handles[i]`
  (`nir_to_msl.c:1565-1575`). There are no Metal argument-buffer encoders.
- **The root table** (`kk_cmd_buffer.h:31-66`) holds `uint64_t sets[KK_MAX_SETS]` and the dynamic
  buffers. `kk_bind_descriptor_sets` (`kk_cmd_buffer.c:556-622`) only writes `root.sets[s]` and
  `set_sizes[s]`. Push descriptors are uploaded at draw time.
- **Residency is device-wide.** Every `kk_bo` is a Metal heap added to one `MTLResidencySet`
  (`kk_bo.c:93`, `kk_device.c:304-310,475-520`), so a resource a descriptor buffer refers to is
  always resident. No per-bind residency is needed.
- **Mutable descriptors** take `KK_MAX_DESCRIPTOR_SIZE` = 64 bytes
  (`kk_descriptor_set_layout.c:32-91`).
- **The Mesa runtime** gives:
  - `vk_common_Get*OpaqueCaptureDescriptorDataEXT` (`vk_descriptors.c:111-160`);
  - shader create flags `VK_SHADER_CREATE_DESCRIPTOR_BUFFER_BIT_MESA` from the set layout flags
    (`vk_shader.c:300-320`), so descriptor-buffer pipelines get their own shader keys;
  - `vk_nir_lower_descriptor_heaps` for `EXT_descriptor_heap`, which RADV and ANV expose and NVK
    does not.
- **The reference is NVK**:
  - `nvk_CmdBindDescriptorBuffersEXT`, `nvk_set_descriptor_buffer_offsets` and
    `nvk_bind_embedded_samplers` (`nvk_cmd_buffer.c:1100-1190`);
  - `nvk_GetDescriptorEXT` (`nvk_descriptor_set.c:1068`);
  - `nvk_GetDescriptorSetLayoutSizeEXT` and `nvk_GetDescriptorSetLayoutBindingOffsetEXT`
    (`nvk_descriptor_set_layout.c:546-570`);
  - embedded immutable samplers, which use a buffer prepared at layout creation
    (`embedded_samplers_addr`);
  - the properties at `nvk_physical_device.c:633-640,1158-1195`.

  NVK does not move immutable samplers into the shader, and neither should KK. **MSL should then
  not change**, and the host test can require byte identity.

### What has to change in KK

1. **Properties and features:**
   - `descriptorBuffer`, `descriptorBufferPushDescriptors` and
     `descriptorBufferImageLayoutIgnored`, with capture/replay off;
   - `bufferlessPushDescriptors = true`, `descriptorBufferOffsetAlignment = 16`;
   - descriptor sizes from `kk_descriptor_types.h`, and ranges of at least 128 MB (NVK reports
     `UINT32_MAX`; `KK_MAX_DESCRIPTOR_SET_SIZE` is 1 GB);
   - buffer usage `*_DESCRIPTOR_BUFFER_BIT_EXT` accepted.
2. **Layout size and binding offset.**
3. **`vkGetDescriptorEXT`**, made by refactoring `kk_descriptor_set.c`'s write helpers to write to
   a pointer.
4. **Binding in the command buffer:**
   - `vkCmdBindDescriptorBuffersEXT`;
   - `vkCmdSetDescriptorBufferOffsets2EXT`, which writes `root.sets[s]` and `set_sizes[s]` from
     the buffer address, the offset and the layout size;
   - embedded samplers.
5. **Meta save and restore.** `kk_meta_begin`/`kk_meta_end` (`kk_cmd_meta.c:130-165`) save set 0
   as a `kk_descriptor_set *`. A set 0 bound from a descriptor buffer has no set object and would
   not be restored after a clear or blit. They must save `root.sets[0]` and `set_sizes[0]` as NVK
   does.
6. **GPL interplay.** Libraries and links must carry the descriptor-buffer flag consistently; DXVK
   sets it on libraries.

### Risks

- **A set 0 lost after a meta operation** (step 5): wrong rendering after clears.
- **Immutable samplers in a descriptor-buffer layout.** Check the spec text against NVK's
  behaviour: the application writes the sampler with `vkGetDescriptorEXT`, or the layout uses
  embedded samplers.
- **The sampler table.** vkd3d makes up to 2,048 D3D12 samplers. KK's hardware sampler table is
  `MSL_MAX_SAMPLERS` (or 4,000 on M1/M2-class devices). That is unchanged by descriptor buffers,
  but vkd3d's sampler heap may now create samplers it did not before (inference).
- **The host mock runs no GPU work.** Rendering is checked only on the phone.
- **Not conformance-tested** (no CTS here).

**Size:** L (A2), on top of S chunks (A1, A3, A4). **Flag:** `descriptor_buffer`.
**Cache key:** no change if MSL is byte-identical; assert it. **Host test:**
- the extension only with the flag;
- every existing pipeline built once more with `DESCRIPTOR_BUFFER_BIT` set layouts, its MSL
  byte-identical;
- for every descriptor type, `vkGetDescriptorEXT` bytes equal what `vkUpdateDescriptorSets`
  writes. The mock maps BO contents directly, so a white-box read of the pool BO or a
  `MESA_KK_DEBUG` hook works;
- draws recorded with offsets and with push descriptors;
- a clear between two draws with set 0 from a descriptor buffer, with `root.sets[0]` restored
  (logged);
- a DXVK-style GPL link with the flag.

**Phone gate:**
- Hollow Knight `-force-d3d12` with `descriptor_buffer` and `ssbo_align_4b`. The vkd3d log must
  show the descriptor-buffer path; no "Small descriptor heap" line.
- DXVK with `DXVK_CONFIG=dxvk.enableDescriptorBuffer=True`.
- Both render as with the flags off.
- `pp perf --cpu-prof` against A0.

## A1. A 4-byte SSBO alignment for vkd3d-proton (prerequisite, standalone value)

- **What changes.** `minStorageBufferOffsetAlignment` = 4 and SPIR-V `min_ssbo_alignment` = 4,
  only when the instance's engine is vkd3d-proton (engine name `"vkd3d"`, as NVK's driconf matches
  it: `nouveau/vulkan/00-nvk-defaults.conf`, `nvk_instance.h:29-32`). KK already matches engines in
  code: Zink at `kk_physical_device.c:72`, RDR2 at `:581`.
- **KK needs no descriptor change for this.** Buffer descriptors store the exact address
  (`kk_descriptor_set.c`; no rounding down). Global loads and stores are emitted through `packed_`
  types (`nir_to_msl.c:838-893`), so 4-byte-aligned vectors are legal MSL. The 16 is only a
  declared limit plus a NIR alignment hint (`kk_shader.c:107`).
- **Win in vkd3d-proton:** no SSBO offset buffer (`state.c:7854`): one fewer load and add per raw
  buffer access in D3D12 shaders, and fewer offset-buffer writes on the CPU. It also lets A turn
  on.
- **Risks:**
  - MSL changes for every vkd3d shader (NIR alignment), so `msl-compile.sh` must pass on all of
    them;
  - the bounds check (`KK_SSBO_BOUNDS_CHECK_ALIGNMENT` 4) needs a recheck with unaligned bases.
- **Size:** S. **Flag:** `ssbo_align_4b`. **Cache key:** yes. Hash the effective alignment into
  `kk_physical_device_init_pipeline_cache`. It is per instance, so per physical device.
- **Host test:**
  - an instance with engine `"vkd3d"` and the flag reports 4;
  - its MSL compiles (`msl-compile.sh`);
  - the default engine's MSL is byte-identical.
- **Phone gate:** Hollow Knight `-force-d3d12` first frame +10 with the flag. The vkd3d log no
  longer reports an SSBO offset buffer (find the exact INFO line in A1).

## B1. `VK_EXT_memory_priority` and `VK_EXT_pageable_device_local_memory`

- **DXVK** (`dxvk_memory.cpp:1362-1406`):
  - device-local allocations get priority 1.0 when dedicated, 0.0 when host-visible and 0.5
    otherwise (`VkMemoryPriorityAllocateInfoEXT`);
  - with the pageable extension it also calls `vkSetDeviceMemoryPriorityEXT` after each
    allocation.
- **vkd3d-proton:**
  - heaps that deny non-RT/DS textures and committed RT/DS/UAV resources get high priority
    (`heap.c:360-391`, `resource.c:4289-4304`);
  - with pageable memory, unsuballocated device-local memory allows dynamic residency
    (`heap.c:388`, `resource.c:4593`);
  - `MakeResident` and `Evict` call `vkSetDeviceMemoryPriorityEXT` (`device.c:7048,7123,7477`);
  - `D3D12_HEAP_FLAG_CREATE_NOT_RESIDENT` starts at priority 0.
- **Without it:** no hints. Driver residency is as now.
- **Metal facts:**
  - KK keeps every heap in one `MTLResidencySet` for the device's lifetime.
  - Metal has no per-allocation priority. `setPurgeableState` is not a priority: a purgeable or
    volatile allocation may lose its contents.
  - On unified memory, taking an allocation out of the residency set would not lower the app's
    memory footprint (inference). It would turn any later GPU access to that memory into a
    fault, and D3D12 games do touch evicted resources in practice (inference).
- **So:** accept both structures and make `vkSetDeviceMemoryPriorityEXT` a no-op (with a
  `MESA_KK_DEBUG` count).
- **Expected win:** parity only; no residency or CPU change. It is the cheapest chunk and proves
  the flag plumbing and host-test pattern first.
- **Risks:** none known, beyond a call per allocation.
- **Size:** S. **Flag:** `memory_priority` (both extensions). **Cache key:** no; no MSL change,
  byte identity asserted.
- **Host test:**
  - the extensions only with the flag;
  - an allocation with `VkMemoryPriorityAllocateInfoEXT` and `vkSetDeviceMemoryPriorityEXT`
    calls;
  - MSL identical.
- **Phone gate:** Hollow Knight first frame +10 on DXVK and on `-force-d3d12` with the flag. Logs
  name the extension. No GPU errors.

## B2. `VK_EXT_depth_bias_control`

- **DXVK:**
  - D3D11 uses force-UNORM when the DSV is D24/D16 and the device offers
    `leastRepresentableValueForceUnormRepresentation` (`d3d11_context.cpp:3694-3740`). `exact`
    is passed through.
  - D3D9 prefers `floatRepresentation`, then force-UNORM (`d3d9_device.cpp:99-116`), and scales
    by an r value (`d3d9_util.h:211-225`). Without the extension, a D32F buffer standing in for
    D24 uses 2²³.
  - The vendor-specific branch (`0x10de && !exact`) does not apply to KK's vendor ID.
- **vkd3d-proton:** `vkCmdSetDepthBias2EXT` with a representation per DSV format
  (`command.c:8445-8470`). It also makes depth bias dynamic for pipelines with a null DSV
  (`state.c:6098-6110`).
- **Without it** (KK today):
  - `kk_cmd_draw.c:1403-1409` passes the Vulkan factors straight to Metal's
    `setDepthBias:slopeScale:clamp:`;
  - KK has no D24 format (`kk_format.c`: Z16, Z32F, Z32F_S8), so D24S8 games get D32F. Their
    constant bias then scales with float depth's exponent instead of 2⁻²⁴. That can differ by
    large factors near small depth values, and reversed-Z shadow maps are the case
    **(inference)**.
- **Metal and Honeykrisp facts:**
  - Honeykrisp (the same Apple GPU, through the kernel driver) exposes force-UNORM with a
    render-pass-level `dbias_is_int` hardware bit, and splits the control stream when it changes
    (`hk_cmd_draw.c:2572-2580,3150-3170,3310-3335`).
  - Metal exposes no such bit. Metal's units for a float depth buffer are not documented
    (inference: the D3D rule).
  - So KK can honestly expose only `depthBiasControl` and `depthBiasExact`, with no float or
    force-UNORM representation (as panvk does, `panvk_vX_physical_device.c:511-515`). Then
    **neither layer changes behaviour**.
- **What would give a win:** emulating force-UNORM on D32F by adding `c·2⁻²⁴·w` to clip-space z in
  the last pre-rasterization stage, with Metal's slope term unchanged. The clamp applies to both
  terms and can only be approximated for the constant part.
- **Size:** S for the honest extension (no value), M for the emulation. **Flag:** `depth_bias`.
- **Cache key:** none for the honest extension. The emulation needs a vertex variant key.
- **Host test:**
  - the extension only with the flag;
  - with the emulation: MSL compiles, and flag-off MSL is identical.
- **Phone gate:** none possible today, because no installed title is known to use depth bias
  (Hollow Knight is 2D; RDR2 is native Vulkan and uses plain `vkCmdSetDepthBias`, 606 pipelines
  with bias: [RDR2 needs](../evidence/2026-10-17-rdr2-vulkan-needs.md)).
- **Recommendation:** owner decision. Drop it, or do the emulation when a D3D11 title with
  shadow-map acne turns up.

## B3. `VK_EXT_shader_module_identifier`

- **DXVK:** only `DxvkShaderPipelineLibrary`, and only when both
  `pipelineCreationCacheControl` and `shaderModuleIdentifier` are on
  (`dxvk_shader.cpp:771-776`). After its first compile, DXVK retries a library from the
  identifier with `FAIL_ON_PIPELINE_COMPILE_REQUIRED` before it decompresses SPIR-V
  (`dxvk_shader.cpp:280-345,599-613`). That needs GPL, so on KK it needs `MESA_KK_EXPERIMENTAL=gpl`.
- **vkd3d-proton:**
  - it records identifiers for each stage (`state.c:3559,5101`);
  - its internal disk cache stores identifiers instead of full SPIR-V
    (`cache.c:3292-3296`; without the extension it saves full SPIR-V);
  - it checks `shaderModuleIdentifierAlgorithmUUID` on load (`cache.c:418,2436`).
- **Expected win (inference):**
  - a much smaller vkd3d cache on disk and less SPIR-V I/O at startup;
  - a warm start then depends on KK's own Mesa disk cache resolving identifiers. On a miss, vkd3d
    compiles DXIL to SPIR-V again: slower than today's SPIR-V cache, but correct;
  - with GPL on, DXVK decodes less.
- **What KK needs:**
  - KK builds pipelines through the common `vk_pipeline.c` and `vk_shader_ops`
    (`kk_device.c:293`); there is no `kk_Create*Pipelines`;
  - the runtime already hashes identifiers into the precompiled-shader key
    (`vk_pipeline.c:303-336`), equal to `module->hash` (`vk_shader_module.c:79-98`), and handles
    `FAIL_ON_PIPELINE_COMPILE_REQUIRED`;
  - so KK only advertises the extension and feature and copies
    `vk_shaderModuleIdentifierAlgorithmUUID` into the properties, as Honeykrisp does
    (`hk_physical_device.c:209,627,1072-1076`).
- **Risks:**
  - the GPL patches (0096–0101) changed how library shaders reach the cache (0099). An identifier
    lookup through a GPL library must hit, or DXVK falls back (no harm);
  - Settings › Storage's Clear empties Mesa's cache but not vkd3d's (check), so vkd3d's identifiers
    then always miss once. That is correct but slower;
  - evicting Mesa disk-cache entries has the same effect.
- **Size:** S. **Flag:** `module_identifier`. **Cache key:** no; MSL is identical.
- **Host test:**
  - the extension only with the flag;
  - `vkGetShaderModuleIdentifierEXT` equals `vkGetShaderModuleCreateInfoIdentifierEXT`;
  - the UUID is `MESA-BLAKE3`;
  - a pipeline from an identifier with `FAIL_ON_PIPELINE_COMPILE_REQUIRED` returns
    `VK_PIPELINE_COMPILE_REQUIRED` before the shader is known;
  - it succeeds after it was compiled, and from a second device through a pipeline cache;
  - the same through a GPL library with `gpl`;
  - MSL identical.
- **Phone gate:**
  - Hollow Knight `-force-d3d12` twice with the flag: the second launch loads PSOs from
    identifiers (vkd3d cache log lines), first frame not later than flag-off;
  - one DXVK launch with `gpl,module_identifier`.

## B4. `VK_KHR_shader_atomic_int64`

- **Use:**
  - DXVK: none.
  - vkd3d-proton: `OPTIONS9.AtomicInt64OnGroupSharedSupported` from `shaderSharedInt64Atomics`,
    `OPTIONS11.AtomicInt64OnDescriptorHeapResourceSupported` from `shaderBufferInt64Atomics` with
    alignment ≤ 16, and typed resources from `EXT_shader_image_atomic_int64`
    (`device.c:9447-9484`).
  - SM 6.6 is already exposed without it by `patches/vkd3d-proton` 0002 (shaders that use int64
    atomics fail to compile).
- **Metal facts**, from Metal's own headers (Metal Developer Tools for Windows, build 32023;
  `metal_atomic:1660-1712`, `metal_config`, `__bits/metal_texture2d:2019-2065`; not checked
  against iOS 27's MSL 4.1):
  - `atomic_ulong` exists (MSL ≥ 2.4) with only `atomic_max_explicit` and `atomic_min_explicit`,
    on **device** memory, returning **void**. There is no add, exchange or compare-exchange, and
    no threadgroup `ulong` atomic.
  - Textures with `ulong` channels (MSL ≥ 3.1) have `atomic_max` and `atomic_min` on `ulong4`,
    returning void.
  - The Apple GPU family needed is not in the headers. Apple's tables put the A19 in Apple10.
- **What this means:**
  - the full feature (all operations, results returned) cannot be implemented natively. A lock
    emulation risks GPU forward-progress hangs;
  - a partial flag could expose `shaderBufferInt64Atomics` and lower only `umin`/`umax`/`imin`/`imax`
    whose result is unused to MSL, failing any other int64 atomic at compile with a log line. That
    breaks the spec; it is what vkd3d 0002 already does one layer up;
  - UE5 Nanite's visibility buffer uses `InterlockedMax` on 64-bit values (inference, also in the
    [FL12_2 plan](2026-10-05-kosmickrisp-fl12_2.md)). On D3D12 it may use a typed UAV, which would
    need image int64 (the texture path) as well.
- **Size:** M (partial, buffer only), M+ with images. **Flag:** `atomic_int64_minmax`.
  **Cache key:** yes; hash the flag.
- **Host test:**
  - shaders with 64-bit `atomicMax`/`atomicMin` without use of the result compile to
    `atomic_max_explicit` (`msl-compile.sh`);
  - `atomicAdd` fails with a log line;
  - flag-off MSL is identical.
- **Phone gate:** needs a UE5 D3D12 title, and none is installed.
- **Recommendation:** owner decision, and coordinate with FL12_2 chunk 0 (PLA-81), which asks the
  same question. These headers answer its probe for the front end.

## C. Present wait, then `VK_NV_low_latency2`

### C1. `VK_KHR_present_wait`/`present_wait2` on iOS

- **What 0018 did, and why.** `patches/mesa` 0018 sets `KK_PRESENT_WAIT` false on iOS
  (`kk_physical_device.c:41-52,187`). The Metal WSI then reports `presentWait2Supported` from the
  device extension. 0018 was **not a hang fix**:
  - [the p99 evidence](../evidence/2026-10-08-vulkan-perf-p99.md) shows that with present wait,
    DXVK and vkd3d-proton release the game's frame latency from the drawable's presented handler;
  - Hollow Knight runs at a frame latency of 1, so it ran exactly one frame ahead of the display,
    and 1.2 % (DXVK) and 1.5 % (vkd3d) of frames missed their refresh at 120 Hz;
  - without present wait, latency is released at GPU completion, as on DXMT (and as DXGI's frame
    latency counts frames on Windows; inference). Late frames fell to 0.19 %;
  - GPU ms rose from 5.8 to 6.55 (clocks, inference).

  The hang was `patches/mesa` 0010: an infinite `vkWaitForPresentKHR` when a presented handler
  never came. Since then the wait is capped at 100 ms after the present's GPU work, and that code
  is still there for macOS.
- **DXVK:** `m_hasPresentWait` (`dxvk_presenter.cpp:967`). In FIFO mode the frame thread calls
  `vkWaitForPresent2KHR`/`vkWaitForPresentKHR` with an infinite timeout (`:1995-2017`), then
  signals the latency tracker and the frame-latency event. Present timing
  (`VK_EXT_present_timing`) needs present_wait2 as well (`:785-790`), but it is off by default at
  the pin (`dxvk.enablePresentTiming`, commit e5ffd0f), and KK reports it unsupported
  (`wsi_common_metal.c:191-196`).
- **vkd3d-proton:** `chain->present.wait` (`swapchain.c:1476-1495`). Without it, vkd3d logs
  "supports neither present_wait1 or present_wait2. Latency will increase" and syncs to the
  present-request-done event (`:1585-1611`).
- **Expected effect:** lower input latency (the game waits for the screen), and the 0018 pacing
  regression back for a latency-1 game. Accurate presented times for DXVK's latency tracker
  (`notifyGpuPresentEnd`) and its FPS limiter.
- **Change:** `KK_PRESENT_WAIT` becomes `!TARGET_OS_IPHONE || KK_EXPERIMENTAL(PRESENT_WAIT)`, a
  runtime value, in both the extension and feature tables. The WSI already follows the device
  extension.
- **Size:** S code, M measurement. **Flag:** `present_wait`. **Cache key:** no.
- **Host test:**
  - the extensions only with the flag (the mock builds with the WSI platform? Check; if not, a
    unit check of the table);
  - MSL identical.
- **Phone gate:** the two `pp perf` route runs of the p99 evidence (`vk-v2-dxvk-p99-2`,
  `vk-v2-vkd3d-p99-1`), repeated with the flag on and off in ABBA order. Report late frames, p99
  and GPU ms, plus Hollow Knight first frame +10 with the flag on.
- **Done when** the numbers decide the flag. The expected outcome is "stays off" unless paired
  with C2.

### C2. DXVK's own latency control (measurement only, no driver change)

`dxvk.latencySleep=True` makes `DxvkBuiltInLatencyTracker`, which works without
`NV_low_latency2` (`dxvk_device.cpp:587-601`, `dxvk_latency_builtin.cpp:12-22`, `dxvk.conf:100-130`).
- **Run:** Hollow Knight on DXVK with `DXVK_CONFIG=dxvk.latencySleep=True`, with C1's flag on and
  off.
- **Why:** it tells whether a latency mode is worth having at all before C3. Graphics options
  only; no patch.

### C3. `VK_NV_low_latency2` (recommend deferring)

- **DXVK:**
  - Reflex (`D3D11ReflexDevice`, `d3d11_device.cpp:3540`) is used only when a game calls NVAPI
    Reflex. That needs dxvk-nvapi and an NVIDIA vendor ID. Playport ships neither (vendor
    `0x106b`).
  - With `latencySleep=True` the built-in tracker uses the extension when present, instead of its
    own algorithm.
- **vkd3d-proton:** only through `ID3DLowLatencyDevice` (dxvk-nvapi) (`device_vkd3d_ext.c:1184-1409`).
  With the extension it also creates an out-of-band queue (`device.c:2889-2910`).
- **Mesa:** no driver in this tree implements it.
- **What KK would need:**
  - `vkSetLatencySleepModeNV`;
  - `vkLatencySleepNV`, which signals a semaphore when the next frame should start, from present
    timing;
  - `vkSetLatencyMarkerNV`, `vkGetLatencyTimingsNV` and `vkQueueNotifyOutOfBandNV`;
  - the swapchain's latency create info;
  - all of it built on present id/wait. That is L, and nothing would call it by default.
- **Size:** L. **Flag:** `low_latency2`.
- **Recommendation:** defer until C1/C2 show a latency mode is wanted. If one is, DXVK's built-in
  algorithm (C2) already gives it.

## Ordered chunk queue

There is one writer at a time. The branch is now in the main checkout; the side copy is
detached. Each chunk ends in a commit with its checks passing; pending phone gates remain
in the Runner state's queue.

| # | Chunk | Size | Flag | Done when |
| --- | --- | --- | --- | --- |
| 0 | Side copy `.work/worktrees/kkparity` on `dev/kk-proton-parity` (0117 rewrite, marker); baseline `run.sh` and its MSL saved as the byte-identity baseline | S | — | Marker in place. `pp build` verified in the side copy. Baseline host test passes and its `msl/` is kept under the side copy's `.work` |
| A0 | Phone baseline: `pp perf --cpu-prof` on Hollow Knight DXVK and `-force-d3d12`; [preliminary menu evidence](../evidence/2026-10-23-kk-descriptor-cpu-baseline.md) collected | S | — | **Gate not satisfied:** per-thread printed leaves quantified, but JIT/top-N/stack gaps and menu-only scope cannot establish total descriptor/CopyDescriptors cost. Recommendation INSUFFICIENT; supervisor decides next action, A2 not started |
| B1 | `memory_priority` | S | `memory_priority` | Mesa 0119. Host test: extensions only with flag, the calls accepted, MSL identical. Phone runtime gate passed with vkd3d logging limit (evidence above) |
| B3 | `shader_module_identifier` | S | `module_identifier` | Mesa 0120. Host tests passed. Phone smoke on both routes and 25 warm disk-cache identifier hits passed; phone miss/fallback unobserved, no performance claim (evidence above) |
| A2 | **Gated on A0.** Descriptor buffer core with the vkd3d 4-byte SSBO alignment (A1 folded in): properties, layout size and offset, `vkGetDescriptorEXT`, bind and offsets, push descriptors, meta save/restore | L | `descriptor_buffer` | Next free Mesa number (split if large; A1's alignment may be its own patch under the same flag). Host test: bytes equal to `vkUpdateDescriptorSets`; draws and clear-between-draws restore set 0; flag-off MSL byte-identical; vkd3d-engine MSL with 4-byte alignment compiles with `msl-compile.sh`; cache key hashes the alignment. Committed |
| A3 | Embedded immutable samplers (`vkCmdBindDescriptorBufferEmbeddedSamplers2EXT`) | S–M | `descriptor_buffer` | Next free Mesa number. Host test: a layout with embedded samplers draws; MSL identical |
| A4 | GPL with descriptor buffers (`gpl,descriptor_buffer`) | S | both | Host test: a DXVK-style library set with the flag links and draws |
| A5 | Phone gates for A (queued): Hollow Knight `-force-d3d12` with `descriptor_buffer`; DXVK with `dxvk.enableDescriptorBuffer=True`; `pp perf --cpu-prof` against A0 | M | — | Evidence file. vkd3d log shows the descriptor-buffer path. Rendering as flag-off. CPU per frame against A0 |
| D | Decision record 0159: which flags stay off, which become defaults; `finished.md` entry | S | — | Decision accepted by the owner |
| — | B2 (PLA-433), B4 (PLA-434), C1–C3 (PLA-435) | — | — | Out of this plan (Settled 3) |

**Why this order and not "B, then C, then A":**
- **B1 first.** It is the smallest and safest, and it proves the flag, host-test and MSL-identity
  plumbing (the GPL pattern) on this branch.
- **B3 next.** It is small, and it is the only B item with a real win (vkd3d's cache).
- **A1 moved up.** It is small, has a D3D12 win on its own, and without it A cannot be used by
  vkd3d-proton at all.
- **C1 kept before A.** It is S code, but its phone gate is a measurement expected to confirm
  0018.
- **A0 before A2.** Profile the phone first so the L chunk is justified by numbers.
- **B2, B4 and C3 out of the main queue.** Each either changes nothing as specified or cannot be
  reached or gated today; they wait for the owner.

## Risks across the plan

- **Patch load.** Every chunk is one more `patches/mesa` file to carry on the next Mesa move
  (`Offered-upstream: no`, by owner direction).
- **Host mock limits.** It checks the CPU side, NIR validation, MSL translation and recording.
  It renders nothing, so every correctness claim beyond MSL identity needs the phone.
- **Two layers with different defaults.** For DXVK, descriptor buffers need a config value that
  Proton does not set. "Proton defaults" then means DXVK stays on its legacy path on KK.
- **A19 GPU clocks.** C1 and any CPU win interact with frequency (the 0018 GPU ms rise). Measure
  ABBA, with `--cool`, as the p99 evidence did.
- **Overlap with other plans.**
  - FL12_2 (PLA-81): int64 atomics and descriptor buffer/heap are listed there too.
  - KosmicKrisp default (PLA-77): the extension table at its line 211–218.

  Share findings; do not schedule the same work twice.

## Open questions for the owner (answered: see Settled)

1. **A1.** It is a prerequisite for vkd3d descriptor buffers and a D3D12 win alone. Should it land
   as its own flag (`ssbo_align_4b`), or fold into `descriptor_buffer`?
2. **DXVK and descriptor buffers.** DXVK uses them on KK only with
   `dxvk.enableDescriptorBuffer=True`. Should Playport ever set that, against "Proton defaults are
   ours"? If not, A serves vkd3d-proton only.
3. **Descriptor buffer or heap.** DXVK prefers `VK_EXT_descriptor_heap`, and Mesa's runtime has
   `vk_nir_lower_descriptor_heaps`. vkd3d-proton's default is still descriptor buffers. This plan
   targets descriptor buffers; is a later heap chunk wanted?
4. **B2.** Drop it, or implement force-UNORM emulation (M) without a title to test it on?
5. **B4.** A spec-breaking partial int64 (min/max only, no results) behind a flag, or nothing?
   Shared with PLA-81.
6. **C.** Given that 0018 measured present wait as worse, is C1 still wanted only as a
   measurement? C3 is deferred unless C2 shows a latency mode is worth having.

## Summary

- **Every extension can be added behind a flag.** Only three change what the layers do on KK
  today:
  - `shader_module_identifier` (vkd3d's cache);
  - descriptor buffers (vkd3d only, and only together with a 4-byte SSBO alignment);
  - present wait (measured worse in 0018).
- **Memory priority and pageable memory** are no-ops on Metal's device-wide residency.
- **Depth bias control and int64 atomics** cannot be implemented faithfully through Metal.
- **`NV_low_latency2`** has no caller in Playport.
- **The plan's real work is A.** KK's NVK-style descriptor model makes it a close port of NVK's
  descriptor buffers, with no MSL change. It is worth doing only if A0's CPU profile shows
  descriptor emulation matters, and only after A1.

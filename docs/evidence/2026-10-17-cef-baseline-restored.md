# PLA-380 checkpoint: approved CEF baseline restored; helper budget not implemented

**Linear:** [PLA-380](https://linear.app/playportdev/issue/PLA-380),
[PLA-379](https://linear.app/playportdev/issue/PLA-379).
**Plan:** [low-VA CEF](../plans/2026-10-16-cef-low-va-build.md).
Owner direction, 2026-10-17: park V8; do the FEX cap independently. This is a
restoration-only checkpoint, not acceptance of the rejected V8 experiment or a
completed FEX policy. Starting HEAD `068b158`, branch `dev/pla-291-rockstar-launcher`.

## Restoration and private archive

Everything below happened before any app/CEF build, packing or device command.
Archive root: `$PLAYPORT_BUILD/agent-notes/pla379-parked/`.

- `entry-tracked.diff`: exact entry binary diff for the two dirty tracked files,
  `build/generated/cef-143.0.14.sha256` and `patches/chromium/series`.
- `original-0007.patch` and the original long-named patch copy: exact rejected
  patch; `candidate-series` and `candidate-payload.sha256`: entry inputs.
- `candidate-source/`: archived source diffs and fresh scratch replay of all
  115 stock/Playport patches. All 424 compared files matched live source.
- Checked reverse-application removed **only patch 0007** from live V8. The active
  Chromium series and payload record were restored byte-for-byte from HEAD.
  `baseline-source/` then replayed 114 stock/Playport patches and compared 422
  files, zero mismatches. This includes the previously dirty V8 `BUILD.gn`:
  its accepted cross-build adapter remains, not an unrecorded experiment.
- `out-stage-c-rejected/`: the entire former active 233-file candidate payload,
  moved without deleting or copying it. All hashes and the exact file set passed
  before and after the move.
- `Release_GN_x64_lowva-rejected/`: the entire rejected ninja output directory,
  moved out of `cef-src/src/out/Release_GN_x64_lowva`. The old output path is
  absent, so a later low-VA build cannot silently reuse its candidate objects.
  Do not move it back as a baseline. No ninja/GN/stock patcher was run.
- `notices/` and `app-cef-staging-entry/`: reflink-preserved entry notices and
  app staging. Prior diagnostics, reports, payload snapshots and logs remain
  intact at their original paths; their historical `out-stage-c` references now
  refer to the archived candidate, not the restored active path.

The approved complete `$PLAYPORT_BUILD/cef-src/out-pla379-baseline` was verified
against the committed record and reflink-copied into `cef-src/out-stage-c`.
Both have the exact approved **233-file set**. Normal `stage-payload.py` then
replaced app staging with **232 runtime files plus five matching notices**;
`verify_runtime` checked the exact 237-file set and every hash. The candidate
DLL is not in active payload or app CEF staging. Stock `Release_GN_x64` and
`out-stage-b` were untouched. No CEF rebuild was necessary.

| Input | SHA-256 |
| --- | --- |
| Restored baseline libcef.dll | `a07bb71d9f92f35222a7f2f19e778183167eb332beb4fcb655dca2aa62c19c9e` |
| Parked candidate libcef.dll | `13210e75e4056eb41cc0a32bdc85dc4f66425700d756957000d5952864faef44` |
| Restored context snapshot | `ab1090ad4b547fbd8047001f657ca1af6c15d871ccfbb40ff76b2b708f0ad99f` |
| Restored payload record | `5951703991289d0720ba71d3fcaf7142b3912c13509b91d933e7a54868d89c78` |
| Parked candidate record | `5c63b69e967a97feac27eaf6175a7cc74524bc62b2453406ec7b7029e065859e` |
| Unchanged notices record | `82aaaa0d0f0fd1b85009dd45a4ca382d5f332e430ec8e5060693c36cce95795b` |
| Parked patch 0007 | `bd5261c15b08a629a8da807c426e6201d5c49c5ce7723b2967f26887bf2f5cca` |

Raw replay logs, entry provenance, hashes and set counts are in
`reconcile-{candidate,baseline}.log`, `entry-provenance.json` and
`restoration-verification.json` under the archive root. These are private scratch
records, not committed runtime logs.

## FEX source finding: generation ceiling is not an aggregate process budget

Read-only trace of the currently patched `$PLAYPORT_BUILD/run/fex` found:

- `FEXCore/Source/Interface/Context/Context.h:138`: each Context owns a
  `SharedCodeBufferManager`. `Source/Windows/ARM64EC/Module.cpp:1041` creates
  the process's Context; JIT threads share its manager.
- `FEXCore/Source/Interface/Core/SharedCodeBufferManager.cpp:15-30,183-224`:
  first shared generation is 16 MiB; iOS rollover jumps straight to 128 MiB,
  not a per-thread doubling ladder. `StartMaximalCodeBuffer` also requests
  128 MiB; `Core.cpp:466-470` uses it when code-cache generation/loading is on.
- The constructor (`SharedCodeBufferManager.cpp:32-87`) halves refused pool
  allocations down to 1 MiB; it deliberately faults if even that fails. The
  buffer includes a guard page, excluded from usable translation bytes.
- Full code buffer → `JIT/JIT.cpp:1011-1031` → `Core.cpp:654-669` →
  `Arm64JITCore::ClearCache` (`JIT/JIT.cpp:807-814`) →
  `CPUBackend::AcquireNewSharedCodeBuffer` (`CPUBackend.cpp:369-380`). This
  allocates the successor **before** retiring the previous generation and
  switches lookup mappings/reset call-return predictions for safe retranslation.
- `CPUBackend.cpp:384-413`: old generations remain referenced when signal frames
  can return into their emitted code. The remote sweep (`:435-623`) migrates
  eligible parked threads, but skips threads in simulation or with pinned signal
  frames. Retries are bounded, not a guarantee that all generations retire.
- `CodeBuffer::~CodeBuffer` frees only after the final shared reference drops.
  Existing generation/sweep/pin logs are bounded. `patches/fex-port/0060` contains
  the 128 MiB growth/retry changes and documents the earlier 32 MiB ceiling's
  severe game retranslation cost; game defaults must remain untouched.

Consequently, merely replacing the maximum with 32 MiB is **not** a 32 MiB
helper-process cap: the first 16 + next 32 can coexist (48 MiB), two 32 MiB
successive generations can coexist (64 MiB), and signal-pinned generations can
extend that. These are source-derived possibilities, not fresh measurements.
Refusing a necessary successor or freeing/resetting a live generation is not a
safe budget implementation.

Escalated before implementation. Supervisor directed: **finish restoration only;
no cap implementation or accepted decision until the owner chooses semantics**.
The proposed narrow alternative is a launcher-scoped 32 MiB **generation ceiling**
with honest aggregate live/peak, allocation/retirement and retranslation/rotation
counters, preserving safe deferred reclamation. This alternative is **not yet
approved**, nor a hard aggregate budget. A hard process budget needs separately
approved coordinated safe-reclamation semantics. Decision 0112 is still unused.

Scope plumbing inspected but not modified: `PublisherLauncher.swift`,
`UI/LaunchersSettings.swift:30-75`, `LaunchCoordinator.swift:267-277` and
Madeira's `build/ntdll-unix/process_ios.c:880-978` CEF classification. The existing
CEF switch rule also covers games' CEF helpers, so it alone cannot scope this to
launcher Open or prevent inheritance into a publisher-launched game. No new
marker/cap exists, and no no-handoff-leak claim or test is made.

## Checks and limits

- `./pp test --quick`: exit 0, all passed; Swift omitted.
- `./pp names` and `./pp secrets`: exit 0, clean.
- Checked patch reversal plus full stock/Playport scratch replay: zero mismatches
  both before and after restoration. This is source reproducibility evidence,
  **not** cache-correctness testing.
- `verify-payload.py`, normal staging, independent payload/notices/runtime exact-set
  checks: pass. No tests added; runtime code is unchanged.
- `git diff --check`: pass. No staged files remain after the checkpoint commit.
- Disk: 590 GiB free, above the 100 GB stop threshold. No active producer started
  by this task; no build or phone process/PID to hand off.

**Not run:** app/CEF build, install, phone status, new Hollow Knight gate or
Rockstar Open. Latest previously recorded installed dev IPA remains
`887442a3cc4d1df4b782dcc77a6e9f3833c4e9fbe5dc2a2f63f344600c7a2f2a`
([prior evidence](2026-10-16-cef-fewer-processes-phone.md)); it is not a new result
or a cap-bearing IPA. Prior 896 MiB pool exhaustion (head 524 / tail 373 MB),
band peak 16,227 / 16,384 MB and footprint peak 6,169 MB remain historical only.
Baseline V8 range behavior is restored, so a future FEX cap must not be described
as fixing the band. No sign-in, credentials, RDR2/RDO or games observed this run.
No distribution approval; PLA-372 still gates that work.

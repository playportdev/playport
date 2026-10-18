# Jitless CEF code ranges: allocation change works, visual gate fails

**Linear:** [PLA-379](https://linear.app/playportdev/issue/PLA-379), under
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Result:** BLOCKED. The isolated desktop control shows the sign-in form; the
patched build shows only the dark Rockstar background. Do not promote this
payload or start PLA-380 on the strength of the allocation tests. Stage D has
not passed. No phone, app build/install, sign-in or game run in this chunk.

Run `c0a3880a-d948-4fb2-86be-af392b193d59` (Sol high) took over at `d989c6e`,
on `dev/pla-291-rockstar-launcher`. No concurrent CEF writer/build was present.
Only this evidence and the plan checkpoint are committed. Chromium patch 0007,
its series entry and the changed payload record remain **uncommitted**.

## Source and regression checks

All source references below are relative to `$PLAYPORT_BUILD/cef-src/src/`.
The preserved patch
`patches/chromium/0007-V8-leave-default-code-ranges-unused-for-jitless-isol.patch`
changes only `ResourceConstraints::ConfigureDefaults` and adds two upstream
resource-constraints tests. It uses `i::v8_flags.jitless`, not command-line string
matching. The non-jitless `min(kMaximalCodeRangeSize, virtual_memory_limit / 8)`
expression, its platform/virtual-limit guard, and `ConfigureDefaultsFromHeapSize`
are unchanged. Explicit range setters are not changed.

- `gin/isolate_holder.cc:160–198`: initialization precedes default constraints;
  `getDefaultIsolateParams` calls `ConfigureDefaults` with physical/virtual memory.
- `gin/v8_initializer.cc:274–290,537–575`: the caller's JS flags are parsed after
  feature flags, before V8 initialization. The patch therefore reads parsed state.
- `v8/src/api/api.cc:535–554`: under jitless the selected range size becomes zero.
- `v8/src/execution/isolate.cc:4305,7659–7660`: the isolate captures jitless;
  `RequiresCodeRange` is platform requirement AND not jitless.
- `v8/src/heap/heap.cc:5398,5948–5980`: the constraint is copied into the heap.
  Allocation occurs when `RequiresCodeRange() || code_range_size_ != 0`.
  Zero means maximal-default size **inside that branch only**. Jitless plus zero
  skips the branch and uses the ordinary page allocator. Without pointer
  compression each allocated code range belongs to one isolate's heap.

This explains the measured allocation reduction, **not functional correctness**.
In particular, embedded builtins and their runtime behavior must still work.
`Isolate::MaybeRemapEmbeddedBuiltinsIntoCodeRange` (`isolate.cc:5337`) already
returns when `RequiresCodeRange` is false, but that observation does not explain
or dismiss the failed visual gate.

### What the native tests establish

Previous producer logs were inspected, not replaced with a new expensive build:
`$PLAYPORT_BUILD/agent-notes/pla379-recovery/` contains the probe source, compiler
commands, link response files, logs and test scripts.

| Native `Isolate::New` case | Configured bytes | Actual code-region bytes | Probe exit |
| --- | ---: | ---: | ---: |
| Baseline, non-jitless | 536870912 | 536870912 | 0 |
| Baseline, jitless | 536870912 | 536870912 | 1 (expected red assertion) |
| Patched, non-jitless | 536870912 | 536870912 | 0 |
| Patched, jitless | 0 | 0 | 0 |

`probe-runtime-{baseline,patched}.log` measures the actual heap code-range pointer
and region after deserializing an isolate with the host snapshot, not allocation
requests. It links real native V8 objects from this Windows-target cross-build;
for the control only the API object is replaced with its baseline object. The
saved baseline API source equals pinned V8 HEAD. This is allocation coverage,
**not JavaScript-execution coverage**: a prior `Script::Run` experiment trapped
in baseline too (`probe-runtime-script-backtrace.log`).

The earlier `SnapshotCreator` experiment crashed during builtin generation
(`probe-snapshotcreator-backtrace.log`), and is not runtime acceptance. The real
`mksnapshot.cc:291–300` explicitly sets a code range for generating builtins;
`SnapshotCreatorImpl` configures/initializes the heap (`snapshot.cc:854–905`).
Successful normal snapshot generation therefore does not exercise a jitless
runtime with no code range. Both actual snapshot actions passed in the build.
No change to the heap-size API or snapshot-generator path was made.

The five real `ResourceConstraints` gtests (including
`ConfigureDefaultsCodeRange` and `ConfigureDefaultsJitlessCodeRange`) passed in
the previous standalone link, and the existing linked binary passed again in
this run. This was **not** the complete GN V8 unittest target. Logs:
`agent-notes/pla379-sol/constraints-tests.{log,exit}`. A fresh scratch replay of
0007 reproduces both live files byte-for-byte; the live V8 source was not edited
in place during this takeover.

## Recovery, producers and matching payload

Recovery was not repeated. Its raw `reconcile.log` records 114 patches (107 CEF
stock plus the then-formal series), 422 files compared, zero mismatches. The
baseline rebuild reproduced approved libcef `a07bb71d…`. Both
`cef-src/logs/lowva-pla379-{baseline,jitless}.exit` contain 0. The patched log
records all 11 steps, including API objects, host/Windows snapshot actions,
context snapshot and libcef link. No ninja/gen/stock patcher was rerun here.
Stock `out/Release_GN_x64` and `out-stage-b` were left untouched.

SHA-256:

| Input/output | Hash |
| --- | --- |
| Approved baseline libcef.dll | `a07bb71d9f92f35222a7f2f19e778183167eb332beb4fcb655dca2aa62c19c9e` |
| Rejected candidate libcef.dll | `13210e75e4056eb41cc0a32bdc85dc4f66425700d756957000d5952864faef44` |
| v8_context_snapshot.bin, both | `ab1090ad4b547fbd8047001f657ca1af6c15d871ccfbb40ff76b2b708f0ad99f` |
| chrome_elf.dll, both | `6ceaf1f1afa9dd96d8ec2b9082c3fe6e180c3960e3cc579bc13abf7c1aa67367` |
| Baseline complete payload record | `5951703991289d0720ba71d3fcaf7142b3912c13509b91d933e7a54868d89c78` |
| Candidate complete payload record | `5c63b69e967a97feac27eaf6175a7cc74524bc62b2453406ec7b7029e065859e` |
| Unchanged notices record | `82aaaa0d0f0fd1b85009dd45a4ca382d5f332e430ec8e5060693c36cce95795b` |
| Playport-BUILD-NOTICE.txt | `fc7020569616ffa2a574841e16a3982c1f9b1c40274048da33ee88f0152b595a` |

All 233 ninja outputs were hashed before assembly; only libcef differs from the
baseline record. `assemble-payload.py` verified all 233 copies. Notices were
regenerated with `generate-notices.py`; all five remain unchanged, including
BUILD-NOTICE and its statically linked MSVC CRT disclosure. Scratch staging with
`stage-payload.py` and `verify_runtime` verified the exact 237-file runtime/notice
set (the import library is omitted). **Hash verification is not UI acceptance.**

**Current build-area warning:** `cef-src/out-stage-c` and
`src/out/Release_GN_x64_lowva` contain the failing candidate. Do not pack them into
an IPA. The known-good complete payload is preserved at
`cef-src/out-pla379-baseline`; its unchanged 233-file record is
`agent-notes/pla379-sol/baseline-payload.sha256` (also the committed record at the
takeover HEAD). The working-tree record currently names the failing candidate;
it is intentionally not committed as a finished output. No release/distribution
approval is implied; PLA-372 still gates distribution.

## Corrected isolated desktop comparison

Sway IPC and display access were checked first: the sway-nocap process owned
`wayland-1` and X0; `xdpyinfo` on `:0` worked. Both runs explicitly used
`DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-1`, never the owner's niri session.
Proton's Steam clients and URL opens were disabled, with an empty scratch Steam
client-install directory. No input, sign-in or consent was performed.

An initial sway pair is **diagnostic only**: the inherited runner's exact
WINEPREFIX comparison missed detached processes whose prefix ended in `/`.
The first patched run consequently overlapped control survivors. Cleanup was
fixed to normalize that slash. With supervisor approval for this identified
host setup error, exactly one corrected pair was run. Each began from the same
saved `prefix-before-sway`; canonical `/proc` prefix scans were empty before and
after each run. Only individually attributed scratch-prefix PIDs were signalled.
The protected `pla254-rockstar/prefix/` was not used or modified.

Acceptance run directories under `agent-notes/pla254-rockstar/runs/`:

- `pla379-sol-isolated-baseline`
- `pla379-sol-isolated-patched`

Both were bounded at 90 seconds, with a 180-second wrapper timeout. Wrapper,
runner and Proton producer exit codes are 0 in both; this says nothing about
visual success. Both used the complete matched payload and the 0111 set:

```
--in-process-gpu --disable-gpu --disable-gpu-compositing
--js-flags=--jitless
--enable-features=NetworkServiceInProcess2,RunVideoCaptureServiceInBrowserProcess
```

| Observation | Baseline | Candidate |
| --- | --- | --- |
| WAIT_BROWSER_WINDOW (ms) | 43 | 37 |
| LOADING / WAITING_FOR_PAGE_LOAD | 475 / 475 | 451 / 452 |
| WAITING_FOR_PAGE_READY | 2295 | 2303 |
| PAGE_READY / START_SIGN_IN | 2463 / 2463 | 2470 / 2470 |
| FINISHED | 2476 | 2483 |
| CEF processes at 90 s (wrapper excluded) | 6 | 6 |
| Renderers at 90 s | 3 | 3 |
| 30/60 s screenshots | Sign-in form and cookie notice | Dark patterned background only |
| Candidate 90 s screenshot | — | Still no form |

The six persistent CEF processes are browser, storage, audio and three renderers;
no separate network/video process. There is no observed CEF fatal/check failure
or snapshot error in the captured Wine stderr. A stack-overflow line for process
0114 appears in **both** traces, not a patch-specific renderer failure. The
candidate's preserved `chrome_debug.log` contains software-WebGL fallback and
ReadPixels stall messages, not a V8 fatal. Its helper log records the browser
and renderer IPC connections. Those logs do not establish the cause of the
missing sign-in form. No further desktop run or speculative fix was attempted.

### Held reservations, not failed hints

`vfilter64.py` records successful `BIG ... -> VIEW start-end` reservations and
frees. Seven successful 512 MiB views appear in the control, all in renderers;
one is later released with MEM_RELEASE (`8000`). MEM_DECOMMIT (`4000`) does not
release the address reservation and is not subtracted. Failed `NOVIEW` hints
are not counted. The candidate has no 512 MiB view or request in this trace.

| Renderer (Windows PID) | Control peak held ranges | Control retained at trace end | Candidate retained |
| --- | ---: | ---: | ---: |
| 1: 0468 | 2 | 1 | 0 (0468) |
| 2: 0594 | 1 | 1 | 0 (0594) |
| 3: 0704 | 4 | 4 | 0 (06fc) |

Thus the control trace ends with six held ranges, **3,221,225,472 bytes (3 GiB)**,
versus zero for this class in the candidate. This is a filtered-trace retention
calculation, not an independent final VirtualQuery inventory or a count of live
JS isolates. The native allocation probe separately establishes 512 MiB → 0
per tested jitless isolate. Other large pools/placeholders remain; these figures
are not total process VA or footprint. Lower reservations do not outweigh the
failed visual gate. Raw calculation: `agent-notes/pla379-sol/reservation-comparison.json`.

Both corrected runs restored the scratch Social Club originals and verified all
81 hashes plus the exact file count. Final verification again found no canonical
prefix PIDs; `runs/pla379-sol-restored.sha256` records the restored files.
Screenshots and private logs stay under `.work`, not in this evidence directory.

## Validation and stop point

- `pp test --quick`: exit 0, all passed; Swift omitted by that option.
- `pp names` and `pp secrets`: clean; `git diff --check`: passed.
- Five existing linked V8 resource-constraints gtests: exit 0, five passed.
- Patch replay: both affected files byte-identical to live source.
- Baseline/candidate payload and notices verification, scratch runtime staging:
  passed; logs in `agent-notes/pla379-sol/`.
- Desktop visual gate: **FAILED**. PLA-379 is not complete. Implementation,
  series and payload-record changes remain pending and uncommitted.
- No `pp build/check/install`, device smoke/Hollow Knight, Rockstar phone Open,
  FEX cap, sign-in, RDR2/RDO, source acquisition or toolchain-policy change.

Next is focused review of this failed candidate and an approved open-source
runtime/debugging direction, not PLA-380 or a combined phone build. The current
unit/allocation harness must not be presented as a successful JS runtime test.

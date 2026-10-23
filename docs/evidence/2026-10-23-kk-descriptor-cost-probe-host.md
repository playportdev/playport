# KK descriptor-cost probe: host validation only

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **Plan:**
[Proton parity](../plans/2026-10-22-kk-proton-parity.md), A0 measurement queue item 1.
Mesa **0121**, diagnostics only, default off. **No phone commands, game launches,
CPU-cost conclusion or A2 authorization.** Independent review precedes client integration
and owner-coordinated existing-save gameplay. The earlier menu sampler remains
[insufficient](2026-10-23-kk-descriptor-cpu-baseline.md).

## Source, coverage and overlap

`MESA_KK_DEBUG=descriptor_stats` uses debug bit **16**, after `vertex_stats`;
experimental bits 16/17 remain separate and unchanged. Future phone activation is
through the existing dev Graphics options UI; no new setting or entry point.
Payload: `kk_debug.{h,c}`, `kk_descriptor_stats.h`, `kk_descriptor_set.c`,
`kk_cmd_buffer.c`, `kk_queue.c`, and the supervisor-approved `kk_device.{h,c}`
for embedded per-device state/init/final reporting. No registry, diagnostic TLS,
per-call allocation or hot-path lock. Counters are initialized before fallible device
initialization, including its failure tail; generation and init timestamp identify
separate device lifetimes. Submit reports follow the existing pass/vertex pattern;
final reporting is after device resource teardown, not at an early queue teardown.

Ten **disjoint** entrypoint scopes: `pool_create`, `allocate`, `free`, `pool_reset`,
`pool_destroy`, `update`, `template_update`, `bind`, `push`, `push_template`.
Allocation rollback calls the original untimed free implementation: its work belongs
only to `allocate`, not a second external `free`. Common Vulkan wrapper/trampoline
work, descriptor layout/template creation/destruction, push constants, render-pass
attachments and shader resource loads are **excluded**. Templates here mean template
updates, including template pushes. No independently timed write/copy children exist.
Within KK, valid disjoint elapsed totals may be summed across operations/threads
(they are not a process wall-time union). **Never add KK totals to client Vulkan or
client-inclusive envelopes.** KK alone does not cover client preparation/copies.

Calls and work are requested API work, including failed requests. Writes/copies
separate records, descriptor elements and **inline-uniform bytes**. Templates count
entries as write records. A combined graphics/compute bind/push counts its API inputs
once, not once per stage. `sets`: pool-create capacity, allocate/free requested slots,
bind requested sets, reset/destroy live sets actually traversed. Pool entries/elements/
inline bytes describe requested capacity. `failures` counts non-success Vulkan results,
or command recording error present at push exit (not necessarily a newly caused error).
Null pool destroy still counts a call with zero sets.

## Schema, clock and boundaries

Every line starts `[kk-descriptor] v=1 component=kk kind=...` with whitespace-separated
`key=value` fields. Kinds: `enabled`, `calibration`, `snapshot`. Enabled coverage banner
states exclusions, disjoint rollback accounting, and `cpu_clock=unsupported`.
Snapshot identity: `pid`, `device` generation, `init_ticks`, per-device `snapshot`.
All numerical telemetry is integer: `ts_begin`, `ts_end`, `hz=1000000000`, cumulative
`frames`, `final`, `clock_ok`, `report_clock_errors`, `overflow`, `quiescent`,
`entered_before/completed_before/entered_after/completed_after`, `op`, then:

```
calls sets write_records write_elements write_bytes
copy_records copy_elements copy_bytes dynamic_offsets
pool_entries pool_elements pool_bytes failures timed_calls
elapsed_ticks max_ticks clock_errors active
```

`frames` counts drawables signalled by successful queue submissions, following the
existing queue frame denominator, not independently observed display refreshes.
Snapshots emit all ten operations on the first submit, about once per second on
subsequent submits, and on orderly destruction. No submits means no periodic reports;
abrupt termination may lose the final tail. Failed report clocks emit one failure
snapshot per failure episode plus final, rather than logging on every submit.

**Elapsed, not CPU time.** Inspection found `os_time_get_nano()` ignores the return
from `timespec_get` and can use uninitialized data on failure. The supervisor explicitly
approved using the **same Mesa `c11/time.h` monotonic primitive directly**, checking
every read's return, zero-initialized timespec, nonnegative seconds, nanosecond range
and conversion overflow. No common helper edit or CPU-clock bridge. Invalid/zero or
backwards scope timestamps increment `clock_errors` without a valid timed call;
zero elapsed from two valid equal timestamps remains a quantized measurement, not
proof of zero work. Report-clock errors have a separate cumulative count. Unsupported
CPU time is a string status, never a numeric zero. Counter overflow saturates with a
sticky invalid-sequence flag; publication counter wrap also invalidates the sequence.

Payload atomics are relaxed, bracketed by seq_cst entered/completed publication and
snapshot fences. `quiescent=1` means unchanged equal publication counts during counter
capture, **not an event-time transaction**. Other snapshots may mix different stages
of publication. `calls` counts entries, elapsed/failures count completed scopes;
`active` and cumulative `max_ticks` expose incomplete work but cannot bound an
arbitrarily long active scope. Future parsing must reject missing rows, overflow,
clock errors and unsafe/concurrent boundaries, or supply explicit finite uncertainty;
never subtract independently windowed child/client totals. Capture lies somewhere in
`[ts_begin, ts_end]`; frames are another relaxed read in that range. Operations starting
or completing near either edge can belong to the adjacent delta. Orderly final does
not override active/incomplete/error indicators. There is no safe zero assumption for
an absent final report, absent operation, unsupported clock or zero-frame interval.

Enabled init emits **16 bounded raw calibration samples**, six checked reads each:
adjacent-read delta and an outer empty-scope delta including checked clocks and atomic
publication; each has an explicit validity flag. Scratch counters do not contaminate
operation totals. No overhead is subtracted. Host sample values and logs are not iOS
resolution/overhead evidence; device calibration, enabled atomic contention, on/off
controls and worthwhile workload budget remain mandatory later.

## Host tests and optimized disabled path

Fresh pre-change runner and MSL copy retained under
`$PLAYPORT_BUILD/agent-notes/kk-parity/`. The runner rsyncs the edited source tree into
`run/mesa/hosttest/mesa`; final delivery is the format-patch/series, not that scratch tree.
New `kk-descriptor-stats-test.c` links the real diagnostic object and Mesa clock object.
It checks failed/invalid/overflow clock conversion, backwards/missing/quantized scope
ends, max/active invariants, saturation, report-clock failure suppression, periodic
throttling and exact two-thread publication after join. The Vulkan fixture is appended
**after existing flag checks**, avoiding historical MSL numbering changes.

API fixture verifies all ten operation counts and work units, mixed writes/copies,
inline bytes, template updates, dynamic offsets, push/template push, pool-create
failure, partial allocation rollback and recovered allocation. Two concurrent empty
update publishers total 2,000 calls. Two simultaneously live devices plus a failure
after device allocation produce three distinct initialized sequences; neither empty
sequence inherits the measured device's counters. Diagnostics-off emits no probe
lines; `descriptor_stats,vertex_stats` preserves both flags' output.

The unchanged established **185-file** MSL prefix matches the fresh pre-change copy
by filename and bytes. Diagnostic off/on runs each produce **219 files**, all identical
including the extra fixture devices; **44 `ok` labels** each (43 existing, one fixture).
Full host runner and Zink mock pass; Zink produces **25** MSL files. No GPU executes.
Cache UUID/build-ID inputs, shader generation, feature/default flags and pins are
unchanged; rebuilding naturally changes the existing build identity.

Inspected all ten optimized public paths using host GCC `-O2` (generated flags/includes)
and the actual release iOS arm64 objects with `objdump`/`llvm-objdump`. An initial host
inspection found stack-protector TLS induced by scope locals in public functions;
enabled-only noinline diagnostic helpers fixed it before the final build. Final disabled
paths have one added debug-bit test and **no diagnostic clock, TLS, counter atomic,
logging or work-count traversal**. Original descriptor processing/reference-count
atomics, prologues and branches remain. This is static path inspection, not proof of
zero instruction/cache/layout overhead, a whole-program proof, or an on-phone control.

## Built artifact

Main-checkout `./pp build` exits 0; verified dev IPA:
`$PLAYPORT_BUILD/out/20261023-093752-1a7935b2/Playport-26.5-1a7935b2.ipa`, SHA256
`1a7935b20aa98b88e394087111eec4384bb6e47730756104d2b16b7f51d9fedf`.
**89 checks passed, 0 failed.** No changed `app/artifacts.tsv` or generated Wine PE
manifest rows. No install/smoke/gameplay/calibration run on the phone.

**Not an exact committed-source IPA:** includes the protected owner's uncommitted
SettingsView edit (file SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`, diff SHA256
`3e371c630d659be316befde9e60824ae0a4be12f44a52084d1595740532ea7b9`). It remains
byte-identical to the private snapshots, unstaged and uncommitted. The production
Mesa payload is the final 0121 patch; no client/parser changes are included.

## Reproduction and remaining gates

The final commands below exited **0**, using `PLAYPORT_BUILD=$PWD/.work` and
`TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp`, foreground waits up to 1,800 s:

```sh
build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host .work/run/mesa/hosttest
./pp build
./pp test --quick
./pp names
./pp secrets
```

`pp test --quick`: **712 Python tests and 26 C test groups passed** (Swift intentionally
omitted); standalone names/secrets clean. Exact-path whitespace/private/home-path
review passed; canonical format-patch blank context lines retained (plain outer
`git diff --cached --check` flags those 31 lines, but source/addition whitespace and
all non-patch files are clean). Owner file and diff still match snapshots. Logs: `a0-kk-{baseline-host,host-final,build-final,test-quick,names,secrets}.log`
under `$PLAYPORT_BUILD/agent-notes/kk-parity/`; optimized assembly/objects use
`a0-kk-O2-*` and `a0-kk-ios-*`. No logs, screenshots or private paths committed.

Next writer is **DXVK only**, then vkd3d, parser/integration and independent review.
Device calibration, diagnostic-off/on controls and the runtime smoke gate are
**unrun**. Only after review/workload coordination may the owner play their save.
No setting/default/cache-key/extension/client changes or descriptor-buffer work here.

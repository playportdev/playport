# Descriptor emission: bounded KK producer correction, host only

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**2026-10-23. Mesa 0122; independent review and phone reenactment pending.**
This targets the actual KK multi-write splice from [device prep](2026-10-23-descriptor-probe-device-prep.md), not a completed device fix or measurement gate.
No phone/install/UI/perf/game commands, save/cache changes, parser edits, new
activation, logging bridge, defaults or pins. A2–A4 remain not started.

## Actual sink and diagnosis

Narrow source inspection before choosing the fix:
- `app/Sources/S1Probe/AppLog.swift`: the app/runtime share `s1-host.log`.
- `app/Sources/WineHost/wine_host.c:1291–1322`: normal dev initialization opens
  the file with `O_WRONLY|O_CREAT|O_APPEND`, then `dup2`s it onto fd2.
  `g_log` separately opens append mode. Stamped profiling can replace stderr
  with a pipe; the dev size cap later diverts stderr to a counting pipe.
- `app/Sources/HostIO/host_log.c:31–51`: normally stdio stderr, or an independent
  append descriptor/writev before stderr names the log. Its FILE lock is not a
  shared writer protocol.
- `$PLAYPORT_BUILD/run/unix/mythic/wine/dlls/ntdll/unix/debug.c:202–212,274–319`:
  stderr unbuffered; client debug output goes directly through `write(2,...)`.
- `$PLAYPORT_BUILD/run/vulkan-pe/dxvk/src/util/log/log.cpp:48–103`: independent
  logger mutex; Wine output; lines over1018 bytes deliberately split.
- Old KK `kk_debug.c:486–503`: `flockfile(stderr)`, prefix fprintf, eighteen
  field fprintf calls, newline fputc. That lock cannot exclude Wine raw writes.

**Primary hypothesis reproduced:** independent raw append between real KK
`write_records` output and the next field produces `write_records=0info:` plus
continuation fragments, exactly the observed mechanism. This does not require
client length splitting or app multiplexing. The original malformed rows also
include CB_SUMMARY; changing DXVK alone would not cover them. DXVK long-line
policy and app cap/stamp behavior remain independent limitations, not globally
ruled out or changed here. No claim that all client records now work on-device.

## Narrow production correction and guarantees

Only `kk_debug.c` and `kk_descriptor_stats.h` change in format-patch0122.
Source-local checked `vsnprintf` appends build a complete row into2048 stack
bytes, including its newline; no silent truncation. Banner, calibration and
snapshot rows each use one direct `write`, not fwrite/stdio assumptions.
The strict v1 snapshot schema has a conservative1097-byte maximum including
newline (20 digits per u64,20-character signed pid, longest operation name).
The max-u64 execution fixture observes1074 bytes with actual host pid/timestamps.

Supported inter-writer guarantee: a successful complete write to the normal
local **O_APPEND regular file** cannot have another appender inserted inside
that write. Separate O_APPEND handles are covered, not independent non-append
handles with unrelated offsets. Existing other writers may themselves produce
partial lines; this change neither repairs nor serializes them. Terminal/device
sinks and downstream relays have no general record guarantee.

For pipes/FIFOs check actual `_PC_PIPE_BUF`; reject a row larger than that bound
or an indeterminate bound. Linux4096-byte pipe fixture passes. A512-byte pipe
bound is explicitly unsupported for snapshot rows and fails closed, rather
than claiming regular-file atomicity. Stamped/cap-diverted modes and downstream
file forwarding are not verified by this host test; log caps may deliberately
discard output. Guarantees assume fd2 is not concurrently redirected between
sink inspection and write; the existing diversion machinery shares no new lock
with this emitter. No pipe-size assumption is made for iOS.

Failure policy (supervisor explicitly approved this limited contract):
- Format error/overflow, failed sink inspection, oversized pipe row, write error
  or exhausted EINTR retries latch per-device emission failure.
- At most three attempts for `-1/EINTR` (no bytes transferred). Never retry or
  continue a positive short write, including a missing final newline.
- Stop remaining/current and all future device report output. The latch is
  accessed inside the existing report guard, not a new hot-path lock.
- One best-effort separate malformed `[kk-descriptor] emission failed` marker
  invalidates strict parsing **if delivered**. It cannot guarantee detection on
  an unrecoverable sink. The regression explicitly shows that a terminal short
  missing only the final newline, followed by failed poison, leaves all fields
  and **can be accepted by the unchanged strict schema**. This is not proof of
  complete lifetime/tail/transport success; no universal loss-detection claim.

Schema, activation/default-off guards, operation counters and hot callbacks,
clock primitives/checks, calibration sample count/brackets and snapshot timing
boundaries are unchanged. Formatting/output remains outside timed operations
and calibration brackets. Reporting overhead changes; no perturbation/performance
claim and no calibration subtraction.

## Red before fix; actual-emitter green and stress

New `build/mesa-host-test/kk-descriptor-emission-test.{c,py}`, wired into `run.sh`,
compile/link the **real production kk_debug.c** with host-only linker wrappers
for deterministic stdio/syscall/format faults. No production test entrypoint,
environment channel or duplicate printf implementation. Independent writer uses
raw writes and a separate O_APPEND open file description, never stderr's FILE
lock. Condition variables, not sleeps, schedule the old mid-record collision;
free-running stress adds uncoordinated competition.

Commands use `PLAYPORT_BUILD=$PWD/.work` and
`TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp`. Notes below are relative to
`$PLAYPORT_BUILD/agent-notes/kk-parity/`:

```sh
python3 build/mesa-host-test/kk-descriptor-emission-test.py \
  .work/run/mesa/hosttest/build \
  .work/run/mesa/mesa/src/kosmickrisp/vulkan/kk_debug.c \
  .work/agent-notes/kk-parity/emission-red append
```

**RED exit1 before production edit**, `a0-emission-red.log`: strict parser
`malformed key=value token` at the real prefix/field boundary. Baseline source
is committed tree5ddf7d2; retained `emission-red/kk_debug.committed.c` SHA256
`78c5b036d9f65ef09b939027963a0540ee4411e8807c21d34d502f785dc2404f`,
identical to then-unedited production. Refined seam replay of that exact source
(`a0-emission-red-exact.log`, `emission-red-exact/`) fails specifically after
`write_records=0info:`. No old production source or raw device evidence rewritten.

Same runner against fixed source, no explicit mode filter: **GREEN exit0**,
`a0-emission-green.log`, `emission-green/`:
- Append and actual Linux pipe:20 snapshot rows each, no malformed; complete
  real banner/calibration and two snapshots yield strict CLI exit0 usable interval.
- Max-u64:10 schema-valid rows; bound/observed lengths above.
- Negative/overflow formatting, EIO, repeated EINTR and positive short writes:
  stop device emission; delivered malformed poison rejected. Two EINTRs then
  full write succeed; exhaustion after three attempts fails closed.
- Terminal newline-only short:10 syntactically complete rows, missing newline,
  poison fails; accepted-schema limitation explicitly asserted.
- Simulated512-byte pipe bound:0 snapshot rows, malformed failure marker.
- Stress seeds1,431,3735928559:4010 exact snapshot rows each,0 malformed,
  versus4000 independent PRNG-sized writer bursts; each producer bounded15s.

Full Mesa host suite command:
```sh
build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host .work/run/mesa/hosttest
```
Exit0, log `a0-emission-mesa-host.log`; full emission matrix repeats green.
Pre-fix236-file descriptor-off MSL copy `emission-baseline-msl/` matches current
236-file off prefix byte-for-byte;236/236 off/on identical, no new device/MSL
suffix. Existing replay0/1/2/2 and3/3/4/5 counts preserved; Zink25 libraries/ok.
Unchanged focused parser suite33/33 passes (`a0-emission-parser-tests.log`).
This mock suite compiles/records; it executes no GPU workload.

## Build, hygiene and remaining gate

`./pp build --variant dev` producer exit0; `a0-emission-build.log` records
**89 checks passed,0 failed**. New unsigned verified dev IPA:
`.work/out/20261023-201226-9d0d2b2a/Playport-26.5-9d0d2b2a.ipa`, SHA256
**`9d0d2b2a37387c790c24b7fc68fdbc1745a74c3d5f3f391fdde0a7b7ac9dc494`**.
Includes the protected uncommitted owner SettingsView edit: **not exact
committed-source provenance**. No installation. No actual main build-record
rows changed (`app/artifacts.tsv`, `build/generated/wine-pe-*.tsv` clean).
Build reconstruction's KK c/h contents match the pre-build format-patch source.

`./pp test --quick` exit0:745 Python tests and26 C groups, all passed (Swift
excluded); separate `pp names` and `pp secrets` clean. Logs
`a0-emission-{quick,names,secrets}.log`. Unchanged parser rerun against the
original full device log still exits1 with0 usable/17 malformed/86 rejected;
new text result `a0-emission-original-still-invalid.txt`, not a replacement for
original parser outputs. Original raw/parser-output hash manifest passes.

Owner SettingsView SHA256 remains
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`;
file and diff cmp with the protected snapshot/owner.diff pass. Never edited,
staged or committed. Exact-path staging, whitespace/private/home checks,
commit and empty final index are recorded in the worker report under
`$PLAYPORT_BUILD/agent-notes/kk-parity/reports/a0-emission-fix.md`.
Independent review is required **before** a separately authorized bounded phone
prep retry. D3D12 calibration and selected Simple path remain unrun; no usable
phone intervals, CPU-cost attribution or descriptor-buffer justification claimed.
Original enabled raw log SHA256 remains
`f2668220bff3198b977d7f412ba6c17f99432ef35dbdc1fc7eef912f57947fac`;
it must remain bad after this producer correction. Phone/setup/state facts from
prior prep are historical only; this worker neither queried nor changed them.

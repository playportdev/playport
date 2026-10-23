# Descriptor emission: supported-sink enforcement, host only

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
**2026-10-23. Mesa0123 follow-up to0122; independent re-review PENDING.**
Addresses the P1 from independent review of `68e5eab`:0122 accepted every
successful non-FIFO fstat, silently allowing non-append files and unsupported
sink types. This is not self-clearance of that review or a device-wire pass.
No phone/install/UI/perf/game commands, parser/schema changes, client/app/bridge
changes, save/cache changes, activation/default/pin changes or A2 authorization.
Prior [device prep](2026-10-23-descriptor-probe-device-prep.md) remains blocked.

## Minimal production correction

0123 changes only `src/kosmickrisp/vulkan/kk_debug.c`: add `<fcntl.h>` and enforce
exactly these supported sinks before submitting a complete descriptor row:
- Regular file: `fcntl(fd2,F_GETFL)` succeeds **and** O_APPEND is set.
- FIFO/pipe: whole row fits a known positive runtime `_PC_PIPE_BUF`.
- All other types, failed flag queries and unsupported lengths: use the existing
  emission-failure latch and one best-effort malformed poison attempt.

Production source diff:9 insertions/3 deletions, including a matching constraint
comment.0122 unchanged. Existing checked2048-byte formatting, single-write path,
three bounded EINTR attempts, no positive-short continuation, failure latch,
calibration/clock semantics, counters/hot callbacks, schema and default-off guards
are unchanged. No stack/security compiler flags changed or test bypass added.

The stable-fd2 precondition remains: no synchronization with concurrent fd2
redirection/flag changes is introduced. Local append/PIPE_BUF atomicity does not
promise downstream relay integrity or make other writers' partial lines whole.
Approved terminal edge remains: a final newline-only short followed by failed
poison can leave a schema-complete record. Poison delivery is not guaranteed;
no complete-lifetime/transport-success or universal loss-detection claim.

## Real-emitter regression: RED before fix, GREEN after

New fixture modes in `build/mesa-host-test/kk-descriptor-emission-test.{c,py}`:
`nonappend`, `unsupported-null`, `unsupported-type`, `getfl-error`, and
`nonappend-after-init`. Tests compile the real emitter, not a printf model.
Existing host-only linker seams now also wrap Linux Mesa's actual large-file
symbols `fstat64` and `fcntl64`. Normal cases call the real APIs unchanged;
only named fault cases inject socket type or F_GETFL failure.

First four cases were added/run **before any production edit** against the
committed0122 source `f05a5b4`. Each returned expected RED/exit1 and printed:

```text
latch=0 record_writes=37 poison_writes=0 writes=37
stat_queries=37 flag_queries=0 future_writes=20
```

The regular counterexample is really opened without O_APPEND and its actual
flags asserted; it is never silently made append-mode. `/dev/null` is an actual
character device in this host test. Injected socket type uses the real fstat
result with only st_mode replaced. Failed flag-query seam demonstrates that old
0122 never queried flags at all. Exact baseline source retained at
`$PLAYPORT_BUILD/agent-notes/kk-parity/emission-sink-red/kk_debug.0122.c`, SHA256
`107a6987ebc2bdc9e12ec725e4b18286964f72ce22b097ed011155f8032097ae`.

After the minimal predicate fix, every case prints:

```text
latch=1 record_writes=0 poison_writes=1 writes=1
stat_queries=1 future_writes=0
```

F_GETFL queried exactly once for nonappend/getfl-error, never for unsupported
types. No enabled/calibration/snapshot row submitted; one poison write attempt
only. File-backed cases contain one malformed marker; real `/dev/null` contains
nothing, honestly proving only the attempt/latch, not poison delivery.

Additional `nonappend-after-init`:17 valid enabled/calibration rows first, then
explicitly clear O_APPEND before the first snapshot (no concurrent fd change).
Exact0122 replay RED:30 record writes after transition,20 future writes, no latch.
GREEN:0 snapshot record writes,1 poison attempt, latch1,0 future writes; remaining
snapshot operations and later reports suppressed. Both tests assert no future
formatting as well as no future write attempts.

Commands (all deliberate scratch/logs under repository `.work`):
```sh
export PLAYPORT_BUILD="$PWD/.work"
export TMPDIR="$PWD/.work/agent-notes/kk-parity/tmp"
python3 build/mesa-host-test/kk-descriptor-emission-test.py \
  .work/run/mesa/hosttest/build \
  .work/run/mesa/mesa/src/kosmickrisp/vulkan/kk_debug.c \
  .work/agent-notes/kk-parity/emission-sink-green
```
Focused matrix exit0. Notes under `$PLAYPORT_BUILD/agent-notes/kk-parity/`:
`a0-emission-sink-red-{nonappend,unsupported-null,unsupported-type,getfl-error}.log`,
`a0-emission-sink-red-late.log`, `a0-emission-sink-green.log`; outputs in
`emission-sink-{red,red-late,green}/`. Each child producer bounded15s; targeted
commands60/120s, no sleeps/polling. Existing valid append/pipe intervals, max-u64
1074-byte observed/1097-byte conservative bound, format/overflow/EINTR/error/short
cases and three stress seeds1,431,3735928559 remain green; each stress4010 rows,
0 malformed. Approved newline-only short edge still explicitly schema-accepted.

## Actual supported host captures and full suite

Only diagnostic capture setup changes in `build/mesa-host-test/run.sh`:
- API fixture `descriptor-{off,on}.log`: truncate once, then shell `>>` opens the
  producer's stdout/stderr in append mode.
- Linked real descriptor helper: truncate once, then Python `open('a')` supplies
  actual O_APPEND fd for stdout/stderr.
- No C helper/accounting model or GPU mock change; no production sink change or
  normal-test predicate bypass. Negative nonappend fixture remains nonappend.

Full suite command:
```sh
build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host .work/run/mesa/hosttest
python3 -m unittest discover -s tools/tests -p test_descriptorprof.py
```
Both producer0. `a0-emission-sink-mesa-host.log`: full Mesa/NIR/mock/flag suite,
real API/helper reports and complete emitter matrix pass. Pre-change236-file
MSL copy `emission-sink-baseline-msl/` matches new descriptor-off output
byte-for-byte;236/236 off/on identical, no added device/MSL suffix. Replay counts
remain secondary0/1/2/2 and reusable3/3/4/5 for bind/push/template-push. Zink ok,
25 MSL libraries. No GPU executes. `a0-emission-sink-parser-tests.log`: unchanged
strict parser33/33 pass. No parser input filtering/reconstruction or schema edits.

## Build/hygiene and remaining gate

`./pp build --variant dev` producer0, **89 checks passed,0 failed**. New verified
unsigned dev IPA `.work/out/20261023-203743-689b9479/Playport-26.5-689b9479.ipa`,
SHA256 **`689b9479ff6d6910bf7d96fa359259345bd8ef1406ab7c361833800c7b9b7a4e`**.
Not installed. Includes protected uncommitted owner UI: not exact committed-source
provenance. No actual main build-record rows changed. Source commit `e05ab1b`
exported via format-patch0123 before build; reconstructed `c72136c` content matches.
Complete emitter matrix repeated green against reconstructed source
(`a0-emission-sink-reconstructed.log`). Build log `a0-emission-sink-build.log`.

`./pp test --quick` producer0:745 Python tests,26 C groups, all passed (Swift
excluded); `a0-emission-sink-quick.log`. Separate names/secrets, exact owned staging,
source/patch/private/home checks and final empty index recorded in the worker
report `$PLAYPORT_BUILD/agent-notes/kk-parity/reports/a0-emission-sink-fix.md`.
Original raw/parser hash manifest passes; unchanged parser still returns
exit1/0 usable/17 malformed/86 rejected on original full log, retained only as a
new result `a0-emission-sink-original-still-invalid.txt`, not rewritten evidence.
Protected owner SettingsView stays uncommitted, hash
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`.
Original readonly raw device log remains
`f2668220bff3198b977d7f412ba6c17f99432ef35dbdc1fc7eef912f57947fac`;
it remains bad, not a green producer regression. Prior installed74c0d54e…/black
restoration are historical; this worker does not query current phone state.
Independent re-review is required before any separately authorized phone prep.
D3D12/selected Simple path unrun; no measurement-ready, performance, perturbation,
gameplay or A2 conclusion. No automatic next stage.

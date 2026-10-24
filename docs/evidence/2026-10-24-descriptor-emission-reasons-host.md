# Descriptor emission failure reasons — host only (PLA-431)

**Independent review PENDING. Not device verified.** This is failure evidence,
not a runtime root-cause fix or completed A0. No phone/install/UI/perf/JIT/game
operation was run. Descriptor diagnostics and experimental features stay off by
default; A2 remains gated.

## Artifact and invariants

Mesa **0124** adds only `src/kosmickrisp/vulkan/kk_debug.c` failure diagnostics;
0121–0123 and `tools/descriptorprof.py` are byte-identical. The existing malformed
`\n[kk-descriptor] emission failed` prefix gains `stage=` and initialized details:
format/empty, fstat/type, getfl/missing-append, pipe query/indeterminate/invalid
bound/too-large, write error/short-or-zero/exhausted three EINTR attempts. Numeric
fields are decimal, not target constant interpretations. Logical failures omit
errno; syscall failures capture it immediately. `fpathconf` alone clears errno
to distinguish indeterminate -1/0 from error, with caller errno restored afterward.

Checked literal/decimal helpers do not call vsnprintf, including when row
formatting fails. Failure buffer is **512 bytes**, with a compile-time conservative
**376-byte** bound on both Linux and the actual Darwin target, including both
newlines; retained host poisons span **46–124 bytes**. Signed minima are converted
without overflowing negation. Runtime bounds fall back to the original marker.
One best-effort poison write, permanent latch and errno restoration remain. No
sink changes, flag modification, fallback descriptor, suffix continuation, extra
retry, record schema/bytes, operation counters/clocks or client changes. Existing
fstat/getfl/PIPE_BUF acceptance and three-attempt EINTR rules remain unchanged.
Bookkeeping is on the report path; this is not a zero-perturbation claim.

Source authored on scratch Mesa branch at
`98b445b2811187936c951ad8aac740c6c8a8303a`, emitted by git format-patch before
build reconstruction. Reconstructed `107bef9adfb0f8791978ae695c33884c8721a6a3`
is whole-tree identical. No upstream submodule edit is the sole artifact.

## Reproducible host evidence

Logs/scripts/output directories below are under
`$PLAYPORT_BUILD/agent-notes/kk-parity/`; all producer exits were checked.

- **Test first RED:** `a0-emission-reasons-red.log`, exact retained `kk_debug.0123.c`.
  Extended actual-emitter fixture run against unmodified0123 fails exit1 because
  format-error poison has no expected `stage=format`, not a production mutation.
- **GREEN:** `a0-emission-reasons-final2.log`, `emission-reasons-final2/` and
  `a0-emission-reasons-reconstructed.log`. C/Python fixtures link real kk_debug.c.
  Normal calls delegate real APIs; nonappend and `/dev/null` remain unsupported,
  including actual append clearing after initialization. Injected fstat/getfl,
  negative errno/indeterminate/zero/exact/too-small pipe bounds, LONG_MIN/LONG_MAX,
  formatter negative/bound/empty, write error/zero/short/SSIZE_MAX, EINTR success/
  exhaustion and failed poison all pass. Exact available-field sets reject stale
  errno/unavailable details; saved errno, one poison attempt and no subsequent
  formatting/query/write after latch are asserted. Poison formatting never calls
  vsnprintf. Each delivered poison invalidates an otherwise valid full synthetic
  source using the unchanged strict analyzer (no client-only filtering).
- **Full suite, repeated:**
  `build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host .work/run/mesa/hosttest`
  exit0, `a0-emission-reasons-mesa-host-final.log`. Real API off capture has no
  descriptor rows; enabled accounting, NIR and Zink checks pass. **236/236** saved
  baseline/off/on MSL files identical; replay **0/1/2/2**, **3/3/4/5** unchanged.
  Three seeds1/431/3735928559 each produce4010 complete rows,0 malformed. Existing
  maximum v1 snapshot1074 observed/1097 conservative remains below2048.
- Unchanged parser **33 tests pass**, `a0-emission-reasons-parser-tests.log`.
  Both complete historical raws still exit1 (new `*-still-invalid.json` files):
  retry0 usable/60 rejected intervals/61 complete client captures rejected/2
  malformed poisons; original remains invalid. Raw hashes and old parser outputs
  preserved; no sanitization or historical-output overwrite.
- `./pp test --quick`: **745 Python tests/26 C groups**, exit0
  (`a0-emission-reasons-quick.log`); names/secrets clean. Swift tests not run.
- Real **arm64-apple-ios26.0**, SDK26.5 emitter compiled with actual build flags,
  no shim. `check-emission-target.py` / `a0-emission-reasons-target.log` prove
  `sizeof(uintmax_t)=8`, CHAR_BIT8 and the376-byte conservative bound. These are
  compiler/host facts, not observed runtime sink/type/errno values.

## Build and remaining gate

`./pp build` exit0, **89 checks passed/0 failed**, unsigned dev IPA:
`.work/out/20261024-102128-aa32a361/Playport-26.5-aa32a361.ipa`, SHA256
`aa32a3616694ee28806ad4667833fb40af77993c06a5b79ee867860308b07a19`.
Build log `a0-emission-reasons-build.log`; **not installed**. No causal build-record
rows changed. Protected owner SettingsView edit is included in the IPA but remains
unstaged/uncommitted and byte-identical: not exact committed-source provenance.

Existing stable-fd2/flags and downstream-relay limitations remain; poison itself
can fail. Approved final-newline-only short plus failed poison still can leave a
schema-accepted final capture, explicitly tested unchanged. Native runtime
failure branch is still **unknown**, not proven fixed. D3D12, human gameplay,
calibration/perturbation measurement and A0/A2 justification remain unrun/gated.
Next: independent review of0124 and retained red/green evidence, then only a
**separately authorized ONE diagnostic DXVK-on capture**, not more menu comparisons
or human measurement. Games observed: **none**.

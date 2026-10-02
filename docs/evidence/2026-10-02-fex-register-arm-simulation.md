# Portal 2: register-only ARM simulator execution gate

## Verdict

All 144 real FEX ARM blocks from the [emission gate](2026-10-02-fex-register-arm-emission.md)
execute in a pinned host CPU simulator and match the independent x86 register
oracle for all 18432 input/block combinations. The real entry prologue and
initial unlinked thunk execute; their state write, literal read, branch path
and exit link-register capture pass. This advances checked emitted words to
**simulated instruction execution**, not native ARM or iOS execution.

**Portal 2 remains unplayable.** No real linker/dispatcher, native helper, guest
load/store, Windows bridge or game instruction stream executes. This native
non-EC backend audit does not validate the shipped ARM64EC ABI, instruction-cache
publication, exceptions or concurrent invalidation. No patch, pin, runtime/app
source or build record changed. No IPA was built or installed; **not checked on
the phone**, with no device-run IPA SHA256. The optional host experiment is not
another app entry point, and its simulator is never bundled in an IPA.

## Execution boundary

`native_decode_audit.py --simulate` implies `--emit` and keeps all prior real
decode/dispatch, default optimization/RA and independent IR/machine-word checks.
The assertion-enabled C++ audit writes `blocks.jsonl` only after those checks:
unmodified code, register budget/map, entry/thunk offsets, guest PCs and 128
independent x86 input/result pairs per block. Original source/archive hashes
remain logged; Frontend.cpp SHA256 remains
`714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`.

`arm_simulator_audit.py` uses Unicorn 2.1.4, without implementing FEX instruction
semantics or using the offline machine-word evaluator to obtain runtime results.
The optional Linux x86-64 wheel is hash-locked in
`arm_simulator_requirements.txt` (SHA256
`9d6e6dea140560de4ebd8446661f7ef84a357d428c14a3ef09dacd306ec8c239`).
Its native simulator library SHA256 is
`ddb196ec82b52e502c18e4a34478bf7b9f61c83c2ebaa95c74d8ded45a95da9c`.

Each block is placed at a distinct address above 4 GiB, independent of its
original low guest PC. The **only changed bytes** belong to the native
exit-linker literal, replaced with a separate high mapped capture address.
The simulator executes ADR/STR prologue, every register-body instruction,
final B, thunk B, LDR linker literal and BLR; a hook stops before the capture
page's BRK guard. It never calls the real linker's host-x86 address. There is no
backpatching or return to a dispatcher.

Checks include:

- Exact bounded instruction path, with no ignored body or exit instructions.
- Low-32-bit guest registers against the independent x86 oracle. Temporary and
  guest upper halves are poisoned per trial; untouched non-budget registers,
  SP and NZCV retain their inputs. Upper guest-register semantics are not claimed.
- A single 8-byte prologue write of the high code-header address to a synthetic
  high CPU-state page; every other CPU-state byte remains a canary.
- A single 8-byte thunk literal read. No guest address, stack, native helper or
  other data access is permitted. Code is RX, synthetic state RW/non-executable.
- Exit PC/X0 equal the capture address, LR equals thunk+16, and the record has
  zero unlinked HostCode, the exact low guest exit PC and caller-relative offset.
  Emitted code remains unchanged after execution.

All three backing granules and PCs from the earlier audit remain covered,
including `0xffff0ffe`. Granules describe the **host decode backing**; this does
not simulate iOS page protection or its instruction-cache behavior.

## Validation

Dependency installation and reproduction are in
[build/guest32](../../build/guest32/README.md#register-only-arm-simulator-execution-gate-host-audit-only).
With its repository-local dependency directory exposed via PYTHONPATH:

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --simulate
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --simulate --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --emit
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --emit --sanitize
./pp test --quick
```

Optimized and ASan/UBSan execution audits pass, including leak checks. Sanitizers
cover the C++ export/checker, frontend, adapter and g32; FEX archives and the
third-party simulator are **uninstrumented**. Logs and per-build exports stay in
`.work/guest32/separated-execution/`; differing native linker pointers mean the
exports' whole-file hashes need not match between runs.

Eight controls corrupt private exported copies **after** the real IR/offline
machine checks: MOV literal, MOV destination, unexpected load, missing header
store, self-branch, BR replacing BLR, guest exit record and x86 expected result.
All are rejected for the intended reason. The BR control reaches the capture
address but fails LR validation, proving that PC-only capture would be too weak.
Controls run on every `--simulate` invocation without mutating source trees or
saved exports.

Emission-only optimized/sanitized regressions, Python syntax compilation,
FEX-style clang-format and git whitespace checks pass. `pp test --quick` passes
all gates, 480 tooling tests and host C suites. Swift tests and ARM64EC rebuild
were not requested: only optional host-audit code changed. All processes ran in
the foreground and exited; no background process was started.

## Next bounded gate

The entry's native CPU-state pointer and the exit's native linker pointer can
remain high while guest metadata remains 32-bit. That is not evidence that the
backend translates guest effective addresses: these blocks contain none.
The next memory gate should explicitly distinguish native CPU-state access
from a scalar guest load/store and exercise separated backing plus permission
and boundary failures. Stack/vector/string/atomic accesses and auxiliary code
readers remain separate coverage requirements. Any eventual native phone
execution experiment must enter through the developer UI. Wine i386/WoW64,
graphics/audio/input and a Portal 2 menu/play/save/reload remain unresolved.

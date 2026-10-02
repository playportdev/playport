# Portal 2: closed checked scalar-load lowering gate

## Verdict

The real FEX decoder, default optimizer/register allocator and backend now
emit a checked **MOV EAX,[EBX]** through an isolated test seam. Its complete
block executes against separated high backing with the compiled scalar helper.
6390 simulated loads pass (3195 with the ordinary helper, 3195 with the
adversarial AAPCS64 wrapper), with five lowering corruption controls rejected.
This advances the [call fixture](2026-10-02-fex-checked-scalar-call.md) to one
real allocated memory handler. It is **not a general checked-memory port**.

**Portal 2 remains unplayable. Not checked on the phone.** No app, pin, IPA,
committed artifact record or runtime entry point changes. No device-run IPA
SHA256 exists. No background process was started.

## Method and boundaries

Patch `fex/0016` adds an opt-in translation-unit-only
`FEX_TEST_CHECKED_SCALAR_LOAD` branch inside the real `LoadMemTSO` handler.
It changes no context/thread layout, enables no CMake target and is forbidden
with iOS/ARM64EC platform macros. Ordinary native and shipped builds retain
the existing handler. Generic LoadMem/StoreMem and implicit native CPU-state
operations are untouched: this is **not** new pointer-provenance metadata or
an automatic classification scheme.

`scalar_lowering_test.cpp` decodes the independent bytes `8b 03` through the
existing byte-source seam from execute-only separated memory. The instruction
crosses a guest page boundary at PCs `0x400fff`, `0x900fff`, `0xffff0fff`.
Real opcode handlers, the default optimizer/RA pipeline and IRValidation run.
A strict closed post-RA graph check requires one i32 GPR LoadMemTSO from the
EBX fixed register into the EAX fixed register, no offset, and one exit to
PC+2. Unknown operations fail. Thus the test proves this one graph contains
only a guest data operand; it does not infer provenance for arbitrary IR.

The backend calls the same compiled `g32_scalar_access`, using the **full**
allocated EBX value as the address, width 4 and old helper value zero. Full
width is retained so even deliberately invalid high bits reject rather than
truncate. The real FEX spill/push/pop/fill methods preserve live state; x3
retains the packed return. Destination publication happens only after restore
and a non-flag-setting status branch. Success falls through to the real
unlinked exit thunk. Failure records `IR->GetHeader()->OriginalRIP` and stops
at native capture before the normal exit, without publishing EAX.

The original block PC is sufficient **only because this gate enforces one
instruction**. Multi-instruction lowering will need each faulting instruction's
PC; the native fault record is not dispatcher exception delivery. The test
seam does not implement stores, partial loads, address arithmetic, concurrency,
TSO ordering or a production helper ABI.

The runner compiles complete series-applied Frontend.cpp and MemoryOps.cpp with
only their ABI-neutral test macros, ahead of real native FEX archives. No FEX
method is replaced. The native context is uniformly non-iOS/non-EC. The helper
and g32 checks are real freestanding ARM64 machine code from the earlier
[helper gate](2026-10-02-guest32-scalar-arm-helper.md). Hooks only observe and
stop; none synthesizes returns, translations, backing accesses or restoration.
Only the native exit-linker literal in the private exported block is adapted
to capture. The real dispatcher/linker does not execute.

## Checks

1065 cases per block/helper cover all committed guest permission pairs,
decommitted neighbors, aligned/unaligned/cross-page dword reads, blocked low
addresses, exact top-of-space fits and overflow, null/poisoned spaces and wide
native addresses, across three granule metadata values. These are simulator
metadata values, not three native ARM VM configurations. Sparse backing is RW
above 4 GiB even where guest permissions deny access; no low guest-number
mapping exists. Every rejection must touch no backing and skip both normal
exit branch and thunk. Success must enter the helper once, read precisely four
backing bytes, publish their independently expected little-endian value and
reach the normal thunk with its expected LR.

The existing independent helper simulator checks are shared, not replaced:
all 24 allocated static/dynamic GPRs, all 30 full 128-bit SIMD registers,
STATE/call-return-stack register, SP, NZCV, helper arguments/count, complete
backing canaries, native descriptor canaries, bounded stack and native CPU-state
writes are checked. Only successful EAX and normal-exit LR may change. Real
32-bit static GPR spills are **64-bit**: deliberately poisoned wide EBX inputs
remain intact after rejecting the address, unlike unchecked base emission.
The entry prologue's native header slot is an additional allowed/checkable
write; it is never translated as a guest operand.

The adversarial wrapper executes the actual helper, then clobbers every
AAPCS64-permitted live GPR, full volatile SIMD registers, high halves of v8-v15
and NZCV. Five private post-export ARM mutations fail for their intended
observation: wrong address register, wrong width, missing status branch, wrong
destination and wrong decoded fault PC. No tracked emitter is corrupted.

## Validation

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_lowering_audit.py .work/guest32/decode-audit/native
# Repeat with --sanitize.
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_call_audit.py .work/guest32/decode-audit/native
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-simulate
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_arm_audit.py
cmake --build .work/run/fex/build-arm64ec --target FEXCore -j 6
./pp test --quick
python3 -m py_compile build/guest32/scalar_lowering_audit.py build/guest32/scalar_arm_audit.py
clang-format --style=file:.work/run/fex/.clang-format --dry-run --Werror \
  build/guest32/scalar_lowering_test.cpp
git diff --check
```

Optimized and ASan/UBSan gates pass. Sanitizers cover the new test, complete
frontend/memory-handler TUs and host g32, not remaining archives, ARM helper
or simulator. ARM64EC FEXCore builds with the seam **disabled**. Macro-off
preprocessing of the original and patched MemoryOps.cpp is byte-identical
with diagnostic file/line macros normalized.
The call regression retains 12762 calls/seven controls; raw-memory regression
retains 19584 simulated inputs, native FXCH IR-only provenance checks and 38
emission controls; compiled-helper regression retains 6327 cases/seven controls.
Quick name/secret/pin/series/tooling/host C checks pass. These optional native
and simulator prerequisites remain outside CI.

Unicorn remains 2.1.4, native library SHA256
`ddb196ec82b52e502c18e4a34478bf7b9f61c83c2ebaa95c74d8ded45a95da9c`.
The runner prints source/archive/ELF hashes. Logs are
`.work/guest32/scalar-lowering-{optimized,sanitized,call-regression,memory-regression,helper-regression,arm64ec,macro-off,quick}.log`;
private objects, exports and binaries stay in `.work/guest32/scalar-lowering/`.

## Next boundary

Extend a closed decoded gate to an allocated dynamic address/destination or
store, independently exercising guest arithmetic and continuation liveness
before any general provenance-sensitive memory port. Native generic memory
must continue bypassing guest checks. General fault delivery, other memory
families, ARM64EC/iOS interop, Wine i386 marshalling, graphics/audio/input and
Portal 2 menu/play/save/reload remain unresolved. Phone integration must use
the UI and include a Hollow Knight regression play.

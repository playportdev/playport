# Portal 2: register-only decode-to-IR gate

## Verdict

The real series-applied FEX decoder and opcode handlers now produce verified
**pre-optimization 32-bit register IR from separated guest memory**. Two bounded
MOV/MOVZX sequences pass independent per-instruction register checks at native,
simulated 16 KiB and simulated 64 KiB host granules. This advances the next gate
from [the full decoder audit](2026-10-02-fex-separated-decoder.md).

**Portal 2 remains unplayable.** No JIT code or guest instruction executes. This
is not the complete ContextImpl::GenerateIR pipeline, optimized IR, register
allocation, ARM execution, a Windows bridge or game loading. No app/runtime code,
upstream patch, pin or build record changed. No IPA was built or installed;
**not checked on the phone**, with no device-run IPA SHA256.

## What is real, and what is the test

`build/guest32/native_decode_audit.py --ir` uses the same native build and
ABI-neutral frontend byte-source seam as the decoder audit. The shared
`native_audit_adapter.h` is the existing serialized g32 fetch/query adapter,
extracted without changing its behavior. Only Frontend.cpp enables the test
macro. No iOS platform layout is mixed into native FEX.

`native_ir_test.cpp` constructs a real ContextImpl, 32-bit-CS thread, Decoder and
OpDispatchBuilder. It decodes through the complete opcode tables, invokes their
real dispatcher member functions, follows the per-instruction cache-flush and
FinishOp lifecycle from GenerateIR, and calls real Finalize and IRValidation.
It deliberately stops before the optimizer/RA/backend pipeline. It does not
replace any FEX decoder, instruction handler, allocator or validation method.
The test emits GuestOpcode metadata at every instruction, as extended-debug IR
does, to establish exact comparison boundaries.

A small **offline SSA graph checker**, not a FEX execution backend, accepts only
block markers, GuestOpcode, Constant, LoadRegister, StoreRegister, Bfi, Bfe,
InlineEntrypointOffset and ExitFunction. Any other node aborts: in particular,
there is no ignored memory, flags, helper, syscall or control-flow operation.
SSA inputs must already have values. Fixed register accesses must be i32 and
refer to the eight guest GPRs; literals cannot be native pointer values. Stores
have the independently expected destination. Guest metadata/exit addresses must
match the original low PC and independently specified instruction lengths.

A separate x86 register oracle specifies effects independently of the bytes
and FEX IR. It checks the full eight-register state at **every instruction
boundary**, not just the last result. Only 32-bit architectural register values
are modeled: this does not establish native CPU-state storage semantics or any
upper-64-bit behavior during actual execution.

## Cases and results

At each host granule, two sequences run at guest PCs `0x400ffe`, `0x900ffe` and
`0xffff0ffe`, with bytes in high, non-native-executable backing:

- Nine instructions write independently specified imm32 values to all eight
  GPRs, including ESP/EBP, then copy EAX to ECX. Values include zero,
  `0xffffffff`, `0x80000001` and mixed-bit patterns. No stack operation occurs.
- Seven instructions write AX, AL and AH; copy EAX to ECX; zero-extend AH to EDX;
  copy input-dependent ESI to EDI; and write BP. Untouched register bits and
  unaffected GPRs must remain intact.
- Both first instructions cross a 4 KiB guest-page boundary. Both pages are
  execute-only; ordinary g32_read remains denied. Guest PCs, block/instruction
  lengths and exit PC remain guest-valued, including near the top of 32-bit
  address space. No image preferred base or native backing pointer is used as
  an IR PC.
- Each graph is checked with all-zero, all-one and 126 deterministic pseudorandom
  initial register states: 18 generated graphs, 2304 input-state comparisons,
  and 18432 instruction-boundary comparisons per audit invocation.
- Fetching the entire sequence afterward returns unchanged bytes. All guest
  reservations are released; decoder/emitter pool ownership checks pass.

Optimized and ASan/UBSan audits pass all three granules. Sanitizers instrument
the full frontend, adapter, checker and g32, **not the other FEX archives**
containing dispatcher methods and IRValidation. Assertions are enabled in the
native FEX build and forcibly retained in the audit TU; its compiler warnings
are errors. Existing decoder tests also pass in both build modes after the
adapter extraction.

Three private negative controls each compile a copy of the checker test with
one deliberate mistake: wrong expected imm32, wrong expected destination, or
wrong guest metadata offset. Each is rejected by an assertion (SIGABRT), not a
false PASS. The copies do not modify upstream or tracked sources. Their script,
binaries and assertion logs remain under `.work/guest32/separated-ir/`.

## Reproduction and validation

Use the prepared native build from
[the allocator configuration](2026-10-01-fex-native-allocator.md#reproduction):

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --sanitize
./pp test --quick
```

This is an optional host audit, not a CI test or a second entry point into app
functionality. Output/source/archive hashes are in
`.work/guest32/separated-ir/{optimized,sanitized}.log`; decoder regressions,
negative controls and quick host results are beside them. The series-applied
Frontend.cpp SHA256 remains
`714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`.

`pp test --quick` passes name/secret/pin/patch gates, all 480 tooling tests and
host C suites. Python syntax compilation, FEX-style clang-format checks and
git diff whitespace checks pass. Swift tests and ARM64EC rebuild were not
requested: only optional host-audit sources changed. All processes ran in the
foreground and exited; no background process was started.

## New integration finding and next gate

Pure 32-bit partial-register semantics can have **i64 Constant/Bfi values** while
LoadRegister/StoreRegister remain i32. IR size alone cannot distinguish a guest
pointer from a native pointer, or a pointer from an ordinary register value.
A future memory port must track access provenance, not rewrite every i64 SSA
value or every register operation as a guest address.

The next bounded gate is the same register-only sequences through real
optimization and register allocation with semantic verification, before ARM
code generation/execution. That gate is now recorded in
[the allocated-register audit](2026-10-02-fex-allocated-register-ir.md). The host is not an ARM execution target. An eventual
phone execution experiment must enter through the product's developer UI.
Scalar/stack/vector/string/atomic memory checking, concurrent VM invalidation,
SMC/disk-cache/diagnostic readers, Wine nested-pointer marshalling and i386
D3D9/audio/input remain outside this audit. No evidence here supports a Portal 2
menu or gameplay claim.

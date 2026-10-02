# Portal 2: scalar guest-address IR gate

## Verdict

Real FEX decode/dispatch produces independently verified scalar-memory IR for
153 graphs and 19584 input states. Guest effective addresses wrap/truncate as
specified by an independent x86 oracle, while native CPU-state storage stays
above 4 GiB. Verified guest addresses can be passed to the existing checked C
memory API with full-width permission/boundary checks and transactional failures.
This advances the [register-only simulation gate](2026-10-02-fex-register-arm-simulation.md)
to a bounded **pre-optimization memory-address contract**, not a FEX memory port.

**Portal 2 remains unplayable.** No memory JIT block, real game instruction stream,
Wine bridge or ARM64EC/iOS execution occurs. No patch, pin, app/runtime source,
IPA or build record changes. **Not checked on the phone**; there is no device-run
IPA SHA256. The optional host experiment is not another app entry point.

## Coverage and provenance

`native_decode_audit.py --memory-ir` uses the same series-applied native archives,
ABI-neutral frontend byte-source seam, real context and opcode dispatch lifecycle
as the earlier audits. It is mutually exclusive with the register-only modes.
No FEX method is replaced. Real IRValidation runs before the strict inspector;
optimization, register allocation and code generation do not run.

The 17 instruction forms comprise:

- Dword MOV loads/stores through EBX, EBX-16, EBX+ESI*4-16, address-size-16
  BX+SI-16, FS:EBX and an absolute address crossing a guest page boundary.
- Byte and word MOV loads/stores through EBX, retaining untouched EAX bits.
- FNSTCW [EBX], which reads the control word from native CPU-state storage and
  writes guest memory as a 16-bit scalar.

Each graph is decoded at `0x400ffe`, `0x900ffe` and `0xffff0ffe`, at native,
16 KiB and 64 KiB host granules. Instruction bytes remain execute-only and
unchanged. Every graph receives 128 independently specified input states,
including 13 deliberate null/page/permission/top-of-space targets (transformed
by each address formula) and pseudorandom registers. FS bases alternate between
`0x12340000` and `0xffff0000`; segment addition wraps at 32 bits. The address-size-16
case verifies zero-extended low-16-bit results, which this fixture deliberately
rejects as blocked low addresses, not successful mapped reads.

The SSA inspector recognizes only bounded value arithmetic, partial-register
inserts, metadata, scalar TSO memory and fixed-register/context operations.
Addresses, width/direction and store values match independent x86 expectations.
Guest loads supply a sentinel for checking register-write structure/results;
**they do not read memory during IR inspection**. Unexpected operations,
uninitialized SSA references, memory offsets or context offsets fail.

`LoadContext` reads a synthetic native CPUState above 4 GiB using only checked
FS-cache/control-word offsets. Its storage address is never passed to g32.
Loaded segment/control values may feed guest arithmetic/stores: classifying all
values loaded from native storage as native pointers would be wrong. Conversely,
there is no assertion that all generic memory IR is guest memory after lowering.

The pre-optimization FS store contains two valid FS-cache loads, including
redundant address preparation; the audit retains and validates both. This is
why a strict structural census cannot assume one native-context load per guest
instruction. A post-optimization gate remains necessary.

## Checked adapter, not checked JIT execution

Only after address inspection does host test code pass the guest address and
full access width to `g32_read`/`g32_write`. This happens **outside FEX** and does
not alter or execute its memory emitters. The independent fixture oracle has
one RW guest page followed by a read-only page in a shared native host granule,
with an uncommitted neighbor and execute-only instruction pages.

The adapter verifies correct successful read/store bytes, unchanged neighboring
bytes, denied cross-page stores, read-only/uncommitted/execute-only refusal,
blocked low addresses and non-wrapping access-end overflow. Failed writes leave
the whole two-page fixture unchanged; failed reads also preserve their output.
Guest address arithmetic may wrap first, but a multi-byte access itself may not
wrap through address zero. This fixture does not test concurrent VM changes,
fault delivery, guard/write-copy pages or a runtime helper ABI.

## Validation

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-ir
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-ir --sanitize
# With the existing repository-local simulator dependency exposed via PYTHONPATH:
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --simulate
./pp test --quick
```

Optimized and ASan/UBSan audits pass. Sanitizers cover the inspector, frontend,
checked C memory and native-context test storage; other FEX archives remain
uninstrumented. Only the inspector translation unit enables C++ exceptions for
its negative controls; no exception unwinds through FEX or changes its build ABI.
Frontend SHA256 remains
`714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`.
The runner prints all source/archive hashes. Outputs stay in
`.work/guest32/separated-memory-ir/{optimized,sanitized}/`; captured logs are
`.work/guest32/memory-ir-{optimized,sanitized}.log`.

225 controls mutate private real generated IR after positive inspection and
restore every field: base-register/store-value source, SIB scale, memory width
and native-context offset. Every control fails with its expected diagnostic,
not merely an arbitrary exception. No upstream tree or saved runtime artifact
is modified. The existing 144-block/18432-input ARM simulation regression passes.
FEX-style clang-format, Python syntax compilation, git whitespace and quick
host gates pass. No background process was started.

## Next boundary

A checked scalar emitter needs guest/native provenance that survives the real
optimizer/RA pipeline, not just this pre-RA inspection. In particular,
`FEXCore/Source/Interface/IR/Passes/x87StackOptimizationPass.cpp` introduces
`FormContextAddress(i64, index, 16)` in `GetOffsetTopAddressWithCache_Slow`, then
uses that native pointer with ordinary `LoadMemFPR` in `LoadStackValueAtOffset_Slow`.
Pre-optimization x87 stack pseudo-operations therefore cannot establish the
post-lowering generic-memory contract. This is source inventory, **not tested
x87 execution**. The next bounded gate should verify scalar addresses through
optimization alongside a lowered native-context-memory counterexample before
adding checked guest scalar ARM loads/stores.

Stack/vector/string/atomic paths, auxiliary code readers, fault delivery,
concurrent invalidation, Wine i386/WoW64 marshalling, graphics/audio/input and
Portal 2 menu/play/save/reload remain unresolved. Any eventual native phone
experiment must enter through the developer UI.
